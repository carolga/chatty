using Chatty.Web;

namespace Chatty.Tests;

internal sealed class TestScreen : IPiiScreen
{
    public const string Canary = "synthetic-person@example.test";
    public List<string> Calls { get; } = [];
    public Func<string, bool> FailWhen { get; set; } = _ => false;

    public Task<ScreenedText> RedactAsync(string text, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Calls.Add(text);
        if (FailWhen(text))
            throw new ChattyException("pii_screening_unavailable");
        return Task.FromResult(new ScreenedText(text.Replace(Canary, "[REDACTED]", StringComparison.Ordinal),
            text.Contains(Canary, StringComparison.Ordinal) ? 1 : 0));
    }
}

internal sealed class TestKnowledge : IKnowledgeSource
{
    public string? LastQuery { get; private set; }
    public IReadOnlyList<KnowledgePassage> Results { get; set; } =
    [
        new("SYN-001", "Synthetic", "Test income documentation", "Example 1", "POC-1",
            $"Synthetic income documentation contact {TestScreen.Canary}.", true)
    ];

    public Task<IReadOnlyList<KnowledgePassage>> SearchAsync(ScreenedText query, CancellationToken cancellationToken)
    {
        LastQuery = query.Text;
        return Task.FromResult(Results);
    }
}

internal sealed class RecordingAgent : IFoundryAgent
{
    public List<IReadOnlyList<SafeMessage>> Calls { get; } = [];
    public string Reply { get; set; } = $"Synthetic income documentation requires review. [S1] {TestScreen.Canary}";
    public string? BaselineReply { get; set; }
    public string? FailureCode { get; set; }
    public AgentVariant? FailVariant { get; set; }
    public List<AgentVariant> Variants { get; } = [];

    public Task<string> RespondAsync(IReadOnlyList<SafeMessage> messages, CancellationToken cancellationToken,
        AgentVariant variant = AgentVariant.Guarded, RequestLog? log = null)
    {
        Calls.Add(messages.ToArray());
        Variants.Add(variant);
        if (FailureCode is not null && (FailVariant is null || FailVariant == variant))
            throw new ChattyException(FailureCode, 422);
        return Task.FromResult(variant == AgentVariant.Baseline ? BaselineReply ?? Reply : Reply);
    }
}
