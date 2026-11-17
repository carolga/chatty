namespace Chatty.Web;

// Public West US 3 GPT-5 mini DataZoneStandard retail rates, checked 2026-11-17.
public sealed record ModelCostEstimate(int InputTokens, int OutputTokens, int? CachedInputTokens,
    int? ReasoningTokens)
{
    public decimal InputUsdPerMillion => 0.275m;
    public decimal CachedInputUsdPerMillion => 0.0275m;
    public decimal OutputUsdPerMillion => 2.20m;
    public string RatesCheckedOn => "2026-11-17";
    public string Currency => "USD";
    public decimal EstimatedUsd =>
        ((InputTokens - (CachedInputTokens ?? 0)) * InputUsdPerMillion +
         (CachedInputTokens ?? 0) * CachedInputUsdPerMillion +
         OutputTokens * OutputUsdPerMillion) / 1_000_000m;
}
