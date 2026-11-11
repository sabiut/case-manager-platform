"""Backend API (application tier). JSON only, no web pages.

It is the only part of the system that talks to the database, and it is not reachable from
the internet: only the frontend can call it, through an internal load balancer.

Endpoints:
  GET   /health                 is this copy running? (used by the load balancer, no database call)
  GET   /ready                  can this copy reach its database? (used by the deployment pipeline)
  GET   /api/v1/info            region, version and database version
  GET   /api/v1/cases           list cases. Optional: ?status=Open&limit=50&offset=0
  POST  /api/v1/cases           create a case. Body: {"client": "A. Smith", "status": "Open"}
  GET   /api/v1/cases/<id>      one case
  PATCH /api/v1/cases/<id>      change the status. Body: {"status": "Closed"}

Every error has the same shape:  {"error": {"code": "not_found", "message": "..."}}

Settings come from environment variables, set by the platform:
  DB_HOST                 where the database is
  DB_USER, DB_PASSWORD    the API's own restricted login (read and write rows, nothing else)
  DB_NAME                 the customer database (default: demo)
  REGION_CODE             au, uk or us

The API never creates or changes the schema. That is migrate.py, run as a separate step.
There is no sign-in in this lab. A real API would check who the caller is on every request.
"""
import os
import socket

import pymssql
from flask import Flask, jsonify, request
from werkzeug.exceptions import HTTPException

DB_HOST = os.environ.get("DB_HOST", "")
DB_USER = os.environ.get("DB_USER", "")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_NAME = os.environ.get("DB_NAME", "demo")
REGION_CODE = os.environ.get("REGION_CODE", "local")
VERSION = os.environ.get("APP_VERSION", "dev")

STATUSES = ("Open", "In progress", "Closed")
MAX_LIMIT = 100

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 16 * 1024  # request bodies here are tiny; refuse anything large


class ApiError(Exception):
    def __init__(self, status, code, message):
        self.status, self.code, self.message = status, code, message


def error_response(status, code, message):
    return jsonify(error={"code": code, "message": message}), status


@app.errorhandler(ApiError)
def handle_api_error(err):
    return error_response(err.status, err.code, err.message)


@app.errorhandler(HTTPException)
def handle_http_error(err):
    # Unknown address, wrong method, body too large: still answer in the standard JSON shape.
    return error_response(err.code, err.name.lower().replace(" ", "_"), err.description)


@app.errorhandler(pymssql.Error)
def handle_database_error(err):
    # The detail goes to the server log (CloudWatch). The caller sees only a general message.
    app.logger.exception("Database error")
    return error_response(503, "database_unavailable", "The database is not available right now.")


@app.errorhandler(Exception)
def handle_unexpected_error(err):
    app.logger.exception("Unexpected error")
    return error_response(500, "internal_error", "Something went wrong.")


def connect():
    return pymssql.connect(
        server=DB_HOST, user=DB_USER, password=DB_PASSWORD, database=DB_NAME,
        login_timeout=5, timeout=10,
    )


def query(sql, params=(), commit=False):
    """Runs one statement and returns its rows. Values are always passed as parameters, never built into the SQL text."""
    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute(sql, params)
        rows = cur.fetchall() if cur.description else []
        if commit:
            conn.commit()
        return rows
    finally:
        conn.close()


def case_json(row):
    return {"id": row[0], "client": row[1], "status": row[2], "opened": row[3].isoformat()}


def json_body():
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        raise ApiError(400, "invalid_body", "The request body must be a JSON object.")
    return body


def valid_status(value):
    if value not in STATUSES:
        raise ApiError(422, "invalid_status", "status must be one of: " + ", ".join(STATUSES))
    return value


def whole_number(name, default, lowest, highest):
    raw = request.args.get(name, default)
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise ApiError(422, "invalid_" + name, f"{name} must be a whole number.")
    if not lowest <= value <= highest:
        raise ApiError(422, "invalid_" + name, f"{name} must be between {lowest} and {highest}.")
    return value


CASE_COLUMNS = "id, client, status, opened"


@app.get("/health")
def health():
    """Liveness. It does not touch the database on purpose: if the database has a problem,
    the load balancer should not also remove every copy of the API."""
    return jsonify(status="ok", version=VERSION)


@app.get("/ready")
def ready():
    """Readiness: can this copy reach its database and read the cases table?"""
    try:
        query("SELECT COUNT(*) FROM dbo.cases")
    except Exception:
        app.logger.exception("Readiness check failed")
        return jsonify(status="database unavailable", version=VERSION), 503
    return jsonify(status="ok", version=VERSION)


@app.get("/api/v1/info")
def info():
    row = query("SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(50)), CAST(SERVERPROPERTY('Edition') AS NVARCHAR(100))")[0]
    return jsonify(region=REGION_CODE, version=VERSION, host=socket.gethostname(),
                   database={"name": DB_NAME, "version": f"SQL Server {row[0]} ({row[1]})"})


@app.get("/api/v1/cases")
def list_cases():
    limit = whole_number("limit", 50, 1, MAX_LIMIT)
    offset = whole_number("offset", 0, 0, 1_000_000)
    status = request.args.get("status")
    if status is None:
        where, params = "", ()
    else:
        where, params = "WHERE status = %s", (valid_status(status),)
    total = query(f"SELECT COUNT(*) FROM dbo.cases {where}", params)[0][0]
    rows = query(
        f"SELECT {CASE_COLUMNS} FROM dbo.cases {where} ORDER BY id OFFSET %s ROWS FETCH NEXT %s ROWS ONLY",
        params + (offset, limit),
    )
    return jsonify(items=[case_json(r) for r in rows], total=total, limit=limit, offset=offset)


@app.post("/api/v1/cases")
def create_case():
    body = json_body()
    client = body.get("client")
    if not isinstance(client, str) or not 1 <= len(client.strip()) <= 100:
        raise ApiError(422, "invalid_client", "client is required and must be 1 to 100 characters.")
    status = valid_status(body.get("status", "Open"))
    row = query(
        "INSERT INTO dbo.cases (client, status, opened) "
        "OUTPUT inserted.id, inserted.client, inserted.status, inserted.opened "
        "VALUES (%s, %s, CAST(SYSUTCDATETIME() AS DATE))",
        (client.strip(), status), commit=True,
    )[0]
    created = case_json(row)
    return jsonify(created), 201, {"Location": f"/api/v1/cases/{created['id']}"}


@app.get("/api/v1/cases/<int:case_id>")
def get_case(case_id):
    rows = query(f"SELECT {CASE_COLUMNS} FROM dbo.cases WHERE id = %s", (case_id,))
    if not rows:
        raise ApiError(404, "not_found", f"There is no case {case_id}.")
    return jsonify(case_json(rows[0]))


@app.patch("/api/v1/cases/<int:case_id>")
def update_case(case_id):
    status = valid_status(json_body().get("status"))
    rows = query(
        "UPDATE dbo.cases SET status = %s "
        "OUTPUT inserted.id, inserted.client, inserted.status, inserted.opened WHERE id = %s",
        (status, case_id), commit=True,
    )
    if not rows:
        raise ApiError(404, "not_found", f"There is no case {case_id}.")
    return jsonify(case_json(rows[0]))
