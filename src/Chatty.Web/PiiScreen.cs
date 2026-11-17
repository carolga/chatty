using Azure;
using Azure.AI.TextAnalytics;

namespace Chatty.Web;

public sealed record ScreenedText
{
    public string Text { get; }
    public int Redactions { get; }

    internal ScreenedText(string text, int redactions)
    {
        Text = text;
        Redactions = redactions;
    }
}

public interface IPiiScreen
{
    Task<ScreenedText> RedactAsync(string text, CancellationToken cancellationToken);
}

public sealed class AzurePiiScreen(TextAnalyticsClient client) : IPiiScreen
{
    public async Task<ScreenedText> RedactAsync(string text, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(text) || text.Length > 5000)
            throw new ChattyException("unscreenable_content", 422);

        try
        {
            var response = await client.RecognizePiiEntitiesAsync(text, "en",
                new RecognizePiiEntitiesOptions { DisableServiceLogs = true }, cancellationToken);
            var entities = response.Value;
            if (entities.Warnings.Count != 0 || string.IsNullOrWhiteSpace(entities.RedactedText))
                throw new ChattyException("pii_screening_incomplete");
            return new ScreenedText(entities.RedactedText, entities.Count);
        }
        catch (RequestFailedException)
        {
            throw new ChattyException("pii_screening_unavailable");
        }
    }
}
