using Microsoft.Data.SqlClient;

namespace Api;

/// <summary>Every SQL statement the API runs. Values are always passed as parameters, never built into the SQL text.</summary>
public sealed class Database
{
    private const string Columns = "id, client, status, opened";
    private readonly string _connectionString;

    public string Name { get; } = Environment.GetEnvironmentVariable("DB_NAME") ?? "demo";

    public Database()
    {
        _connectionString = ConnectionString(
            Environment.GetEnvironmentVariable("DB_USER") ?? "",
            Environment.GetEnvironmentVariable("DB_PASSWORD") ?? "",
            Name, connectTimeout: 5);
    }

    public static string ConnectionString(string user, string password, string database, int connectTimeout) =>
        new SqlConnectionStringBuilder
        {
            DataSource = Environment.GetEnvironmentVariable("DB_HOST") ?? "",
            UserID = user,
            Password = password,
            InitialCatalog = database,
            ConnectTimeout = connectTimeout,
            // The connection is encrypted. The server's certificate is not checked, because the
            // container does not carry the RDS certificate authority. Production adds that
            // certificate to the image and sets TrustServerCertificate to false.
            Encrypt = true,
            TrustServerCertificate = true,
        }.ConnectionString;

    private async Task<SqlConnection> OpenAsync()
    {
        var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync();
        return connection;
    }

    private static Case Read(SqlDataReader row) =>
        new(row.GetInt32(0), row.GetString(1), row.GetString(2), row.GetDateTime(3).ToString("yyyy-MM-dd"));

    private static async Task<Case?> FirstAsync(SqlCommand command)
    {
        await using var row = await command.ExecuteReaderAsync();
        return await row.ReadAsync() ? Read(row) : null;
    }

    public async Task<string> ServerVersionAsync()
    {
        await using var connection = await OpenAsync();
        await using var command = new SqlCommand(
            "SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(50)), CAST(SERVERPROPERTY('Edition') AS NVARCHAR(100))", connection);
        await using var row = await command.ExecuteReaderAsync();
        await row.ReadAsync();
        return $"SQL Server {row.GetString(0)} ({row.GetString(1)})";
    }

    public async Task<int> CountCasesAsync(string? status)
    {
        await using var connection = await OpenAsync();
        await using var command = new SqlCommand(
            "SELECT COUNT(*) FROM dbo.cases WHERE (@status IS NULL OR status = @status)", connection);
        command.Parameters.AddWithValue("@status", (object?)status ?? DBNull.Value);
        return (int)(await command.ExecuteScalarAsync())!;
    }

    public async Task<List<Case>> ListCasesAsync(string? status, int offset, int limit)
    {
        await using var connection = await OpenAsync();
        await using var command = new SqlCommand(
            $"SELECT {Columns} FROM dbo.cases WHERE (@status IS NULL OR status = @status) " +
            "ORDER BY id OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY", connection);
        command.Parameters.AddWithValue("@status", (object?)status ?? DBNull.Value);
        command.Parameters.AddWithValue("@offset", offset);
        command.Parameters.AddWithValue("@limit", limit);

        var cases = new List<Case>();
        await using var row = await command.ExecuteReaderAsync();
        while (await row.ReadAsync()) cases.Add(Read(row));
        return cases;
    }

    public async Task<Case?> GetCaseAsync(int id)
    {
        await using var connection = await OpenAsync();
        await using var command = new SqlCommand($"SELECT {Columns} FROM dbo.cases WHERE id = @id", connection);
        command.Parameters.AddWithValue("@id", id);
        return await FirstAsync(command);
    }

    public async Task<Case> CreateCaseAsync(string client, string status)
    {
        await using var connection = await OpenAsync();
        await using var command = new SqlCommand(
            "INSERT INTO dbo.cases (client, status, opened) " +
            "OUTPUT inserted.id, inserted.client, inserted.status, inserted.opened " +
            "VALUES (@client, @status, CAST(SYSUTCDATETIME() AS DATE))", connection);
        command.Parameters.AddWithValue("@client", client);
        command.Parameters.AddWithValue("@status", status);
        return (await FirstAsync(command))!;
    }

    public async Task<Case?> UpdateStatusAsync(int id, string status)
    {
        await using var connection = await OpenAsync();
        await using var command = new SqlCommand(
            "UPDATE dbo.cases SET status = @status " +
            "OUTPUT inserted.id, inserted.client, inserted.status, inserted.opened WHERE id = @id", connection);
        command.Parameters.AddWithValue("@status", status);
        command.Parameters.AddWithValue("@id", id);
        return await FirstAsync(command);
    }
}
