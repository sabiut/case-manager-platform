// Backend API (application tier). JSON only, no web pages.
//
// It is the only part of the system that talks to the database, and it is not reachable from
// the internet: only the frontend can call it, through an internal load balancer.
//
// Endpoints:
//   GET   /health                 is this copy running? (used by the load balancer, no database call)
//   GET   /ready                  can this copy reach its database? (used by the deployment pipeline)
//   GET   /api/v1/info            region, version and database version
//   GET   /api/v1/cases           list cases. Optional: ?status=Open&limit=50&offset=0
//   POST  /api/v1/cases           create a case. Body: {"client": "A. Smith", "status": "Open"}
//   GET   /api/v1/cases/{id}      one case
//   PATCH /api/v1/cases/{id}      change the status. Body: {"status": "Closed"}
//
// Every error has the same shape:  {"error": {"code": "not_found", "message": "..."}}
//
// Settings come from environment variables, set by the platform:
//   DB_HOST                 where the database is
//   DB_USER, DB_PASSWORD    the API's own restricted login (read and write rows, nothing else)
//   DB_NAME                 the customer database (default: demo)
//   REGION_CODE             au, uk or us
//
// The same program also runs the database migration when started with the argument "migrate"
// (see Migrator.cs). The running API never creates or changes the schema.
// There is no sign-in in this lab. A real API would check who the caller is on every request.

using System.Net;
using System.Text.Json;
using Api;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.Data.SqlClient;

if (args is ["migrate"])
{
    return await Migrator.RunAsync();
}

var version = Environment.GetEnvironmentVariable("APP_VERSION") ?? "dev";
var region = Environment.GetEnvironmentVariable("REGION_CODE") ?? "local";

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(o => o.Limits.MaxRequestBodySize = 16 * 1024); // bodies here are tiny; refuse anything large
builder.Services.AddSingleton<Database>();

var app = builder.Build();

// ---- Errors: always the same JSON shape ----

static IResult Error(int status, string code, string message) =>
    Results.Json(new { error = new { code, message } }, statusCode: status);

// Anything unexpected. The detail goes to the server log (CloudWatch). The caller sees only a general message.
app.UseExceptionHandler(new ExceptionHandlerOptions
{
    ExceptionHandler = async context =>
    {
        var problem = context.Features.Get<IExceptionHandlerFeature>()?.Error;
        var result = problem switch
        {
            SqlException => Error(503, "database_unavailable", "The database is not available right now."),
            BadHttpRequestException { StatusCode: 413 } => Error(413, "request_too_large", "The request body is too large."),
            _ => Error(500, "internal_error", "Something went wrong."),
        };
        await result.ExecuteAsync(context);
    },
});

// A mistake by the caller (bad input, unknown case). Not a server fault, so it is not logged as an error.
app.Use(async (context, next) =>
{
    try
    {
        await next(context);
    }
    catch (ApiError e)
    {
        await Error(e.Status, e.Code, e.Message).ExecuteAsync(context);
    }
});

// Unknown address or wrong method: still answer in the standard JSON shape.
app.UseStatusCodePages(async pages =>
{
    var status = pages.HttpContext.Response.StatusCode;
    var code = status switch { 404 => "not_found", 405 => "method_not_allowed", _ => "error" };
    await Error(status, code, ((HttpStatusCode)status).ToString()).ExecuteAsync(pages.HttpContext);
});

// ---- Health ----

// Liveness. It does not touch the database on purpose: if the database has a problem,
// the load balancer should not also remove every copy of the API.
app.MapGet("/health", () => Results.Json(new { status = "ok", version }));

// Readiness: can this copy reach its database and read the cases table?
app.MapGet("/ready", async (Database db, ILogger<Program> log) =>
{
    try
    {
        await db.CountCasesAsync(null);
        return Results.Json(new { status = "ok", version });
    }
    catch (Exception e)
    {
        log.LogError(e, "Readiness check failed");
        return Results.Json(new { status = "database unavailable", version }, statusCode: 503);
    }
});

// ---- API ----

var api = app.MapGroup("/api/v1");

api.MapGet("/info", async (Database db) => Results.Json(new
{
    region,
    version,
    host = Environment.MachineName,
    database = new { name = db.Name, version = await db.ServerVersionAsync() },
}));

api.MapGet("/cases", async (HttpRequest request, Database db) =>
{
    var limit = CaseRules.WholeNumber("limit", request.Query["limit"], 50, 1, CaseRules.MaxLimit);
    var offset = CaseRules.WholeNumber("offset", request.Query["offset"], 0, 0, 1_000_000);
    string? status = request.Query.ContainsKey("status") ? CaseRules.Status(request.Query["status"]) : null;

    var total = await db.CountCasesAsync(status);
    var items = await db.ListCasesAsync(status, offset, limit);
    return Results.Json(new { items, total, limit, offset });
});

api.MapPost("/cases", async (HttpRequest request, Database db) =>
{
    var body = await ReadBody(request);
    var client = CaseRules.Client(Text(body, "client"));
    var status = body.TryGetProperty("status", out _) ? CaseRules.Status(Text(body, "status")) : "Open";

    var created = await db.CreateCaseAsync(client, status);
    return Results.Json(created, statusCode: 201).WithLocation($"/api/v1/cases/{created.Id}");
});

api.MapGet("/cases/{id:int}", async (int id, Database db) =>
    Results.Json(await db.GetCaseAsync(id) ?? throw new ApiError(404, "not_found", $"There is no case {id}.")));

api.MapPatch("/cases/{id:int}", async (int id, HttpRequest request, Database db) =>
{
    var status = CaseRules.Status(Text(await ReadBody(request), "status"));
    return Results.Json(await db.UpdateStatusAsync(id, status) ?? throw new ApiError(404, "not_found", $"There is no case {id}."));
});

app.Run();
return 0;

// ---- Helpers ----

static async Task<JsonElement> ReadBody(HttpRequest request)
{
    try
    {
        using var document = await JsonDocument.ParseAsync(request.Body);
        if (document.RootElement.ValueKind == JsonValueKind.Object) return document.RootElement.Clone();
    }
    catch (JsonException) { }
    throw new ApiError(400, "invalid_body", "The request body must be a JSON object.");
}

// The value of a property if it is text, otherwise null (missing, a number, a list and so on).
static string? Text(JsonElement body, string name) =>
    body.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

static class ResultExtensions
{
    public static IResult WithLocation(this IResult result, string location) => new LocationResult(result, location);

    private sealed class LocationResult(IResult inner, string location) : IResult
    {
        public Task ExecuteAsync(HttpContext context)
        {
            context.Response.Headers.Location = location;
            return inner.ExecuteAsync(context);
        }
    }
}

public partial class Program;
