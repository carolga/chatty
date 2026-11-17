using Azure.AI.TextAnalytics;
using Azure.Identity;
using Chatty.Web;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Options;
using Microsoft.Extensions.Logging.Abstractions;
using System.Text.Json;

if (args.Length != 5)
    throw new ArgumentException("Expected source directory, Language endpoint, project endpoint, guarded version, and baseline version.");
const string canary = "chatty-canary-42@example.com";
using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(5));
var credential = new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned);
var clientOptions = new TextAnalyticsClientOptions();
clientOptions.Diagnostics.IsLoggingEnabled = false;
clientOptions.Diagnostics.IsLoggingContentEnabled = false;
var pii = new AzurePiiScreen(new TextAnalyticsClient(new Uri(args[1]), credential, clientOptions));
var transport = new ResponseMetadataHandler(new SocketsHttpHandler { AllowAutoRedirect = false }, canary);
using var http = new HttpClient(transport);
var options = Options.Create(new ChattyOptions
{
    LanguageEndpoint = args[1],
    ProjectEndpoint = args[2],
    AgentName = "chatty",
    AgentVersion = args[3],
    BaselineAgentName = "chatty-no-pii",
    BaselineAgentVersion = args[4]
});
var requestLog = new RequestLog(NullLogger<RequestLog>.Instance);
var recording = new RecordingAgent(new FoundryPromptAgent(http, credential, options, requestLog));
using var cache = new MemoryCache(new MemoryCacheOptions { SizeLimit = 1024 });
var store = new ConversationStore(cache);
var knowledge = new SyntheticKnowledge(new SmokeEnvironment(args[0]));
var chat = new ChatService(pii, knowledge, recording, store, NullLogger<ChatService>.Instance, requestLog);
ChatReply? reply = null;
try
{
    reply = await chat.SendAsync("smoke-owner",
        new ChatRequest($"Explain the synthetic income documentation review. My email is {canary}."),
        timeout.Token);
}
catch (ChattyException exception) when (exception.Code == "foundry_output_blocked")
{
    Console.WriteLine("PASS: Foundry blocked the first completion; no answer was released.");
}
if (recording.Calls != 1 || transport.LastQuestion is null ||
    transport.LastQuestion.Contains(canary, StringComparison.OrdinalIgnoreCase) ||
    recording.Messages.Any(m => m.Content.Text.Contains(canary, StringComparison.OrdinalIgnoreCase)))
    throw new InvalidOperationException("Model-bound PII boundary smoke check failed.");
if (reply is not null)
{
    if (reply.Citations.Count == 0 || reply.Redactions < 1 ||
        reply.Answer.Contains(canary, StringComparison.OrdinalIgnoreCase) ||
        !reply.InputScreening.AgentInvoked || reply.InputScreening.Redactions < 1 ||
        reply.InputScreening.Text != transport.LastQuestion)
        throw new InvalidOperationException("Answer or redaction preview smoke check failed.");
    Console.WriteLine("PASS: real Language redaction, screened answer and citations.");
    Console.WriteLine("PASS: redaction preview matches the exact model-bound question.");
}
Console.WriteLine("PASS: real Language redaction and pinned Foundry invocation; no model-bound canary PII.");

ChatReply? followup = null;
try
{
    followup = await chat.SendAsync("smoke-owner",
        new ChatRequest($"Explain missing income documentation in the synthetic policy. My email is {canary}.",
            reply?.ConversationId), timeout.Token);
}
catch (ChattyException exception) when (exception.Code == "foundry_output_blocked")
{
    Console.WriteLine("PASS: Foundry blocked the follow-up completion; no answer was released.");
}
if (recording.Calls != 2 || recording.Messages.Count != (reply is null ? 2 : 4) ||
    transport.LastQuestion is null || transport.LastQuestion.Contains(canary, StringComparison.OrdinalIgnoreCase) ||
    recording.Messages.Any(m => m.Content.Text.Contains(canary, StringComparison.OrdinalIgnoreCase)))
    throw new InvalidOperationException("Follow-up privacy boundary smoke check failed.");
