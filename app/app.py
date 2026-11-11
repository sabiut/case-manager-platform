"""Small three-tier demo app: a web page that lists cases from a customer's SQL Server database.

Settings come from environment variables, set by the platform:
  DB_HOST                 where the database is
  DB_USER, DB_PASSWORD    the app's own restricted login (read and write rows in its database, nothing else)
  DB_NAME                 the customer database to read (default: demo)
  REGION_CODE             au, uk or us, shown on the page

The app never creates or changes the schema. That is migrate.py, run as a separate step.
"""
import os
import socket

import pymssql
from flask import Flask, jsonify, render_template_string

DB_HOST = os.environ.get("DB_HOST", "")
DB_USER = os.environ.get("DB_USER", "")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_NAME = os.environ.get("DB_NAME", "demo")
REGION_CODE = os.environ.get("REGION_CODE", "local")
VERSION = os.environ.get("APP_VERSION", "dev")

app = Flask(__name__)

PAGE = """<!doctype html>
<title>Case Manager lab</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 760px; margin: 40px auto; padding: 0 16px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border: 1px solid #ccc; padding: 6px 10px; text-align: left; }
  .ok { color: #0a6b3d; } .bad { color: #a11; } dt { font-weight: 600; } dd { margin: 0 0 8px 0; }
</style>
<h1>Case Manager lab</h1>
<dl>
  <dt>Region</dt><dd>{{ region }}</dd>
  <dt>Answered by</dt><dd>{{ host }}</dd>
  <dt>App version</dt><dd>{{ version }}</dd>
  <dt>Database</dt>
  <dd>{% if failed %}<span class="bad">The database is not available right now.</span>
      {% else %}<span class="ok">Connected</span> to {{ db_name }} on {{ db_version }}{% endif %}</dd>
</dl>
{% if cases %}
<h2>Cases in {{ db_name }}</h2>
<table>
  <tr><th>ID</th><th>Client</th><th>Status</th><th>Opened</th></tr>
  {% for c in cases %}<tr><td>{{ c[0] }}</td><td>{{ c[1] }}</td><td>{{ c[2] }}</td><td>{{ c[3] }}</td></tr>{% endfor %}
</table>
{% endif %}
"""


def connect():
    return pymssql.connect(
        server=DB_HOST, user=DB_USER, password=DB_PASSWORD, database=DB_NAME,
        login_timeout=5, timeout=10,
    )


@app.get("/health")
def health():
    """Liveness: is this copy of the app running? Used by the load balancer.

    It does not touch the database on purpose: if the database has a problem,
    the load balancer should not also remove every copy of the app.
    """
    return jsonify(status="ok", version=VERSION)


@app.get("/ready")
def ready():
    """Readiness: can this copy reach its database and read the cases table?

    Used by the deployment pipeline as the smoke test before it moves on to the next region.
    """
    try:
        conn = connect()
        try:
            cur = conn.cursor()
            cur.execute("SELECT COUNT(*) FROM dbo.cases")
            cur.fetchone()
        finally:
            conn.close()
    except Exception:
        app.logger.exception("Readiness check failed")
        return jsonify(status="database unavailable", version=VERSION), 503
    return jsonify(status="ok", version=VERSION)


@app.get("/")
def index():
    cases, db_version, failed = [], "", False
    try:
        conn = connect()
        try:
            cur = conn.cursor()
            cur.execute("SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(50)), CAST(SERVERPROPERTY('Edition') AS NVARCHAR(100))")
            row = cur.fetchone()
            db_version = f"SQL Server {row[0]} ({row[1]})"
            cur.execute("SELECT id, client, status, opened FROM dbo.cases ORDER BY id")
            cases = cur.fetchall()
        finally:
            conn.close()
    except Exception:
        # The detail goes to the server log (CloudWatch). The visitor sees only a general message.
        app.logger.exception("Could not read cases from the database")
        failed = True
    return render_template_string(
        PAGE, region=REGION_CODE, host=socket.gethostname(), version=VERSION,
        db_name=DB_NAME, db_version=db_version, cases=cases, failed=failed,
    )
