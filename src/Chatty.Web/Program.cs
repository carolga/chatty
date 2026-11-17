using System.Security.Claims;
using System.Security.Cryptography;
using System.Text.Json.Serialization;
using System.Threading.RateLimiting;
using Azure.AI.TextAnalytics;
using Azure.Core;
using Azure.Identity;
using Chatty.Web;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Web;
using Microsoft.Identity.Web.UI;

var builder = WebApplication.CreateBuilder(new WebApplicationOptions
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory,
    WebRootPath = "wwwroot"
});
var uiRoot = Path.Combine(AppContext.BaseDirectory, "wwwroot");
var uiAssets = WebAssets.Validate(uiRoot);
var applicationHash = Convert.ToHexString(SHA256.HashData(
    File.ReadAllBytes(typeof(Program).Assembly.Location))).ToLowerInvariant();
builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(o =>
{
    o.SingleLine = true;
    o.IncludeScopes = true;
    o.TimestampFormat = "yyyy-MM-ddTHH:mm:ssZ ";
    o.UseUtcTimestamp = true;
});
builder.Logging.AddFilter("Microsoft", LogLevel.Warning);
builder.Logging.AddFilter("Azure", LogLevel.None);
builder.Logging.AddFilter("System.Net.Http.HttpClient", LogLevel.None);
builder.WebHost.ConfigureKestrel(o =>
{
    o.AddServerHeader = false;
    o.Limits.MaxRequestBodySize = 16_384;
});
builder.Services.ConfigureHttpJsonOptions(o =>
    o.SerializerOptions.UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow);
builder.Services.AddOptions<ChattyOptions>().BindConfiguration("Chatty")
    .Validate(o => o.IsValid(), "Chatty configuration is missing or invalid. See README.")
    .ValidateOnStart();
builder.Services.AddOptions<IdentitySettings>().BindConfiguration("AzureAd")
    .Validate(o => Guid.TryParse(o.TenantId, out _) && Guid.TryParse(o.ClientId, out _),
        "Set AzureAd:TenantId and AzureAd:ClientId to your single-tenant app registration.")
    .ValidateOnStart();
builder.Services.AddAuthentication(OpenIdConnectDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApp(builder.Configuration.GetSection("AzureAd"))
    .EnableTokenAcquisitionToCallDownstreamApi()
    .AddInMemoryTokenCaches();
builder.Services.AddControllersWithViews().AddMicrosoftIdentityUI();
builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedProto;
    o.ForwardLimit = 1;
    if (builder.Configuration["Chatty:TrustedProxyNetwork"] is { Length: > 0 } network)
        o.KnownIPNetworks.Add(System.Net.IPNetwork.Parse(network));
});
// Microsoft.Identity.Web constructs its token handler from its own named options.
builder.Services.Configure<MicrosoftIdentityOptions>(OpenIdConnectDefaults.AuthenticationScheme,
    o => o.MapInboundClaims = false);
builder.Services.Configure<OpenIdConnectOptions>(OpenIdConnectDefaults.AuthenticationScheme, o =>
{
    o.MapInboundClaims = false;
    o.TokenValidationParameters.NameClaimType = "oid";
    o.TokenValidationParameters.RoleClaimType = "roles";
    o.SaveTokens = false;
    o.Events.OnRemoteFailure = context =>
    {
        context.HandleResponse();
        context.Response.Redirect("/auth-error");
        return Task.CompletedTask;
    };
});
builder.Services.Configure<CookieAuthenticationOptions>(CookieAuthenticationDefaults.AuthenticationScheme, o =>
{
    // Discard older tickets whose claim names were mapped by the previous handler.
    o.Cookie.Name = "__Host-Chatty-v2";
    o.Cookie.HttpOnly = true;
    o.Cookie.SecurePolicy = CookieSecurePolicy.Always;
    o.Cookie.SameSite = SameSiteMode.Lax;
    o.ExpireTimeSpan = TimeSpan.FromMinutes(20);
    o.SlidingExpiration = false;
});
builder.Services.AddAuthorizationBuilder()
    .SetFallbackPolicy(new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build())
    .AddPolicy("Employee", policy => policy.RequireAuthenticatedUser().RequireAssertion(context =>
        EmployeeAccess.IsAllowed(context.User, builder.Configuration["AzureAd:TenantId"]!)));
