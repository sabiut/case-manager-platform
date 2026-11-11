using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

namespace Api;

/// <summary>
/// Database migration. Run once per deployment as a separate one-off task (the API image started
/// with the argument "migrate"), BEFORE the new version is rolled out, and never by the running API.
///
/// It signs in with the ADMIN login and does three things, all safe to repeat:
///   1. creates the customer database if it is missing
///   2. creates the API's restricted login (read and write rows only) and keeps its password in sync
///   3. applies any schema changes that have not been applied yet, in order
///
/// Rules for schema changes, because the previous version is still running while this runs:
///   - add things first (a new table, a new nullable column); remove old things in a later release
///   - add a new numbered entry to Migrations; never edit an entry that has already been applied
///
/// Environment variables:
///   DB_HOST, DB_ADMIN_USER, DB_ADMIN_PASSWORD   admin access, given only to this task
///   DB_NAME                                     the customer database (default: demo)
///   APP_DB_USER, APP_DB_PASSWORD                the login the API will use
/// </summary>
public static class Migrator
{
    // Schema changes, in order.
    private static readonly (int Version, string Description, string Sql)[] Migrations =
    [
        (1, "create cases table", """
            CREATE TABLE dbo.cases (
                id INT IDENTITY PRIMARY KEY,
                client NVARCHAR(100) NOT NULL,
                status NVARCHAR(20) NOT NULL,
                opened DATE NOT NULL
            )
            """),
    ];

    // What migration 1 produces. Used to recognise a database that already has the table
    // from before migrations were tracked.
    private const string BaselineTable = "cases";
    private static readonly string[] BaselineColumns = ["id", "client", "status", "opened"];

    private static readonly (string Client, string Status, string Opened)[] SampleCases =
    [
        ("A. Smith", "Open", "2026-10-01"),
        ("B. Jones", "Closed", "2026-09-12"),
        ("C. Taylor", "Open", "2026-11-03"),
    ];

