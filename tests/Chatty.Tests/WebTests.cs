using System.Net;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text.Encodings.Web;
using System.Text.Json;
using Chatty.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Chatty.Tests;

public sealed class WebTests
{
    [Fact]
    public async Task Comparison_has_separate_safe_results_and_logs_for_the_same_screened_input()
    {
        await using var app = new ChattyFactory();
        using var client = app.EmployeeClient();
        var session = await client.GetFromJsonAsync<JsonElement>("/api/session");
        client.DefaultRequestHeaders.Add("X-CHATTY-CSRF", session.GetProperty("csrfToken").GetString());
        app.Agent.FailureCode = "foundry_output_blocked";
        app.Agent.FailVariant = AgentVariant.Guarded;
        var response = await client.PostAsJsonAsync("/api/compare",
            new { message = $"Income private-comparison-canary {TestScreen.Canary}", conversationId = (Guid?)null });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("no-store", response.Headers.CacheControl!.ToString());
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.False(string.IsNullOrEmpty(body.GetProperty("traceId").GetString()));
        var arms = body.GetProperty("agents").EnumerateArray().ToArray();
        Assert.Equal("withheld", arms[0].GetProperty("status").GetString());
        Assert.Equal(JsonValueKind.Null, arms[0].GetProperty("answer").ValueKind);
        Assert.Equal("completed", arms[1].GetProperty("status").GetString());
        Assert.Contains(arms[1].GetProperty("requestLog").EnumerateArray(),
            entry => entry.GetProperty("stage").GetString() == "Output screening");
        Assert.DoesNotContain(body.GetProperty("requestLog").EnumerateArray(),
            entry => entry.GetProperty("stage").GetString() == "Output screening");
        Assert.DoesNotContain(TestScreen.Canary, body.GetRawText());
        Assert.Equal(app.Agent.Calls[0], app.Agent.Calls[1]);
        Assert.DoesNotContain("private-comparison-canary", string.Join("\n", app.Logs.Messages));
        Assert.DoesNotContain(TestScreen.Canary, string.Join("\n", app.Logs.Messages));
        Assert.False(body.TryGetProperty("conversationId", out _));
    }

    [Fact]
    public async Task Operational_logs_explain_success_and_failure_without_conversation_content()
    {
        await using var app = new ChattyFactory();
        using var client = app.EmployeeClient();
        var session = await client.GetFromJsonAsync<JsonElement>("/api/session");
        client.DefaultRequestHeaders.Add("X-CHATTY-CSRF", session.GetProperty("csrfToken").GetString());
        var question = $"Income documentation private-log-canary {TestScreen.Canary}";
        var response = await client.PostAsJsonAsync("/api/chat", new { message = question });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var success = await response.Content.ReadFromJsonAsync<JsonElement>();
        var successLog = success.GetProperty("requestLog");
        Assert.False(string.IsNullOrEmpty(success.GetProperty("traceId").GetString()));
        Assert.Contains(successLog.EnumerateArray(), entry =>
            entry.GetProperty("stage").GetString() == "Output screening" &&
            entry.GetProperty("outcome").GetString() == "Passed" &&
            entry.GetProperty("findings").GetInt32() == 1);
        Assert.DoesNotContain("private-log-canary", successLog.GetRawText());
        Assert.DoesNotContain(TestScreen.Canary, successLog.GetRawText());
        Assert.DoesNotContain("[REDACTED]", successLog.GetRawText());

        app.Screen.FailWhen = _ => true;
        var blocked = await client.PostAsJsonAsync("/api/chat", new { message = question });
        Assert.False(blocked.IsSuccessStatusCode);
        var failure = await blocked.Content.ReadFromJsonAsync<JsonElement>();
        var failureLog = failure.GetProperty("requestLog");
        Assert.Equal("Failed", failureLog.EnumerateArray().Last().GetProperty("outcome").GetString());
        Assert.DoesNotContain(failureLog.EnumerateArray(), entry =>
            entry.GetProperty("stage").GetString() == "Model invocation");
        Assert.DoesNotContain("private-log-canary", failure.GetRawText());
        Assert.NotEqual(success.GetProperty("traceId").GetString(), failure.GetProperty("traceId").GetString());

        var logs = string.Join("\n", app.Logs.Messages);
        Assert.Contains("Input screened: findings=1", logs);
        Assert.Contains("Model request ready:", logs);
        Assert.Contains("Output screened: findings=1", logs);
        Assert.Contains("Chat completed:", logs);
        Assert.Contains("pii_screening_unavailable", logs);
        Assert.DoesNotContain("private-log-canary", logs);
        Assert.DoesNotContain(TestScreen.Canary, logs);
        Assert.DoesNotContain("[REDACTED]", logs);
        Assert.DoesNotContain(app.Agent.Reply, logs);
    }