builder.Services.AddAntiforgery(o =>
{
    o.HeaderName = "X-CHATTY-CSRF";
    o.Cookie.Name = "__Host-Chatty-Csrf";
    o.Cookie.SecurePolicy = CookieSecurePolicy.Always;
    o.Cookie.HttpOnly = true;
    o.Cookie.SameSite = SameSiteMode.Strict;
});
builder.Services.AddMemoryCache(o => o.SizeLimit = 1024);
builder.Services.AddSingleton<ConversationStore>();
builder.Services.AddSingleton<TokenCredential>(services =>
{
    var config = services.GetRequiredService<IOptions<ChattyOptions>>().Value;
    return builder.Environment.IsDevelopment()
        ? new AzureCliCredential(new AzureCliCredentialOptions { TenantId = builder.Configuration["AzureAd:TenantId"] })
        : string.IsNullOrEmpty(config.ManagedIdentityClientId)
            ? new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned)
            : new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(config.ManagedIdentityClientId));
});
builder.Services.AddSingleton(services =>
{
    var config = services.GetRequiredService<IOptions<ChattyOptions>>().Value;
    var options = new TextAnalyticsClientOptions();
    options.Diagnostics.IsLoggingEnabled = false;
    options.Diagnostics.IsLoggingContentEnabled = false;
    options.Retry.MaxRetries = 1;
    options.Retry.NetworkTimeout = TimeSpan.FromSeconds(15);
    return new TextAnalyticsClient(new Uri(config.LanguageEndpoint),
        services.GetRequiredService<TokenCredential>(), options);
});
builder.Services.AddSingleton<IPiiScreen, AzurePiiScreen>();
builder.Services.AddSingleton<IKnowledgeSource, SyntheticKnowledge>();
builder.Services.AddHttpClient<IFoundryAgent, FoundryPromptAgent>(client => client.Timeout = TimeSpan.FromSeconds(90))
    .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler { AllowAutoRedirect = false });
builder.Services.AddScoped<ChatService>();
builder.Services.AddScoped<RequestLog>();
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    o.AddPolicy("Chat", context => RateLimitPartition.GetFixedWindowLimiter(
        context.User.FindFirstValue("oid") ?? "anonymous",
        _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = 10,
            Window = TimeSpan.FromMinutes(1),
            QueueLimit = 0
        }));
});

var app = builder.Build();
_ = app.Services.GetRequiredService<IKnowledgeSource>();
app.UseForwardedHeaders();
app.Use(async (context, next) =>
{
    context.Response.Headers.ContentSecurityPolicy =
        "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; " +
        "img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'";
    context.Response.Headers.XContentTypeOptions = "nosniff";
    context.Response.Headers["Referrer-Policy"] = "no-referrer";
    context.Response.Headers.CacheControl = "no-store";
    try
    {
        await next(context);
    }
    catch (Exception exception) when (!context.Response.HasStarted)
    {
        var (status, code) = exception switch
        {
            ChattyException e => (e.StatusCode, e.Code),
            AntiforgeryValidationException => (400, "invalid_csrf"),
            BadHttpRequestException e => (e.StatusCode, "invalid_request"),
            OperationCanceledException => (504, "request_cancelled"),
            _ => (500, "request_failed")
        };
        // Never attach exceptions: upstream messages and payloads can contain PII.
        app.Logger.LogWarning("Request failed: {Code}; type={Type}; trace={Trace}",
            code, exception.GetType().Name, context.TraceIdentifier);
        var requestLog = context.RequestServices.GetRequiredService<RequestLog>();
        if (requestLog.Entries.Count > 0)
            requestLog.Add("Request", status == 422 && code is "foundry_input_blocked" or "foundry_output_blocked" ? "Blocked" : "Failed");
        context.Response.StatusCode = status;
        await context.Response.WriteAsJsonAsync(new
        {
            error = code, traceId = context.TraceIdentifier, requestLog = requestLog.Entries
        });
    }
});
if (!app.Environment.IsEnvironment("Testing"))
{
    app.UseHsts();
    app.UseHttpsRedirection();
}
app.UseAuthentication();
app.Use(async (context, next) =>
{
    if (context.Request.Path.StartsWithSegments("/api") &&
        context.User.Identity?.IsAuthenticated != true)
    {
        context.Response.StatusCode = 401;
        app.Logger.LogInformation("API access denied: sign_in_required; trace={Trace}", context.TraceIdentifier);
        await context.Response.WriteAsJsonAsync(new
        {
            error = "sign_in_required", traceId = context.TraceIdentifier,
            requestLog = Array.Empty<RequestLogEntry>()
        });
        return;
    }
    await next(context);
});
app.UseAuthorization();
app.UseRateLimiter();
app.MapGet("/health/live", () => Results.Ok(new { status = "alive" })).AllowAnonymous();
app.MapGet("/health/ready", () => Results.Ok(new { status = "ready", applicationHash, uiAssets })).AllowAnonymous();
app.MapGet("/auth-error", () => Results.Problem("Sign-in failed.", statusCode: 401)).AllowAnonymous();
app.MapGet("/MicrosoftIdentity/Account/AccessDenied", (HttpContext context) =>
    Results.Problem(
        title: "Access denied",
        detail: "Sign-in completed, but this account does not meet Chatty's access requirements.",
        statusCode: StatusCodes.Status403Forbidden,
        extensions: new Dictionary<string, object?>
        {
            ["reasons"] = EmployeeAccess.DenialReasons(context.User, builder.Configuration["AzureAd:TenantId"]!),
            ["traceId"] = context.TraceIdentifier
        })).RequireAuthorization();
