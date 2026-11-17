using System.Net;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Chatty.Web;
using Microsoft.Extensions.Options;
using Microsoft.Extensions.Logging.Abstractions;

namespace Chatty.Tests;

public sealed class FoundryAgentTests
{
    [Fact]
    public async Task Serializes_only_screened_input_pins_agent_and_disables_storage_and_tools()
    {
        var handler = new CaptureHandler("""{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Example [S1]"}]}]}""");
        using var http = new HttpClient(handler);
        var agent = Create(http);
        Assert.Equal("Example [S1]", await agent.RespondAsync(
            [new("user", new ScreenedText("Income [REDACTED]", 1))], default));

        using var body = JsonDocument.Parse(handler.Body!);
        Assert.Equal("7", body.RootElement.GetProperty("agent_reference").GetProperty("version").GetString());
        Assert.False(body.RootElement.GetProperty("store").GetBoolean());
        Assert.False(body.RootElement.GetProperty("stream").GetBoolean());
        Assert.Equal("none", body.RootElement.GetProperty("tool_choice").GetString());
        Assert.Equal(0, body.RootElement.GetProperty("tools").GetArrayLength());
        Assert.Contains("[REDACTED]", handler.Body!);
        Assert.Equal("/api/projects/chatty/openai/v1/responses", handler.Endpoint!.AbsolutePath);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Baseline_pins_its_own_agent_and_isolates_its_log_while_retaining_other_blocks(bool blocked)
    {
        var handler = new CaptureHandler("""
            {"status":"completed","content_filters":[{"source_type":"completion","blocked":BLOCKED,"content_filter_results":{"personally_identifiable_information":{"detected":false}}}],"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Example [S1]"}]}]}
            """.Replace("BLOCKED", blocked ? "true" : "false", StringComparison.Ordinal));
        using var http = new HttpClient(handler);
        var sharedLog = new RequestLog(NullLogger<RequestLog>.Instance);
        var armLog = sharedLog.Fork();
        var adapter = new FoundryPromptAgent(http, new StubCredential(), Options.Create(new ChattyOptions
        {
            ProjectEndpoint = "https://chatty-test.services.ai.azure.com/api/projects/chatty",
            AgentName = "chatty", AgentVersion = "7",
            BaselineAgentName = "chatty-no-pii", BaselineAgentVersion = "3"
        }), sharedLog);
        var call = () => adapter.RespondAsync([new("user", new ScreenedText("safe", 0))], default,
            AgentVariant.Baseline, armLog);
        if (blocked)
            Assert.Equal("foundry_output_blocked", (await Assert.ThrowsAsync<ChattyException>(call)).Code);
        else
            Assert.Equal("Example [S1]", await call());
        using var body = JsonDocument.Parse(handler.Body!);
        var reference = body.RootElement.GetProperty("agent_reference");
        Assert.Equal("chatty-no-pii", reference.GetProperty("name").GetString());
        Assert.Equal("3", reference.GetProperty("version").GetString());
        Assert.Empty(sharedLog.Entries);
        Assert.Contains(armLog.Entries, entry => entry.Stage == "Custom Foundry PII controls" &&
            entry.Outcome == "Not configured");
        Assert.All(armLog.Entries, entry => Assert.Null(entry.PiiDetected));
        Assert.Equal(blocked ? "Blocked" : "Evaluated", armLog.Entries[^1].Outcome);
    }

    [Theory]
    [InlineData("""{"status":"incomplete","output":[]}""")]
    [InlineData("""{"status":"completed","output":[{"type":"function_call","name":"bypass"}]}""")]
    [InlineData("""{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"No"}]}]}""")]
    public async Task Incomplete_responses_and_unexpected_actions_are_not_returned(string response)
    {
        using var http = new HttpClient(new CaptureHandler(response));
        await Assert.ThrowsAsync<ChattyException>(() =>
            Create(http).RespondAsync([new("user", new ScreenedText("safe", 0))], default));
    }

    [Theory]
    [InlineData("""{"status":"incomplete","incomplete_details":{"reason":"content_filter"},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Never release partial text"}]}]}""")]
    [InlineData("""{"status":"completed","content_filters":[{"source_type":"completion","blocked":true}],"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Never release blocked text"}]}]}""")]
    public async Task Guardrail_blocks_have_a_specific_safe_error_and_never_release_text(string response)
    {
        using var http = new HttpClient(new CaptureHandler(response));
        var exception = await Assert.ThrowsAsync<ChattyException>(() =>
            Create(http).RespondAsync([new("user", new ScreenedText("safe", 0))], default));
        Assert.Equal("foundry_output_blocked", exception.Code);
        Assert.Equal(422, exception.StatusCode);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Pii_detection_is_reported_without_payload_and_does_not_override_blocking(bool blocked)
    {
        var response = """
            {"status":"completed","content_filters":[{"source_type":"completion","blocked":BLOCKED,"content_filter_results":{"personally_identifiable_information":{"detected":true,"sub_categories":[{"value":"never-log-this@example.test"}]}}}],"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Screen this answer [S1]"}]}]}
            """.Replace("BLOCKED", blocked ? "true" : "false", StringComparison.Ordinal);
        using var http = new HttpClient(new CaptureHandler(response));
        var log = new RequestLog(NullLogger<RequestLog>.Instance);
        var agent = new FoundryPromptAgent(http, new StubCredential(), Options.Create(new ChattyOptions
        {
            ProjectEndpoint = "https://chatty-test.services.ai.azure.com/api/projects/chatty",
            AgentName = "chatty", AgentVersion = "7"
        }), log);
        if (blocked)
            await Assert.ThrowsAsync<ChattyException>(() =>
                agent.RespondAsync([new("user", new ScreenedText("safe", 0))], default));
        else
            Assert.Equal("Screen this answer [S1]",
                await agent.RespondAsync([new("user", new ScreenedText("safe", 0))], default));
        var entry = Assert.Single(log.Entries, entry => entry.Stage == "Foundry output guardrails");
        Assert.True(entry.PiiDetected);
        Assert.Equal(blocked ? "Blocked" : "Evaluated", entry.Outcome);
        Assert.DoesNotContain("never-log-this", JsonSerializer.Serialize(log.Entries));
        Assert.DoesNotContain("Screen this answer", JsonSerializer.Serialize(log.Entries));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Input_blocks_and_output_annotations_are_distinct_and_never_expose_payloads(bool inputBlocked)
    {
        var response = """
            {"status":"completed","content_filters":[
              {"source_type":"prompt","blocked":INPUT_BLOCKED,"content_filter_results":{"personally_identifiable_information":{"detected":INPUT_BLOCKED}}},
              {"source_type":"completion","blocked":false,"content_filter_results":{"personally_identifiable_information":{"detected":true}}}
            ],"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Example [S1]"}]}]}
            """.Replace("INPUT_BLOCKED", inputBlocked ? "true" : "false", StringComparison.Ordinal);
        if (inputBlocked)
            response = """
                {"error":{"code":"content_filter","message":"Never log this upstream message",
                "content_filters":[{"source_type":"prompt","blocked":true,
                "content_filter_results":{"personally_identifiable_information":{"detected":true}}}]}}
                """;
        using var http = new HttpClient(new CaptureHandler(response,
            inputBlocked ? HttpStatusCode.BadRequest : HttpStatusCode.OK));
        var log = new RequestLog(NullLogger<RequestLog>.Instance);
        var adapter = new FoundryPromptAgent(http, new StubCredential(),
            Options.Create(new ChattyOptions { ProjectEndpoint = "https://test.services.ai.azure.com/api/projects/chatty" }), log);
        if (inputBlocked)
        {
            var error = await Assert.ThrowsAsync<ChattyException>(() =>
                adapter.RespondAsync([new("user", new ScreenedText("safe", 0))], default));
            Assert.Equal("foundry_input_blocked", error.Code);
            Assert.Equal(422, error.StatusCode);
            Assert.Null(log.ModelCost);
            Assert.DoesNotContain(log.Entries, entry => entry.Stage == "Foundry output guardrails");
        }
        else
        {
            await adapter.RespondAsync([new("user", new ScreenedText("safe", 0))], default);
            Assert.True(Assert.Single(log.Entries, entry => entry.Stage == "Foundry output guardrails").PiiDetected);
        }
        var input = Assert.Single(log.Entries, entry => entry.Stage == "Foundry input guardrails");
        Assert.Equal(inputBlocked, input.PiiDetected);
        Assert.Equal(inputBlocked ? "Blocked" : "Evaluated", input.Outcome);
        Assert.DoesNotContain("Never log", JsonSerializer.Serialize(log.Entries));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Reported_usage_accounts_for_cached_input_and_includes_reasoning_once_even_when_output_is_blocked(bool blocked)
    {
        var response = """
            {"status":"completed","usage":{"input_tokens":1000,"output_tokens":100,
            "input_tokens_details":{"cached_tokens":250},"output_tokens_details":{"reasoning_tokens":40}},
            "content_filters":[{"source_type":"completion","blocked":BLOCKED}],
            "output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Example [S1]"}]}]}
            """.Replace("BLOCKED", blocked ? "true" : "false", StringComparison.Ordinal);
        using var http = new HttpClient(new CaptureHandler(response));
        var log = new RequestLog(NullLogger<RequestLog>.Instance);
        var adapter = new FoundryPromptAgent(http, new StubCredential(),
            Options.Create(new ChattyOptions { ProjectEndpoint = "https://test.services.ai.azure.com/api/projects/chatty" }), log);
        if (blocked)
            await Assert.ThrowsAsync<ChattyException>(() =>
                adapter.RespondAsync([new("user", new ScreenedText("safe", 0))], default));
        else
            await adapter.RespondAsync([new("user", new ScreenedText("safe", 0))], default);
        Assert.NotNull(log.ModelCost);
        Assert.Equal(0.000433125m, log.ModelCost.EstimatedUsd);
        Assert.Equal(100, log.ModelCost.OutputTokens);
        Assert.Equal(40, log.ModelCost.ReasoningTokens);
    }

    [Fact]
    public async Task Agent_log_forks_keep_the_comparison_clock_without_copying_shared_events()
    {
        var shared = new RequestLog(NullLogger<RequestLog>.Instance);
        await Task.Delay(25);
        shared.Add("Input screening", "Passed", 1);
        var arm = shared.Fork();
        arm.Add("Model invocation", "Started");
        Assert.True(arm.Entries[0].ElapsedMs >= shared.Entries[0].ElapsedMs);
        Assert.Single(arm.Entries);
        Assert.Equal("Model invocation", arm.Entries[0].Stage);
    }

    [Theory]
    [InlineData(null, 10, null)]
    [InlineData(10, -1, null)]
    [InlineData(10, 5, 11)]
    public void Missing_or_invalid_usage_is_unknown_not_free(int? input, int? output, int? cached)
    {
        var log = new RequestLog(NullLogger<RequestLog>.Instance);
        log.RecordModelUsage(input, output, cached, null);
        Assert.Null(log.ModelCost);
        Assert.Single(log.Entries);
    }

    private static FoundryPromptAgent Create(HttpClient http) => new(http, new StubCredential(),
        Options.Create(new ChattyOptions
        {
            ProjectEndpoint = "https://chatty-test.services.ai.azure.com/api/projects/chatty",
            AgentName = "chatty",
            AgentVersion = "7"
        }), new RequestLog(NullLogger<RequestLog>.Instance));

    private sealed class StubCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            new("not-a-real-token", DateTimeOffset.UtcNow.AddMinutes(5));
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }

    private sealed class CaptureHandler(string response, HttpStatusCode status = HttpStatusCode.OK) : HttpMessageHandler
    {
        public string? Body { get; private set; }
        public Uri? Endpoint { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Body = await request.Content!.ReadAsStringAsync(cancellationToken);
            Endpoint = request.RequestUri;
            return new(status) { Content = new StringContent(response, Encoding.UTF8, "application/json") };
        }
    }
}
