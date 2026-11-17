using System.Diagnostics;

namespace Chatty.Web;

public sealed record RequestLogEntry(string Stage, string Outcome, long ElapsedMs,
    int? Findings = null, bool? PiiDetected = null);

// Request-scoped teaching telemetry, never an upstream payload or a shared log feed.
public sealed class RequestLog(ILogger<RequestLog> logger)
{
    private readonly long started = Stopwatch.GetTimestamp();
    private readonly List<RequestLogEntry> entries = [];
    public IReadOnlyList<RequestLogEntry> Entries => entries.ToArray();
    public ModelCostEstimate? ModelCost { get; private set; }

    private RequestLog(ILogger<RequestLog> logger, long started) : this(logger) => this.started = started;
    public RequestLog Fork() => new(logger, started);

    public void RecordModelUsage(int? input, int? output, int? cached, int? reasoning)
    {
        if (input is null or < 0 || output is null or < 0 || cached < 0 || cached > input ||
            reasoning < 0 || reasoning > output)
        {
            Add("Model usage", input is null || output is null ? "Not reported" : "Invalid metadata");
            return;
        }
        ModelCost = new(input.Value, output.Value, cached, reasoning);
        logger.LogInformation("Model usage: inputTokens={Input}; outputTokens={Output}; cachedInputTokens={Cached}; reasoningTokens={Reasoning}",
            input, output, cached, reasoning);
    }

    public void Add(string stage, string outcome, int? findings = null, bool? piiDetected = null)
    {
        var entry = new RequestLogEntry(stage, outcome,
            (long)Stopwatch.GetElapsedTime(started).TotalMilliseconds, findings, piiDetected);
        entries.Add(entry);
        logger.LogInformation(
            "Request stage: {Stage}; outcome={Outcome}; elapsedMs={ElapsedMs}; findings={Findings}; piiDetected={PiiDetected}",
            stage, outcome, entry.ElapsedMs, findings, piiDetected);
    }
}
