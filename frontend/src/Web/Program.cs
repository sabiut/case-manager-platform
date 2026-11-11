// Frontend (web tier). Serves the web pages and nothing else.
//
// It has no database login and cannot reach the database. Everything it shows comes from
// the backend API, which it calls over the private network.
//
// Settings come from environment variables, set by the platform:
//   API_URL        address of the backend API (the internal load balancer)
//   REGION_CODE    au, uk or us, shown on the page

using System.Net;
using System.Text;
using System.Text.Json;

var version = Environment.GetEnvironmentVariable("APP_VERSION") ?? "dev";
var region = Environment.GetEnvironmentVariable("REGION_CODE") ?? "local";
var apiUrl = (Environment.GetEnvironmentVariable("API_URL") ?? "http://localhost:8081").TrimEnd('/');

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(o => o.Limits.MaxRequestBodySize = 16 * 1024);
builder.Services.AddHttpClient("api", client =>
{
    client.BaseAddress = new Uri(apiUrl);
    client.Timeout = TimeSpan.FromSeconds(10);
});

var app = builder.Build();

// Calls the backend API and returns its JSON answer, or null if the call failed. Never throws.
async Task<JsonElement?> Api(HttpMethod method, string path, object? body = null)
{
    try
    {
        var client = app.Services.GetRequiredService<IHttpClientFactory>().CreateClient("api");
        using var request = new HttpRequestMessage(method, path);
        if (body is not null) request.Content = JsonContent.Create(body);
        using var response = await client.SendAsync(request);
        if (!response.IsSuccessStatusCode)
        {
            app.Logger.LogWarning("The backend API answered {Status} to {Method} {Path}", (int)response.StatusCode, method, path);
            return null;
        }
        return await response.Content.ReadFromJsonAsync<JsonElement>();
    }
    catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException)
    {
        // The detail goes to the server log (CloudWatch). The visitor sees only a general message.
        app.Logger.LogError(e, "Call to the backend API failed: {Method} {Path}", method, path);
        return null;
    }
}

// Liveness. It does not call the API on purpose: if the API has a problem,
// the load balancer should not also remove every copy of the frontend.
app.MapGet("/health", () => Results.Json(new { status = "ok", version }));

// Readiness of the whole chain: frontend -> API -> database.
// Used by the deployment pipeline as the smoke test before it moves on to the next region.
// Reports both versions, so the pipeline can prove the new frontend AND the new API answered.
app.MapGet("/ready", async () =>
{
    var answer = await Api(HttpMethod.Get, "/ready");
    if (answer is { } ready && ready.GetProperty("status").GetString() == "ok")
    {
        return Results.Json(new { status = "ok", version, api_version = ready.GetProperty("version").GetString() });
    }
    return Results.Json(new { status = "backend unavailable", version, api_version = (string?)null }, statusCode: 503);
});

app.MapGet("/", async (HttpRequest request) =>
{
    var info = await Api(HttpMethod.Get, "/api/v1/info");
    var cases = info is null ? null : await Api(HttpMethod.Get, "/api/v1/cases?limit=100");
    var failed = request.Query["failed"] == "1";
    return Results.Content(Page.Render(region, version, Environment.MachineName, info, cases, failed), "text/html; charset=utf-8");
});

app.MapPost("/cases", async (HttpRequest request) =>
{
    var form = await request.ReadFormAsync();
    var created = await Api(HttpMethod.Post, "/api/v1/cases", new { client = form["client"].ToString() });
    return Results.Redirect(created is null ? "/?failed=1" : "/");
});

app.MapPost("/cases/{id:int}/close", async (int id) =>
{
    var updated = await Api(HttpMethod.Patch, $"/api/v1/cases/{id}", new { status = "Closed" });
    return Results.Redirect(updated is null ? "/?failed=1" : "/");
});

app.Run();

static class Page
{
    // Everything that came from the API or the database is passed through this before it goes
    // into the page, so text such as <script> is shown as text and never run by the browser.
    private static string E(string? text) => WebUtility.HtmlEncode(text ?? "");

    public static string Render(string region, string version, string host, JsonElement? info, JsonElement? cases, bool failed)
    {
        var html = new StringBuilder("""
            <!doctype html>
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

            """);

        if (failed) html.Append("<p class=\"bad\">That change could not be saved. Please try again.</p>\n");

        html.Append("<dl>\n");
        html.Append($"  <dt>Region</dt><dd>{E(region)}</dd>\n");
        html.Append($"  <dt>Frontend</dt><dd>version {E(version)}, answered by {E(host)}</dd>\n");
        html.Append("  <dt>Backend API</dt>\n");
        if (info is { } api)
        {
            var database = api.GetProperty("database");
            html.Append($"  <dd><span class=\"ok\">Connected</span>, version {E(api.GetProperty("version").GetString())}, answered by {E(api.GetProperty("host").GetString())}</dd>\n");
            html.Append($"  <dt>Database</dt><dd>{E(database.GetProperty("name").GetString())} on {E(database.GetProperty("version").GetString())}</dd>\n");
        }
        else
        {
            html.Append("  <dd><span class=\"bad\">The service is not available right now.</span></dd>\n");
        }
        html.Append("</dl>\n");

        if (info is not null)
        {
            html.Append("""
                <h2>Cases</h2>
                <form class="add" method="post" action="/cases">
                  <label>New case for client <input name="client" maxlength="100" required></label>
                  <button>Add</button>
                </form>
                <table>
                  <tr><th>ID</th><th>Client</th><th>Status</th><th>Opened</th><th></th></tr>

                """);
            if (cases is { } listing)
            {
                foreach (var item in listing.GetProperty("items").EnumerateArray())
                {
                    var id = item.GetProperty("id").GetInt32();
                    var status = item.GetProperty("status").GetString();
                    var close = status == "Closed" ? "" : $"<form class=\"inline\" method=\"post\" action=\"/cases/{id}/close\"><button>Close</button></form>";
                    html.Append($"  <tr><td>{id}</td><td>{E(item.GetProperty("client").GetString())}</td><td>{E(status)}</td><td>{E(item.GetProperty("opened").GetString())}</td><td>{close}</td></tr>\n");
                }
            }
            html.Append("</table>\n");
        }
        return html.ToString();
    }
}