if (followup is not null &&
    (followup.Citations.Count == 0 || followup.Redactions < 1 ||
     followup.Answer.Contains(canary, StringComparison.OrdinalIgnoreCase) ||
     !followup.InputScreening.AgentInvoked || followup.InputScreening.Redactions < 1 ||
     followup.InputScreening.Text != transport.LastQuestion))
    throw new InvalidOperationException("Follow-up answer or preview smoke check failed.");
Console.WriteLine(reply is null
    ? "SKIP: live history replay; the first completion was withheld. Second independent request remained screened."
    : "PASS: follow-up model-bound question and replayed history contain no canary PII.");

var abstention = await chat.SendAsync("smoke-owner",
    new ChatRequest($"Quantumchromodynamics {canary}"), timeout.Token);
if (recording.Calls != 2 || abstention.InputScreening.AgentInvoked ||
    abstention.InputScreening.Redactions < 1 || abstention.Citations.Count != 0 ||
    abstention.InputScreening.Text.Contains(canary, StringComparison.OrdinalIgnoreCase))
    throw new InvalidOperationException("Screened abstention preview check failed.");
Console.WriteLine("PASS: screened abstention preview correctly reports no model call.");

var failed = new ChatService(new UnavailableScreen(), knowledge, recording, store, NullLogger<ChatService>.Instance,
    new RequestLog(NullLogger<RequestLog>.Instance));
try
{
    await failed.SendAsync("smoke-owner", new ChatRequest("Explain synthetic income documentation."), timeout.Token);
    throw new InvalidOperationException("Expected screening failure.");
}
catch (ChattyException exception) when (exception.Message == "pii_screening_unavailable")
{
    if (recording.Calls != 2)
        throw new InvalidOperationException("Model was invoked after screening failed.");
}
Console.WriteLine("PASS: screening failure prevented inference.");
if (reply is not null)
{
    try
    {
        await chat.SendAsync("different-owner", new ChatRequest("Explain income documentation.", reply.ConversationId), timeout.Token);
        throw new InvalidOperationException("Expected owner isolation.");
    }
    catch (ChattyException exception) when (exception.Message == "conversation_not_found")
    {
        if (recording.Calls != 2)
            throw new InvalidOperationException("Model was invoked for a different conversation owner.");
    }
    Console.WriteLine("PASS: cross-user conversation access denied.");
}
else
{
    Console.WriteLine("SKIP: live answered-conversation ownership check; the first completion was withheld.");
}

transport.Inputs.Clear();
var comparison = await chat.CompareAsync(
    new ChatRequest($"Explain synthetic income documentation. My email is {canary}."), timeout.Token);
if (transport.Inputs.Count != 2 || !transport.Inputs.TryGetValue("chatty", out var guardedInput) ||
    !transport.Inputs.TryGetValue("chatty-no-pii", out var baselineInput) || guardedInput != baselineInput ||
    comparison.Agents.Count != 2 || comparison.Agents.Any(result => result.Status == "failed") ||
    comparison.Agents.Single(result => result.Variant == "baseline").Status != "completed" ||
    comparison.Agents.Any(result => result.Status == "completed" &&
        (result.ModelCost is null || result.ModelCost.InputTokens <= 0 ||
         result.ModelCost.OutputTokens <= 0 || result.ModelCost.EstimatedUsd <= 0)) ||
    comparison.Agents.Any(result => result.Answer?.Contains(canary, StringComparison.OrdinalIgnoreCase) == true))
    throw new InvalidOperationException("Paired-agent input equality or screened-output smoke check failed.");
Console.WriteLine("PASS: both pinned agents received identical screened input; baseline answered; no canary in either released answer.");
Console.WriteLine("PASS: completed agent calls returned token usage for separate model-cost estimates.");
foreach (var arm in comparison.Agents)
{
    var inputCheck = arm.RequestLog.SingleOrDefault(entry => entry.Stage == "Foundry input guardrails");
    var outputCheck = arm.RequestLog.SingleOrDefault(entry => entry.Stage == "Foundry output guardrails");
    if (arm.Status == "completed" && (inputCheck is null || outputCheck is null))
        throw new InvalidOperationException("Agent input/output guardrail telemetry is missing.");
    Console.WriteLine($"Agent {arm.Variant}: inputCheck={inputCheck?.Outcome}; outputCheck={outputCheck?.Outcome}; usageReported={arm.ModelCost is not null}.");
}

