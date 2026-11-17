using System.Text.Json;
using System.Text.RegularExpressions;

namespace Chatty.Web;

public sealed record KnowledgePassage(string Id, string Publisher, string Title,
    string Section, string Version, string Text, bool Synthetic);
public sealed record Citation(string Id, string Publisher, string Title, string Section, string Version, bool Synthetic);

public interface IKnowledgeSource
{
    Task<IReadOnlyList<KnowledgePassage>> SearchAsync(ScreenedText query, CancellationToken cancellationToken);
}

public sealed partial class SyntheticKnowledge : IKnowledgeSource
{
    private readonly IReadOnlyList<KnowledgePassage> passages;
    private static readonly HashSet<string> StopWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "a", "an", "and", "are", "as", "at", "be", "can", "do", "does", "for", "from",
        "how", "i", "in", "is", "it", "me", "my", "of", "on", "or", "please", "the",
        "this", "to", "what", "which", "with", "you"
    };

    public SyntheticKnowledge(IWebHostEnvironment environment)
    {
        var json = File.ReadAllText(Path.Combine(environment.ContentRootPath, "Knowledge", "synthetic.json"));
        passages = JsonSerializer.Deserialize<List<KnowledgePassage>>(json,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidOperationException("Synthetic knowledge is missing.");
        if (passages.Count == 0 || passages.Any(p => !p.Synthetic || p.Text.Length > 2000 ||
            string.IsNullOrWhiteSpace(p.Text) || !Regex.IsMatch(p.Id, @"\ASYN-[0-9]{3}\z")) ||
            passages.Select(p => p.Id).Distinct().Count() != passages.Count)
            throw new InvalidOperationException("Synthetic knowledge failed validation.");
    }

    public Task<IReadOnlyList<KnowledgePassage>> SearchAsync(ScreenedText query, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var terms = Words().Matches(query.Text).Select(m => m.Value.ToLowerInvariant())
            .Where(w => !StopWords.Contains(w)).ToHashSet();
        IReadOnlyList<KnowledgePassage> result = passages
            .Select(p => new
            {
                Passage = p,
                Score = Words().Matches(p.Text + " " + p.Title)
                .Select(m => m.Value.ToLowerInvariant()).Distinct().Count(terms.Contains)
            })
            .Where(p => p.Score >= 2).OrderByDescending(p => p.Score)
            .ThenBy(p => p.Passage.Id, StringComparer.Ordinal).Take(3).Select(p => p.Passage).ToArray();
        return Task.FromResult(result);
    }

    [GeneratedRegex(@"[a-zA-Z]{3,}", RegexOptions.CultureInvariant)]
    private static partial Regex Words();
}