    public static async Task<int> RunAsync()
    {
        try
        {
            var adminUser = Required("DB_ADMIN_USER");
            var adminPassword = Required("DB_ADMIN_PASSWORD");
            var database = Environment.GetEnvironmentVariable("DB_NAME") ?? "demo";
            var appUser = Required("APP_DB_USER");
            var appPassword = Required("APP_DB_PASSWORD");
            Required("DB_HOST");

            // These three values are placed into SQL text (CREATE DATABASE and CREATE LOGIN cannot
            // take parameters), so only a strict set of characters is accepted.
            Check("DB_NAME", database, "^[A-Za-z0-9_-]{1,60}$");
            Check("APP_DB_USER", appUser, "^[A-Za-z0-9_]{1,60}$");
            Check("APP_DB_PASSWORD", appPassword, "^[A-Za-z0-9]{16,128}$");

            await PrepareServerAsync(adminUser, adminPassword, database, appUser, appPassword);
            await MigrateSchemaAsync(adminUser, adminPassword, database, appUser);
            Console.WriteLine("Migration finished");
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"Migration FAILED: {e.Message}");
            return 1;
        }
    }

    private static string Required(string name) =>
        Environment.GetEnvironmentVariable(name) is { Length: > 0 } value
            ? value
            : throw new InvalidOperationException($"{name} is not set");

    private static void Check(string label, string value, string pattern)
    {
        if (!Regex.IsMatch(value, pattern))
            throw new InvalidOperationException($"{label} contains characters that are not allowed");
    }

    private static async Task ExecuteAsync(SqlConnection connection, SqlTransaction? transaction, string sql, params (string Name, object Value)[] parameters)
    {
        await using var command = new SqlCommand(sql, connection, transaction) { CommandTimeout = 150 };
        foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
        await command.ExecuteNonQueryAsync();
    }

    /// <summary>Database and login. CREATE DATABASE cannot run inside a transaction, so this part is
    /// separate from the schema migrations and each statement is written to be safe to repeat.</summary>
    private static async Task PrepareServerAsync(string adminUser, string adminPassword, string database, string appUser, string appPassword)
    {
        await using var connection = new SqlConnection(Database.ConnectionString(adminUser, adminPassword, "master", connectTimeout: 10));
        await connection.OpenAsync();
        await ExecuteAsync(connection, null, $"IF DB_ID('{database}') IS NULL CREATE DATABASE [{database}]");
        await ExecuteAsync(connection, null, $"""
            IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '{appUser}')
                CREATE LOGIN [{appUser}] WITH PASSWORD = '{appPassword}'
            ELSE
                ALTER LOGIN [{appUser}] WITH PASSWORD = '{appPassword}'
            """);
        Console.WriteLine($"Database {database} and login {appUser} are in place");
    }

    private static async Task MigrateSchemaAsync(string adminUser, string adminPassword, string database, string appUser)
    {
        await using var connection = new SqlConnection(Database.ConnectionString(adminUser, adminPassword, database, connectTimeout: 10));
        await connection.OpenAsync();

        // Only one migration may run at a time. A second one waits here, then finds nothing left to do.
        // The lock belongs to this connection and is released when the connection closes.
        await ExecuteAsync(connection, null, """
            DECLARE @result INT;
            EXEC @result = sp_getapplock @Resource = 'schema_migrations', @LockMode = 'Exclusive',
                                         @LockOwner = 'Session', @LockTimeout = 120000;
            IF @result < 0 THROW 50000, 'Could not get the migration lock', 1;
            """);

        // The database user, its permissions and the history table.
        await using (var setup = (SqlTransaction)await connection.BeginTransactionAsync())
        {
            await ExecuteAsync(connection, setup, $"""
                IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '{appUser}')
                    CREATE USER [{appUser}] FOR LOGIN [{appUser}]
                """);
            await ExecuteAsync(connection, setup, $"ALTER ROLE db_datareader ADD MEMBER [{appUser}]");
            await ExecuteAsync(connection, setup, $"ALTER ROLE db_datawriter ADD MEMBER [{appUser}]");
            await ExecuteAsync(connection, setup, """
                IF OBJECT_ID('dbo.schema_migrations') IS NULL
                CREATE TABLE dbo.schema_migrations (
                    version INT PRIMARY KEY,
                    description NVARCHAR(200) NOT NULL,
                    applied_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
                )
                """);
            await AdoptExistingSchemaAsync(connection, setup);
            await setup.CommitAsync();
        }

        var done = new HashSet<int>();
        await using (var command = new SqlCommand("SELECT version FROM dbo.schema_migrations", connection))
        await using (var row = await command.ExecuteReaderAsync())
        {
            while (await row.ReadAsync()) done.Add(row.GetInt32(0));
        }

        foreach (var (version, description, sql) in Migrations)
        {
            if (done.Contains(version))
            {
                Console.WriteLine($"Migration {version} ({description}): already applied");
                continue;
            }
            // The schema change and its history record succeed together or not at all.
            await using var step = (SqlTransaction)await connection.BeginTransactionAsync();
            try
            {
                await ExecuteAsync(connection, step, sql);
                await ExecuteAsync(connection, step,
                    "INSERT INTO dbo.schema_migrations (version, description) VALUES (@version, @description)",
                    ("@version", version), ("@description", description));
                await step.CommitAsync();
            }
            catch
            {
                await step.RollbackAsync();
                Console.Error.WriteLine($"Migration {version} ({description}): FAILED, rolled back");
                throw;
            }
            Console.WriteLine($"Migration {version} ({description}): applied");
        }

        await using var seed = (SqlTransaction)await connection.BeginTransactionAsync();
        await using var count = new SqlCommand("SELECT COUNT(*) FROM dbo.cases", connection, seed);
        if ((int)(await count.ExecuteScalarAsync())! == 0)
        {
            foreach (var (client, status, opened) in SampleCases)
            {
                await ExecuteAsync(connection, seed,
                    "INSERT INTO dbo.cases (client, status, opened) VALUES (@client, @status, @opened)",
                    ("@client", client), ("@status", status), ("@opened", opened));
            }
            Console.WriteLine($"Added {SampleCases.Length} sample cases");
        }
        await seed.CommitAsync();
    }

    /// <summary>If the cases table already exists but no migration was ever recorded, check that it has
    /// the expected columns and record migration 1 as applied instead of trying to create it again.</summary>
    private static async Task AdoptExistingSchemaAsync(SqlConnection connection, SqlTransaction transaction)
    {
        await using (var recorded = new SqlCommand("SELECT COUNT(*) FROM dbo.schema_migrations", connection, transaction))
        {
            if ((int)(await recorded.ExecuteScalarAsync())! != 0) return;
        }

        var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        await using (var columns = new SqlCommand(
            "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = @table", connection, transaction))
        {
            columns.Parameters.AddWithValue("@table", BaselineTable);
            await using var row = await columns.ExecuteReaderAsync();
            while (await row.ReadAsync()) existing.Add(row.GetString(0));
        }
        if (existing.Count == 0) return; // no table yet: migration 1 will create it

        var missing = BaselineColumns.Where(column => !existing.Contains(column)).ToArray();
        if (missing.Length > 0)
        {
            throw new InvalidOperationException(
                $"dbo.{BaselineTable} already exists but is missing column(s) {string.Join(", ", missing)}. " +
                "Refusing to guess. Fix the table by hand or restore it, then run the migration again.");
        }

        await ExecuteAsync(connection, transaction,
            "INSERT INTO dbo.schema_migrations (version, description) VALUES (@version, @description)",
            ("@version", 1), ("@description", "create cases table (already existed, recorded as baseline)"));
        Console.WriteLine("Found an existing cases table with the expected columns: recorded migration 1 as the baseline");
    }
}
