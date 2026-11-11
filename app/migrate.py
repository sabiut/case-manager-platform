"""Database migration. Run once per deployment as a separate one-off task, BEFORE the new app
version is rolled out, and never by the web app itself.

It signs in with the ADMIN login and does three things, all safe to repeat:
  1. creates the customer database if it is missing
  2. creates the app's restricted login (read and write rows only) and keeps its password in sync
  3. applies any schema changes that have not been applied yet, in order

Rules for schema changes, because the previous app version is still running while this runs:
  - add things first (a new table, a new nullable column); remove old things in a later release
  - add a new numbered entry to MIGRATIONS; never edit an entry that has already been applied

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

# Schema changes, in order: (version, description, SQL).
MIGRATIONS = [
    (1, "create cases table", """
        CREATE TABLE dbo.cases (
            id INT IDENTITY PRIMARY KEY,
            client NVARCHAR(100) NOT NULL,
            status NVARCHAR(20) NOT NULL,
            opened DATE NOT NULL
        )"""),
]

# What migration 1 produces. Used to recognise a database that already has the table
# from before migrations were tracked (an earlier app version created it on its own).
BASELINE_TABLE = "cases"
BASELINE_COLUMNS = {"id", "client", "status", "opened"}

SAMPLE_CASES = [
    ("A. Smith", "Open", "2026-10-01"),
    ("B. Jones", "Closed", "2026-09-12"),
    ("C. Taylor", "Open", "2026-11-03"),
]


def connect(database, autocommit):
    return pymssql.connect(
        server=DB_HOST, user=ADMIN_USER, password=ADMIN_PASSWORD, database=database,
        login_timeout=10, timeout=60, autocommit=autocommit,
    )


def prepare_server():
    """Database and login. CREATE DATABASE cannot run inside a transaction, so this part is
    separate from the schema migrations and each statement is written to be safe to repeat."""
    conn = connect("master", autocommit=True)
    try:
        cur = conn.cursor()
        cur.execute(f"IF DB_ID('{DB_NAME}') IS NULL CREATE DATABASE [{DB_NAME}]")
        cur.execute(f"""
            IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '{APP_USER}')
                CREATE LOGIN [{APP_USER}] WITH PASSWORD = '{APP_PASSWORD}'
            ELSE
                ALTER LOGIN [{APP_USER}] WITH PASSWORD = '{APP_PASSWORD}'""")
    finally:
        conn.close()
    print(f"Database {DB_NAME} and login {APP_USER} are in place")


def adopt_existing_schema(cur):
    """If the cases table already exists but no migration was ever recorded, check that it has
    the expected columns and record migration 1 as applied instead of trying to create it again."""
    cur.execute("SELECT COUNT(*) FROM dbo.schema_migrations")
    if cur.fetchone()[0] != 0:
        return
    cur.execute(
        "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = %s",
        (BASELINE_TABLE,),
    )
    existing = {row[0].lower() for row in cur.fetchall()}
    if not existing:
        return  # no table yet: migration 1 will create it
    missing = BASELINE_COLUMNS - existing
    if missing:
        raise RuntimeError(
            f"dbo.{BASELINE_TABLE} already exists but is missing column(s) {sorted(missing)}. "
            "Refusing to guess. Fix the table by hand or restore it, then run the migration again."
        )
    cur.execute(
        "INSERT INTO dbo.schema_migrations (version, description) VALUES (%s, %s)",
        (1, "create cases table (already existed, recorded as baseline)"),
    )
    print("Found an existing cases table with the expected columns: recorded migration 1 as the baseline")


def migrate_schema():
    conn = connect(DB_NAME, autocommit=False)
    try:
        cur = conn.cursor()

        # Only one migration may run at a time. A second one waits here, then finds nothing left to do.
        cur.execute("""
            DECLARE @result INT;
            EXEC @result = sp_getapplock @Resource = 'schema_migrations', @LockMode = 'Exclusive',
                                         @LockOwner = 'Session', @LockTimeout = 120000;
            IF @result < 0 THROW 50000, 'Could not get the migration lock', 1;""")
        conn.commit()

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
        adopt_existing_schema(cur)
        conn.commit()

        cur.execute("SELECT version FROM dbo.schema_migrations")
        done = {row[0] for row in cur.fetchall()}
        conn.commit()

        for version, description, sql in MIGRATIONS:
            if version in done:
                print(f"Migration {version} ({description}): already applied")
                continue
            # The schema change and its history record succeed together or not at all.
            try:
                cur.execute(sql)
                cur.execute(
                    "INSERT INTO dbo.schema_migrations (version, description) VALUES (%s, %s)",
                    (version, description),
                )
                conn.commit()
            except Exception:
                conn.rollback()
                print(f"Migration {version} ({description}): FAILED, rolled back", file=sys.stderr)
                raise
            print(f"Migration {version} ({description}): applied")

        cur.execute("SELECT COUNT(*) FROM dbo.cases")
        if cur.fetchone()[0] == 0:
            cur.executemany("INSERT INTO dbo.cases (client, status, opened) VALUES (%s, %s, %s)", SAMPLE_CASES)
            print(f"Added {len(SAMPLE_CASES)} sample cases")
        conn.commit()
    finally:
        conn.close()  # also releases the migration lock


def main():
    prepare_server()
    migrate_schema()
    print("Migration finished")


if __name__ == "__main__":
    main()
