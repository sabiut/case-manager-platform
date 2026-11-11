"""Small three-tier demo app: a web page that lists cases from a customer's SQL Server database.

Settings come from environment variables, set by the platform:
  DB_HOST, DB_USER, DB_PASSWORD   where the database is and how to sign in
  DB_NAME                         the customer database to read (default: demo)
  REGION_CODE                     au, uk or us, shown on the page
"""
import os
import re
import socket

import pymssql
from flask import Flask, render_template_string

DB_HOST = os.environ.get("DB_HOST", "")
DB_USER = os.environ.get("DB_USER", "")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_NAME = os.environ.get("DB_NAME", "demo")
REGION_CODE = os.environ.get("REGION_CODE", "local")
VERSION = os.environ.get("APP_VERSION", "dev")

# The name is placed into SQL text below, so allow only letters, digits, - and _.
if not re.fullmatch(r"[A-Za-z0-9_-]{1,60}", DB_NAME):
    raise SystemExit(f"DB_NAME '{DB_NAME}' is not a valid database name")

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
  <dd>{% if error %}<span class="bad">Not reachable: {{ error }}</span>
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


def connect(database):
    return pymssql.connect(
        server=DB_HOST, user=DB_USER, password=DB_PASSWORD, database=database,
        login_timeout=5, timeout=10, autocommit=True,
    )


def ensure_schema():
    """Create the customer database, its table and a few sample rows if they are missing.

    Lab shortcut: a real product runs schema changes as a separate, reviewed pipeline step,
    and the app signs in with a login limited to its own database, not the admin login.
    """
    conn = connect("master")
    try:
        conn.cursor().execute(f"IF DB_ID('{DB_NAME}') IS NULL CREATE DATABASE [{DB_NAME}]")
    finally:
        conn.close()

    conn = connect(DB_NAME)
    try:
        cur = conn.cursor()
        cur.execute("""
            IF OBJECT_ID('dbo.cases') IS NULL
            CREATE TABLE dbo.cases (
                id INT IDENTITY PRIMARY KEY,
                client NVARCHAR(100) NOT NULL,
                status NVARCHAR(20) NOT NULL,
                opened DATE NOT NULL
            )""")
        cur.execute("SELECT COUNT(*) FROM dbo.cases")
        if cur.fetchone()[0] == 0:
            cur.executemany(
                "INSERT INTO dbo.cases (client, status, opened) VALUES (%s, %s, %s)",
                [("A. Smith", "Open", "2026-10-01"),
                 ("B. Jones", "Closed", "2026-09-12"),
                 ("C. Taylor", "Open", "2026-11-03")],
            )
    finally:
        conn.close()


@app.get("/health")
def health():
    # Used by the load balancer. It does not touch the database on purpose:
    # if the database has a problem, the load balancer should not also kill every app copy.
    return "ok"


@app.get("/")
def index():
    cases, db_version, error = [], "", ""
    try:
        ensure_schema()
        conn = connect(DB_NAME)
        try:
            cur = conn.cursor()
            cur.execute("SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(50)), CAST(SERVERPROPERTY('Edition') AS NVARCHAR(100))")
            row = cur.fetchone()
            db_version = f"SQL Server {row[0]} ({row[1]})"
            cur.execute("SELECT id, client, status, opened FROM dbo.cases ORDER BY id")
            cases = cur.fetchall()
        finally:
            conn.close()
    except Exception as exc:  # show the problem on the page instead of a blank error
        error = str(exc)[:300]
    return render_template_string(
        PAGE, region=REGION_CODE, host=socket.gethostname(), version=VERSION,
        db_name=DB_NAME, db_version=db_version, cases=cases, error=error,
    )
