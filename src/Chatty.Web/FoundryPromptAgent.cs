using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Azure.Core;
using Microsoft.Extensions.Options;

namespace Chatty.Web;

public sealed class FoundryPromptAgent(HttpClient http, TokenCredential credential, IOptions<ChattyOptions> options,
    RequestLog requestLog)
    : IFoundryAgent
{
    public async Task<string> RespondAsync(IReadOnlyList<SafeMessage> messages, CancellationToken cancellationToken,
        AgentVariant variant = AgentVariant.Guarded, RequestLog? log = null)
    {
        var config = options.Value;
        var (name, version) = variant switch
        {
            AgentVariant.Guarded => (config.AgentName, config.AgentVersion),
            AgentVariant.Baseline => (config.BaselineAgentName, config.BaselineAgentVersion),
            _ => throw new ArgumentOutOfRangeException(nameof(variant))
        };
        log ??= requestLog;
        var endpoint = new Uri(config.ProjectEndpoint.TrimEnd('/') + "/openai/v1/responses");
        var token = await credential.GetTokenAsync(
            new TokenRequestContext(["https://ai.azure.com/.default"]), cancellationToken);
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        request.Content = JsonContent.Create(new
        {
            agent_reference = new { type = "agent_reference", name, version },
            input = messages.Select(m => new { role = m.Role, content = m.Content.Text }),
            store = false,
            stream = false,
            tools = Array.Empty<object>(),
            tool_choice = "none",
            max_output_tokens = 4096
        });
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (!response.IsSuccessStatusCode && response.StatusCode != System.Net.HttpStatusCode.BadRequest)
            throw new ChattyException("foundry_request_failed");
        // Bound buffering, including chunked responses. Do not log upstream bodies.
        await response.Content.LoadIntoBufferAsync(262_144, cancellationToken);
        var body = await response.Content.ReadFromJsonAsync<AgentResponse>(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            if (body?.Error?.Code == "content_filter" &&
                body.Error.ContentFilters?.Any(filter => filter.SourceType == "prompt" && filter.Blocked) == true)
            {
                LogGuardrails(log, body.Error.ContentFilters, "prompt", variant);
                throw new ChattyException("foundry_input_blocked", 422);
            }
            throw new ChattyException("foundry_request_failed");
        }
        log.RecordModelUsage(body?.Usage?.InputTokens, body?.Usage?.OutputTokens,
            body?.Usage?.InputDetails?.CachedTokens, body?.Usage?.OutputDetails?.ReasoningTokens);
        if (variant == AgentVariant.Baseline)
            log.Add("Custom Foundry PII controls", "Not configured");
        LogGuardrails(log, body?.ContentFilters, "prompt", variant);
        if (body?.ContentFilters?.Any(filter => filter.SourceType == "prompt" && filter.Blocked) == true)
            throw new ChattyException("foundry_input_blocked", 422);
        LogGuardrails(log, body?.ContentFilters, "completion", variant,
            body?.IncompleteDetails?.Reason == "content_filter");
        if (body?.IncompleteDetails?.Reason == "content_filter" ||
            body?.ContentFilters?.Any(filter => filter.Blocked) == true)
            throw new ChattyException("foundry_output_blocked", 422);
        if (body?.Status != "completed" || body.Output is null)
            throw new ChattyException("foundry_response_incomplete", 502);
        var text = new List<string>();
        foreach (var item in body.Output)
        {
            if (item.Type == "reasoning")
                continue;
            if (item.Type != "message" || item.Role != "assistant" || item.Content is null)
                throw new ChattyException("unexpected_agent_action", 502);
            foreach (var content in item.Content)
            {
                if (content.Type != "output_text" || string.IsNullOrEmpty(content.Text))
                    throw new ChattyException("agent_refused_or_invalid_output", 502);
                text.Add(content.Text);
            }
        }
        return string.Join("\n", text);
    }

    private static void LogGuardrails(RequestLog log, IReadOnlyList<ContentFilter>? filters,
        string source, AgentVariant variant, bool blocked = false)
    {
        var matches = filters?.Where(filter => filter.SourceType == source).ToArray();
        var pii = matches?.Select(filter => filter.Results?.Pii).OfType<PiiResult>().ToArray();
        log.Add(source == "prompt" ? "Foundry input guardrails" : "Foundry output guardrails",
            blocked || matches?.Any(filter => filter.Blocked) == true ? "Blocked" :
            matches is { Length: > 0 } ? "Evaluated" : "Not reported",
            piiDetected: variant == AgentVariant.Guarded && pii is { Length: > 0 }
                ? pii.Any(result => result.Detected) : null);
    }

    private sealed record AgentResponse(
        string? Status,
        IReadOnlyList<OutputItem>? Output,
        [property: JsonPropertyName("incomplete_details")] IncompleteDetails? IncompleteDetails,
        [property: JsonPropertyName("content_filters")] IReadOnlyList<ContentFilter>? ContentFilters,
        AgentUsage? Usage, AgentError? Error);
    private sealed record AgentError(string? Code,
        [property: JsonPropertyName("content_filters")] IReadOnlyList<ContentFilter>? ContentFilters);
    private sealed record AgentUsage(
        [property: JsonPropertyName("input_tokens")] int? InputTokens,
        [property: JsonPropertyName("output_tokens")] int? OutputTokens,
        [property: JsonPropertyName("input_tokens_details")] InputTokenDetails? InputDetails,
        [property: JsonPropertyName("output_tokens_details")] OutputTokenDetails? OutputDetails);
    private sealed record InputTokenDetails(
        [property: JsonPropertyName("cached_tokens")] int? CachedTokens);
    private sealed record OutputTokenDetails(
        [property: JsonPropertyName("reasoning_tokens")] int? ReasoningTokens);
    private sealed record IncompleteDetails(string? Reason);
    private sealed record ContentFilter(bool Blocked,
        [property: JsonPropertyName("source_type")] string? SourceType,
        [property: JsonPropertyName("content_filter_results")] FilterResults? Results);
    private sealed record FilterResults(
        [property: JsonPropertyName("personally_identifiable_information")] PiiResult? Pii);
    private sealed record PiiResult(bool Detected);
    private sealed record OutputItem(string Type, string? Role, IReadOnlyList<OutputContent>? Content);
    private sealed record OutputContent(string Type, string? Text);
}