    [Fact]
    public async Task Withheld_answer_returns_only_its_request_log_and_does_not_commit_history()
    {
        await using var app = new ChattyFactory();
        using var client = app.EmployeeClient();
        var session = await client.GetFromJsonAsync<JsonElement>("/api/session");
        client.DefaultRequestHeaders.Add("X-CHATTY-CSRF", session.GetProperty("csrfToken").GetString());
        app.Agent.FailureCode = "foundry_output_blocked";
        var response = await client.PostAsJsonAsync("/api/chat", new { message = $"Income {TestScreen.Canary}" });
        Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("foundry_output_blocked", body.GetProperty("error").GetString());
        var entries = body.GetProperty("requestLog").EnumerateArray().ToArray();
        Assert.Contains(entries, entry => entry.GetProperty("stage").GetString() == "Input screening" &&
            entry.GetProperty("findings").ValueKind == JsonValueKind.Number);
        Assert.Equal("Blocked", entries[^1].GetProperty("outcome").GetString());
        Assert.DoesNotContain(entries, entry => entry.GetProperty("stage").GetString() == "Output screening");
        Assert.DoesNotContain(TestScreen.Canary, body.GetRawText());
        Assert.False(body.TryGetProperty("answer", out _));
        app.Agent.FailureCode = null;
        var retry = await client.PostAsJsonAsync("/api/chat", new { message = "Income" });
        Assert.Equal(HttpStatusCode.OK, retry.StatusCode);
        Assert.Equal(2, app.Agent.Calls[^1].Count);
    }