app.MapControllers();
app.MapGet("/", () =>
    Results.File(Path.Combine(uiRoot, "index.html"), "text/html")).RequireAuthorization("Employee");
app.MapGet("/app.js", () =>
    Results.File(Path.Combine(uiRoot, "app.js"), "text/javascript")).RequireAuthorization("Employee");
app.MapGet("/app.css", () =>
    Results.File(Path.Combine(uiRoot, "app.css"), "text/css")).RequireAuthorization("Employee");
app.MapGet("/api/session", (HttpContext context, IAntiforgery csrf) =>
    Results.Ok(new { csrfToken = csrf.GetAndStoreTokens(context).RequestToken }))
    .RequireAuthorization("Employee");
app.MapPost("/api/chat", async (
    [FromBody] ChatRequest request, HttpContext context, IAntiforgery csrf, ChatService chat, RequestLog requestLog) =>
{
    await csrf.ValidateRequestAsync(context);
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
    timeout.CancelAfter(TimeSpan.FromSeconds(110));
    using var scope = app.Logger.BeginScope(new Dictionary<string, object?>
    {
        ["trace"] = context.TraceIdentifier
    });
    var started = System.Diagnostics.Stopwatch.GetTimestamp();
    requestLog.Add("Request", "Started");
    var reply = await chat.SendAsync(EmployeeAccess.Owner(context.User), request, timeout.Token);
    app.Logger.LogInformation(
        "Chat completed: modelInvoked={ModelInvoked}; findings={Findings}; references={References}; elapsedMs={ElapsedMs}",
        reply.InputScreening.AgentInvoked, reply.Redactions, reply.Citations.Count,
        (long)System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds);
    requestLog.Add("Request", "Completed");
    return Results.Ok(reply with { TraceId = context.TraceIdentifier, RequestLog = requestLog.Entries });
}).RequireAuthorization("Employee").RequireRateLimiting("Chat");
app.MapPost("/api/compare", async (
    [FromBody] ChatRequest request, HttpContext context, IAntiforgery csrf, ChatService chat, RequestLog requestLog) =>
{
    await csrf.ValidateRequestAsync(context);
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
    timeout.CancelAfter(TimeSpan.FromSeconds(110));
    using var scope = app.Logger.BeginScope(new Dictionary<string, object?> { ["trace"] = context.TraceIdentifier });
    requestLog.Add("Comparison", "Started");
    var reply = await chat.CompareAsync(request, timeout.Token);
    requestLog.Add("Comparison", "Completed; inspect each agent outcome");
    app.Logger.LogInformation("Comparison completed: guarded={Guarded}; baseline={Baseline}",
        reply.Agents[0].Status, reply.Agents[1].Status);
    return Results.Ok(reply with { TraceId = context.TraceIdentifier, RequestLog = requestLog.Entries });
}).RequireAuthorization("Employee").RequireRateLimiting("Chat");
app.Logger.LogInformation("Chatty ready: content-free operational logging enabled.");
app.Run();

public partial class Program;
