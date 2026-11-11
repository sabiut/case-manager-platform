namespace Api;

/// <summary>An error the caller caused or can understand. Turned into the standard JSON error shape.</summary>
public sealed class ApiError(int status, string code, string message) : Exception(message)
{
    public int Status { get; } = status;
    public string Code { get; } = code;
}

public sealed record Case(int Id, string Client, string Status, string Opened);

/// <summary>The rules for what a caller may send. No database or web code here, so it is easy to test.</summary>
public static class CaseRules
{
    public static readonly string[] Statuses = ["Open", "In progress", "Closed"];
    public const int MaxLimit = 100;

    public static string Status(string? value) =>
        value is not null && Statuses.Contains(value)
            ? value
            : throw new ApiError(422, "invalid_status", "status must be one of: " + string.Join(", ", Statuses));

    public static string Client(string? value)
    {
        var trimmed = value?.Trim();
        return trimmed is { Length: >= 1 and <= 100 }
            ? trimmed
            : throw new ApiError(422, "invalid_client", "client is required and must be 1 to 100 characters.");
    }

    public static int WholeNumber(string name, string? raw, int fallback, int lowest, int highest)
    {
        if (string.IsNullOrEmpty(raw)) return fallback;
        if (!int.TryParse(raw, out var value))
            throw new ApiError(422, "invalid_" + name, $"{name} must be a whole number.");
        if (value < lowest || value > highest)
            throw new ApiError(422, "invalid_" + name, $"{name} must be between {lowest} and {highest}.");
        return value;
    }
}