    [Theory]
    [InlineData("index.html", false)]
    [InlineData("app.js", false)]
    [InlineData("app.css", true)]
    public void Missing_or_empty_published_ui_assets_fail_startup_validation(string file, bool empty)
    {
        var root = Path.Combine(Path.GetTempPath(), $"chatty-assets-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            foreach (var name in new[] { "index.html", "app.js", "app.css" })
                File.WriteAllText(Path.Combine(root, name), "fixture");
            if (empty)
                File.WriteAllText(Path.Combine(root, file), "");
            else
                File.Delete(Path.Combine(root, file));

            var error = Assert.Throws<InvalidOperationException>(() => WebAssets.Validate(root));
            Assert.Contains(file, error.Message);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task Employee_can_load_all_ui_assets_matching_the_live_readiness_manifest()
    {
        await using var app = new ChattyFactory();
        using var anonymous = app.CreateClient();
        var ready = await anonymous.GetFromJsonAsync<JsonElement>("/health/ready");
        Assert.Equal("ready", ready.GetProperty("status").GetString());
        var assets = ready.GetProperty("uiAssets");
        using var client = app.EmployeeClient();
        foreach (var (path, file, contentType) in new[]
        {
            ("/", "index.html", "text/html"),
            ("/app.js", "app.js", "text/javascript"),
            ("/app.css", "app.css", "text/css")
        })
        {
            var response = await client.GetAsync(path);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            Assert.Equal(contentType, response.Content.Headers.ContentType!.MediaType);
            var bytes = await response.Content.ReadAsByteArrayAsync();
            Assert.NotEmpty(bytes);
            Assert.Equal(assets.GetProperty(file).GetString(),
                Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant());
        }
        Assert.Empty(app.Agent.Calls);
    }

    [Fact]
    public async Task Configured_sign_in_handler_preserves_the_claims_required_by_employee_access()
    {
        await using var app = new ChattyFactory();
        var options = app.Services.GetRequiredService<IOptionsMonitor<OpenIdConnectOptions>>()
            .Get(OpenIdConnectDefaults.AuthenticationScheme);
        using var rsa = RSA.Create(2048);
        var key = new RsaSecurityKey(rsa);
        var issuer = $"https://login.microsoftonline.com/{TestAuth.Tenant}/v2.0";
        const string audience = "22222222-2222-2222-2222-222222222222";
        var token = new JsonWebTokenHandler().CreateToken(new SecurityTokenDescriptor
        {
            Issuer = issuer,
            Audience = audience,
            Subject = new ClaimsIdentity(
            [
                new("tid", TestAuth.Tenant),
                new("oid", "33333333-3333-3333-3333-333333333333"),
                new("acct", "0"),
                new("roles", "Chatty.User")
            ]),
            SigningCredentials = new SigningCredentials(key, SecurityAlgorithms.RsaSha256),
            Expires = DateTime.UtcNow.AddMinutes(5)
        });
        var validated = await options.TokenHandler.ValidateTokenAsync(token, new TokenValidationParameters
        {
            ValidIssuer = issuer,
            ValidAudience = audience,
            IssuerSigningKey = key,
            NameClaimType = options.TokenValidationParameters.NameClaimType,
            RoleClaimType = options.TokenValidationParameters.RoleClaimType
        });

        Assert.True(validated.IsValid);
        Assert.Empty(EmployeeAccess.DenialReasons(new ClaimsPrincipal(validated.ClaimsIdentity), TestAuth.Tenant));
    }

    [Theory]
    [InlineData("169.254.129.1", "https")]
    [InlineData("10.243.3.4", "http")]
    public async Task Original_https_scheme_is_accepted_only_from_a_trusted_proxy(string address, string expectedScheme)
    {
        await using var app = new ChattyFactory();
        var context = await app.Server.SendAsync(context =>
        {
            context.Connection.RemoteIpAddress = IPAddress.Parse(address);
            context.Request.Host = new HostString("localhost");
            context.Request.Path = "/health/live";
            context.Request.Scheme = "http";
            context.Request.Headers["X-Forwarded-Proto"] = "https";
        });
        Assert.Equal(StatusCodes.Status200OK, context.Response.StatusCode);
        Assert.Equal(expectedScheme, context.Request.Scheme);
    }

    [Theory]
    [InlineData("/api/chat")]
    [InlineData("/api/compare")]
    public async Task Anonymous_chat_is_unauthorized_without_any_inference(string route)
    {
        await using var app = new ChattyFactory();
        using var client = app.CreateClient();
        var response = await client.PostAsJsonAsync(route, new { message = "Income documentation" });
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("sign_in_required", body.GetProperty("error").GetString());
        Assert.False(string.IsNullOrEmpty(body.GetProperty("traceId").GetString()));
        Assert.Empty(body.GetProperty("requestLog").EnumerateArray());
        Assert.DoesNotContain("Income documentation", body.GetRawText());
        Assert.Contains(app.Logs.Messages, message => message.Contains("API access denied: sign_in_required", StringComparison.Ordinal));
        var session = await client.GetAsync("/api/session");
        Assert.Equal(HttpStatusCode.Unauthorized, session.StatusCode);
        Assert.Equal("sign_in_required",
            (await session.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString());
        Assert.Empty(app.Agent.Calls);
    }

    [Theory]
    [InlineData("guest")]
    [InlineData("missing-account-type")]
    [InlineData("unassigned")]
    [InlineData("wrong-tenant")]
    public async Task Authenticated_but_disallowed_users_cannot_chat(string mode)
    {
        await using var app = new ChattyFactory();
        using var client = app.EmployeeClient(mode);
        foreach (var path in new[] { "/api/session", "/", "/app.js", "/app.css" })
            Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync(path)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden,
            (await client.PostAsJsonAsync("/api/compare", new { message = "Income documentation" })).StatusCode);
        Assert.Empty(app.Agent.Calls);
    }

    [Theory]
    [InlineData("unassigned", "missing_chatty_role")]
    [InlineData("missing-account-type", "missing_member_claim")]
    [InlineData("guest", "not_tenant_member")]
    public async Task Cookie_forbidden_redirect_has_a_mapped_private_diagnostic_instead_of_a_404(string mode, string reason)
    {
        await using var app = new ChattyFactory(useCookieForbid: true);
        using var client = app.EmployeeClient(mode);
        var root = await client.GetAsync("/");
        Assert.Equal(HttpStatusCode.Redirect, root.StatusCode);
        Assert.Equal("/MicrosoftIdentity/Account/AccessDenied", root.Headers.Location!.AbsolutePath);

        var denied = await client.GetAsync(root.Headers.Location);
        Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
        var body = await denied.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Contains(body.GetProperty("reasons").EnumerateArray(), item => item.GetString() == reason);
        Assert.DoesNotContain("33333333-3333-3333-3333-333333333333", body.GetRawText());
        Assert.DoesNotContain(TestAuth.Tenant, body.GetRawText());
        Assert.Empty(app.Agent.Calls);
    }

    [Fact]
    public async Task Anonymous_user_cannot_read_access_denied_diagnostics()
    {
        await using var app = new ChattyFactory();
        using var client = app.CreateClient();
        var response = await client.GetAsync("/MicrosoftIdentity/Account/AccessDenied");
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        Assert.DoesNotContain("reasons", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Authorized_user_can_chat_with_csrf_but_cannot_supply_history()
    {
        await using var app = new ChattyFactory();
        using var client = app.EmployeeClient();
        var session = await client.GetFromJsonAsync<JsonElement>("/api/session");
        client.DefaultRequestHeaders.Add("X-CHATTY-CSRF", session.GetProperty("csrfToken").GetString());
        var response = await client.PostAsJsonAsync("/api/chat",
            new { message = $"Income documentation {TestScreen.Canary}" });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.DoesNotContain(TestScreen.Canary, await response.Content.ReadAsStringAsync());
        Assert.Single(app.Agent.Calls);
        var reply = await response.Content.ReadFromJsonAsync<JsonElement>();
        var preview = reply.GetProperty("inputScreening");
        Assert.True(preview.GetProperty("agentInvoked").GetBoolean());
        Assert.Equal(app.Agent.Calls[0][^1].Content.Text, preview.GetProperty("text").GetString());
        Assert.Equal(1, preview.GetProperty("redactions").GetInt32());
        Assert.Equal("no-store", response.Headers.CacheControl!.ToString());

        var tampered = await client.PostAsJsonAsync("/api/chat",
            new { message = "Income documentation", history = new[] { "bypass screening" } });
        Assert.Equal(HttpStatusCode.BadRequest, tampered.StatusCode);
        Assert.Single(app.Agent.Calls);
    }

    [Theory]
    [InlineData("/api/chat")]
    [InlineData("/api/compare")]
    public async Task Missing_csrf_token_blocks_inference(string route)
    {
        await using var app = new ChattyFactory();
        using var client = app.EmployeeClient();
        var response = await client.PostAsJsonAsync(route, new { message = "Income documentation" });
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Empty(app.Agent.Calls);
    }

    [Fact]
    public async Task Bundled_synthetic_knowledge_retrieves_references_without_loading_real_guides()
    {
        await using var app = new ChattyFactory(useRealKnowledge: true);
        using var client = app.EmployeeClient();
        var session = await client.GetFromJsonAsync<JsonElement>("/api/session");
        client.DefaultRequestHeaders.Add("X-CHATTY-CSRF", session.GetProperty("csrfToken").GetString());
        var response = await client.PostAsJsonAsync("/api/chat", new { message = "Explain synthetic income documentation" });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains(app.Agent.Calls.Single(), message =>
            message.Content.Text.Contains("SYNTHETIC TEST POLICY", StringComparison.Ordinal));
        var unsupported = await client.PostAsJsonAsync("/api/chat", new { message = "Quantum chromodynamics" });
        Assert.Contains("Insufficient evidence", await unsupported.Content.ReadAsStringAsync());
        Assert.Single(app.Agent.Calls);
    }

    private sealed class ChattyFactory(bool useRealKnowledge = false, bool useCookieForbid = false) : WebApplicationFactory<Program>
    {
        public RecordingAgent Agent { get; } = new();
        public TestScreen Screen { get; } = new();
        public RecordingLogProvider Logs { get; } = new();

        public HttpClient EmployeeClient(string mode = "employee")
        {
            var client = CreateClient(new WebApplicationFactoryClientOptions
            {
                BaseAddress = new Uri("https://localhost"),
                AllowAutoRedirect = false
            });
            client.DefaultRequestHeaders.Add("X-Test-Identity", mode);
            return client;
        }

        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.UseEnvironment("Testing");
            builder.ConfigureLogging(logging => logging.AddProvider(Logs));
            builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["AzureAd:TenantId"] = TestAuth.Tenant,
                ["AzureAd:ClientId"] = "22222222-2222-2222-2222-222222222222",
                ["Chatty:LanguageEndpoint"] = "https://chatty-test.cognitiveservices.azure.com/",
                ["Chatty:ProjectEndpoint"] = "https://chatty-test.services.ai.azure.com/api/projects/chatty",
                ["Chatty:AgentVersion"] = "1",
                ["Chatty:BaselineAgentVersion"] = "1",
                ["Chatty:TrustedProxyNetwork"] = "169.254.0.0/16"
            }));
            builder.ConfigureTestServices(services =>
            {
                services.RemoveAll<IPiiScreen>();
                services.RemoveAll<IFoundryAgent>();
                services.AddSingleton<IPiiScreen>(Screen);
                if (!useRealKnowledge)
                {
                    services.RemoveAll<IKnowledgeSource>();
                    services.AddSingleton<IKnowledgeSource, TestKnowledge>();
                }
                services.AddSingleton<IFoundryAgent>(Agent);
                services.AddAuthentication(o =>
                {
                    o.DefaultAuthenticateScheme = "Test";
                    o.DefaultChallengeScheme = "Test";
                    o.DefaultForbidScheme = useCookieForbid ? CookieAuthenticationDefaults.AuthenticationScheme : "Test";
                }).AddScheme<AuthenticationSchemeOptions, TestAuth>("Test", _ => { });
            });
        }
    }

