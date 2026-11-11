"""Database migration. Run once per deployment as a separate one-off task, never by the web app.

It signs in with the ADMIN login and does three things, all safe to repeat:
  1. creates the customer database if it is missing
  2. creates the app's restricted login (read and write rows only) and keeps its password in sync
  3. applies any schema changes that have not been applied yet, in order

Environment variables:
  DB_HOST, DB_ADMIN_USER, DB_ADMIN_PASSWORD   admin access, given only to this task
  DB_NAME                                     the customer database (default: demo)
  APP_DB_USER, APP_DB_PASSWORD                the login the web app will use
"""
import os
import re
import sys

import pymssql

DB_HOST = os.environ["DB_HOST"]
ADMIN_USER = os.environ["DB_ADMIN_USER"]
ADMIN_PASSWORD = os.environ["DB_ADMIN_PASSWORD"]
DB_NAME = os.environ.get("DB_NAME", "demo")
APP_USER = os.environ["APP_DB_USER"]
APP_PASSWORD = os.environ["APP_DB_PASSWORD"]

# These three values are placed into SQL text (CREATE DATABASE and CREATE LOGIN cannot take
# parameters), so only a strict set of characters is accepted.
for label, value, pattern in [
    ("DB_NAME", DB_NAME, r"[A-Za-z0-9_-]{1,60}"),
    ("APP_DB_USER", APP_USER, r"[A-Za-z0-9_]{1,60}"),
    ("APP_DB_PASSWORD", APP_PASSWORD, r"[A-Za-z0-9]{16,128}"),
]:
    if not re.fullmatch(pattern, value):
        sys.exit(f"{label} contains characters that are not allowed")

# Schema changes, in order. To change the schema, add a new numbered entry. Never edit an old one.
MIGRATIONS = [
    (1, "create cases table", """
        CREATE TABLE dbo.cases (
            id INT IDENTITY PRIMARY KEY,
            client NVARCHAR(100) NOT NULL,
            status NVARCHAR(20) NOT NULL,
            opened DATE NOT NULL
        )"""),
]

SAMPLE_CASES = [
    ("A. Smith", "Open", "2026-10-01"),
    ("B. Jones", "Closed", "2026-09-12"),
    ("C. Taylor", "Open", "2026-11-03"),
]


def connect(database):
    return pymssql.connect(
        server=DB_HOST, user=ADMIN_USER, password=ADMIN_PASSWORD, database=database,
        login_timeout=10, timeout=60, autocommit=True,
    )


def main():
    server = connect("master")
    cur = server.cursor()
    cur.execute(f"IF DB_ID('{DB_NAME}') IS NULL CREATE DATABASE [{DB_NAME}]")
    cur.execute(f"""
        IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '{APP_USER}')
            CREATE LOGIN [{APP_USER}] WITH PASSWORD = '{APP_PASSWORD}'
        ELSE
            ALTER LOGIN [{APP_USER}] WITH PASSWORD = '{APP_PASSWORD}'""")
    server.close()
    print(f"Database {DB_NAME} and login {APP_USER} are in place")

    db = connect(DB_NAME)
    cur = db.cursor()
    cur.execute(f"""
        IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '{APP_USER}')
            CREATE USER [{APP_USER}] FOR LOGIN [{APP_USER}]""")
    cur.execute(f"ALTER ROLE db_datareader ADD MEMBER [{APP_USER}]")
    cur.execute(f"ALTER ROLE db_datawriter ADD MEMBER [{APP_USER}]")

    cur.execute("""
        IF OBJECT_ID('dbo.schema_migrations') IS NULL
        CREATE TABLE dbo.schema_migrations (
            version INT PRIMARY KEY,
            description NVARCHAR(200) NOT NULL,
            applied_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
        )""")
    cur.execute("SELECT version FROM dbo.schema_migrations")
    done = {row[0] for row in cur.fetchall()}
    for version, description, sql in MIGRATIONS:
        if version in done:
            print(f"Migration {version} ({description}): already applied")
            continue
        cur.execute(sql)
        cur.execute("INSERT INTO dbo.schema_migrations (version, description) VALUES (%s, %s)", (version, description))
        print(f"Migration {version} ({description}): applied")

    cur.execute("SELECT COUNT(*) FROM dbo.cases")
    if cur.fetchone()[0] == 0:
        cur.executemany("INSERT INTO dbo.cases (client, status, opened) VALUES (%s, %s, %s)", SAMPLE_CASES)
        print(f"Added {len(SAMPLE_CASES)} sample cases")
    db.close()
    print("Migration finished")


if __name__ == "__main__":
    main()