sealed class RecordingAgent(IFoundryAgent inner) : IFoundryAgent
{
    private int calls;
    public int Calls => calls;
    public IReadOnlyList<SafeMessage> Messages { get; private set; } = [];
    public Task<string> RespondAsync(IReadOnlyList<SafeMessage> messages, CancellationToken cancellationToken,
        AgentVariant variant = AgentVariant.Guarded, RequestLog? log = null)
    {
        Interlocked.Increment(ref calls);
        Messages = messages.ToArray();
        return inner.RespondAsync(messages, cancellationToken, variant, log);
    }
}

sealed class UnavailableScreen : IPiiScreen
{
    public Task<ScreenedText> RedactAsync(string text, CancellationToken cancellationToken) =>
        throw new ChattyException("pii_screening_unavailable");
}

sealed class ResponseMetadataHandler(HttpMessageHandler inner, string canary) : DelegatingHandler(inner)
{
    public string? LastQuestion { get; private set; }
    public System.Collections.Concurrent.ConcurrentDictionary<string, string> Inputs { get; } = new();

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.Content is null)
            throw new InvalidOperationException("Model-bound request privacy check failed.");
        var json = await request.Content.ReadAsStringAsync(cancellationToken);
        if (json.Contains(canary, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Model-bound request privacy check failed.");
        using (var document = JsonDocument.Parse(json))
        {
            LastQuestion = document.RootElement.GetProperty("input").EnumerateArray().Last()
                .GetProperty("content").GetString();
            Inputs[document.RootElement.GetProperty("agent_reference").GetProperty("name").GetString()!] =
                document.RootElement.GetProperty("input").GetRawText();
        }
        var response = await base.SendAsync(request, cancellationToken);
        Console.WriteLine($"Foundry HTTP status: {(int)response.StatusCode}.");
        if (response.IsSuccessStatusCode)
        {
            await response.Content.LoadIntoBufferAsync(262_144, cancellationToken);
            using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
            var root = document.RootElement;
            if (root.TryGetProperty("content_filters", out var filters) && filters.ValueKind == JsonValueKind.Array)
            {
                foreach (var filter in filters.EnumerateArray())
                {
                    if (filter.TryGetProperty("source_type", out var source) && source.GetString() == "completion" &&
                        filter.TryGetProperty("content_filter_results", out var results) &&
                        results.TryGetProperty("personally_identifiable_information", out var personalData) &&
                        personalData.TryGetProperty("detected", out var detected) &&
                        detected.ValueKind == JsonValueKind.True)
                        Console.WriteLine("Foundry completion category: personally_identifiable_information detected.");
                }
            }
            var status = root.TryGetProperty("status", out var state) ? state.GetString() : null;
            Console.WriteLine($"Foundry completion state: {status switch
            {
                "completed" or "incomplete" or "failed" => status,
                _ => "unknown"
            }}.");
            if (root.TryGetProperty("incomplete_details", out var details) &&
                details.ValueKind == JsonValueKind.Object &&
                details.TryGetProperty("reason", out var reason))
                Console.WriteLine($"Foundry incomplete reason: {reason.GetString() switch
                {
                    "max_output_tokens" => "max_output_tokens",
                    "content_filter" => "content_filter",
                    _ => "unknown"
                }}.");
            if (root.TryGetProperty("usage", out var usage) &&
                usage.TryGetProperty("output_tokens", out var outputTokens) && outputTokens.TryGetInt32(out var count))
                Console.WriteLine($"Foundry output token count: {count}.");
        }
        return response;
    }
}

sealed class SmokeEnvironment(string path) : IWebHostEnvironment
{
    public string ApplicationName { get; set; } = "Chatty.Smoke";
    public string EnvironmentName { get; set; } = "Production";
    public string ContentRootPath { get; set; } = path;
    public string WebRootPath { get; set; } = Path.Combine(path, "wwwroot");
    public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    public IFileProvider WebRootFileProvider { get; set; } = new NullFileProvider();
}
