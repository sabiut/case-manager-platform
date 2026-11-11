"""Frontend (web tier). Serves the web pages and nothing else.

It has no database login and cannot reach the database. Everything it shows comes from
the backend API, which it calls over the private network.

Settings come from environment variables, set by the platform:
  API_URL        address of the backend API (the internal load balancer)
  REGION_CODE    au, uk or us, shown on the page
"""
import os
import socket

import requests
from flask import Flask, jsonify, redirect, render_template_string, request, url_for

API_URL = os.environ.get("API_URL", "http://localhost:8081").rstrip("/")
REGION_CODE = os.environ.get("REGION_CODE", "local")
VERSION = os.environ.get("APP_VERSION", "dev")
TIMEOUT = (3, 10)  # seconds to connect, seconds to wait for the answer

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 16 * 1024

PAGE = """<!doctype html>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Case Manager lab</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 760px; margin: 40px auto; padding: 0 16px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border: 1px solid #ccc; padding: 6px 10px; text-align: left; }
  .ok { color: #0a6b3d; } .bad { color: #a11; } dt { font-weight: 600; } dd { margin: 0 0 8px 0; }
  form.inline { display: inline; } form.add { margin: 16px 0; }
  input, button { font: inherit; padding: 4px 8px; }
</style>
<h1>Case Manager lab</h1>
{% if failed %}<p class="bad">That change could not be saved. Please try again.</p>{% endif %}
<dl>
  <dt>Region</dt><dd>{{ region }}</dd>
  <dt>Frontend</dt><dd>version {{ version }}, answered by {{ host }}</dd>
  <dt>Backend API</dt>
  <dd>{% if info %}<span class="ok">Connected</span>, version {{ info.version }}, answered by {{ info.host }}
      {% else %}<span class="bad">The service is not available right now.</span>{% endif %}</dd>
  {% if info %}<dt>Database</dt><dd>{{ info.database.name }} on {{ info.database.version }}</dd>{% endif %}
</dl>
{% if info %}
<h2>Cases</h2>
<form class="add" method="post" action="{{ url_for('add_case') }}">
  <label>New case for client <input name="client" maxlength="100" required></label>
  <button>Add</button>
</form>
<table>
  <tr><th>ID</th><th>Client</th><th>Status</th><th>Opened</th><th></th></tr>
  {% for c in cases %}
  <tr><td>{{ c.id }}</td><td>{{ c.client }}</td><td>{{ c.status }}</td><td>{{ c.opened }}</td>
      <td>{% if c.status != "Closed" %}
        <form class="inline" method="post" action="{{ url_for('close_case', case_id=c.id) }}"><button>Close</button></form>
      {% endif %}</td></tr>
  {% endfor %}
</table>
{% endif %}
"""


def api(method, path, **kwargs):
    """Calls the backend API and returns (data, error message). Never raises."""
    try:
        response = requests.request(method, API_URL + path, timeout=TIMEOUT, **kwargs)
        data = response.json()
    except (requests.RequestException, ValueError):
        # The detail goes to the server log (CloudWatch). The visitor sees only a general message.
        app.logger.exception("Call to the backend API failed: %s %s", method, path)
        return None, "The service is not available right now."
    if response.ok:
        return data, None
    message = data.get("error", {}).get("message") if isinstance(data, dict) else None
    return None, message or "The request could not be completed."


@app.get("/health")
def health():
    """Liveness. It does not call the API on purpose: if the API has a problem,
    the load balancer should not also remove every copy of the frontend."""
    return jsonify(status="ok", version=VERSION)


@app.get("/ready")
def ready():
    """Readiness of the whole chain: frontend -> API -> database.

    Used by the deployment pipeline as the smoke test before it moves on to the next region.
    Reports both versions, so the pipeline can prove the new frontend AND the new API answered.
    """
    data, _ = api("GET", "/ready")
    if not data or data.get("status") != "ok":
        return jsonify(status="backend unavailable", version=VERSION, api_version=None), 503
    return jsonify(status="ok", version=VERSION, api_version=data.get("version"))


@app.get("/")
def index():
    info, _ = api("GET", "/api/v1/info")
    cases = []
    if info:
        listing, _ = api("GET", "/api/v1/cases", params={"limit": 100})
        cases = listing["items"] if listing else []
    return render_template_string(
        PAGE, region=REGION_CODE, host=socket.gethostname(), version=VERSION,
        info=info, cases=cases, failed=request.args.get("failed") == "1",
    )


@app.post("/cases")
def add_case():
    _, error = api("POST", "/api/v1/cases", json={"client": request.form.get("client", "")})
    return redirect(url_for("index", failed="1" if error else None))


@app.post("/cases/<int:case_id>/close")
def close_case(case_id):
    _, error = api("PATCH", f"/api/v1/cases/{case_id}", json={"status": "Closed"})
    return redirect(url_for("index", failed="1" if error else None))