    private sealed class RecordingLogProvider : ILoggerProvider
    {
        public System.Collections.Concurrent.ConcurrentQueue<string> Messages { get; } = new();
        public ILogger CreateLogger(string categoryName) => new RecordingLogger(Messages);
        public void Dispose() { }

        private sealed class RecordingLogger(System.Collections.Concurrent.ConcurrentQueue<string> messages) : ILogger
        {
            public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
            public bool IsEnabled(LogLevel logLevel) => true;
            public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
                Func<TState, Exception?, string> formatter) => messages.Enqueue(formatter(state, exception));
        }
    }

    private sealed class TestAuth(IOptionsMonitor<AuthenticationSchemeOptions> options, ILoggerFactory logger, UrlEncoder encoder)
        : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
    {
        public const string Tenant = "11111111-1111-1111-1111-111111111111";

        protected override Task<AuthenticateResult> HandleAuthenticateAsync()
        {
            var mode = Request.Headers["X-Test-Identity"].ToString();
            if (string.IsNullOrEmpty(mode))
                return Task.FromResult(AuthenticateResult.NoResult());
            var identity = new ClaimsIdentity(
            [
                new("oid", "33333333-3333-3333-3333-333333333333"),
                new("tid", mode == "wrong-tenant" ? "99999999-9999-9999-9999-999999999999" : Tenant),
                new("acct", mode == "guest" ? "1" : mode == "missing-account-type" ? "" : "0"),
                new("roles", mode == "unassigned" ? "NoRole" : "Chatty.User")
            ], Scheme.Name, "oid", "roles");
            return Task.FromResult(AuthenticateResult.Success(
                new AuthenticationTicket(new ClaimsPrincipal(identity), Scheme.Name)));
        }
    }
}
