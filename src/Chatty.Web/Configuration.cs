using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Chatty.Web;

public sealed class IdentitySettings
{
    public string TenantId { get; set; } = "";
    public string ClientId { get; set; } = "";
}

public sealed class ChattyOptions
{
    public string LanguageEndpoint { get; set; } = "";
    public string ProjectEndpoint { get; set; } = "";
    public string AgentName { get; set; } = "chatty";
    public string AgentVersion { get; set; } = "";
    public string BaselineAgentName { get; set; } = "chatty-no-pii";
    public string BaselineAgentVersion { get; set; } = "";
    public string ManagedIdentityClientId { get; set; } = "";

    public bool IsValid() =>
        IsEndpoint(LanguageEndpoint, ".cognitiveservices.azure.com", requireProject: false) &&
        IsEndpoint(ProjectEndpoint, ".services.ai.azure.com", requireProject: true) &&
        Regex.IsMatch(AgentName, @"\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z") &&
        int.TryParse(AgentVersion, out var version) && version > 0 &&
        Regex.IsMatch(BaselineAgentName, @"\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z") &&
        BaselineAgentName != AgentName &&
        int.TryParse(BaselineAgentVersion, out var baselineVersion) && baselineVersion > 0;

    private static bool IsEndpoint(string value, string suffix, bool requireProject) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == "https" &&
        uri.Host.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) && uri.IsDefaultPort &&
        string.IsNullOrEmpty(uri.UserInfo) && string.IsNullOrEmpty(uri.Query) &&
        string.IsNullOrEmpty(uri.Fragment) && (requireProject
            ? Regex.IsMatch(uri.AbsolutePath, @"\A/api/projects/[a-zA-Z0-9_-]+/?\z")
            : uri.AbsolutePath == "/");
}

public static class WebAssets
{
    public static IReadOnlyDictionary<string, string> Validate(string root)
    {
        var hashes = new Dictionary<string, string>();
        foreach (var name in new[] { "index.html", "app.js", "app.css" })
        {
            var path = Path.Combine(root, name);
            if (!File.Exists(path) || new FileInfo(path).Length == 0)
                throw new InvalidOperationException($"Required Chatty UI asset is missing or empty: {name}");
            hashes[name] = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
        }
        return hashes;
    }
}

public static class EmployeeAccess
{
    public static bool IsAllowed(ClaimsPrincipal user, string tenantId) =>
        DenialReasons(user, tenantId).Count == 0;

    public static IReadOnlyList<string> DenialReasons(ClaimsPrincipal user, string tenantId)
    {
        if (user.Identity?.IsAuthenticated != true)
            return ["not_authenticated"];
        var reasons = new List<string>();
        if (!string.Equals(user.FindFirstValue("tid"), tenantId, StringComparison.OrdinalIgnoreCase))
            reasons.Add("wrong_tenant");
        if (!Guid.TryParse(user.FindFirstValue("oid"), out _))
            reasons.Add("missing_user_identifier");
        var accountType = user.FindFirstValue("acct");
        if (string.IsNullOrEmpty(accountType))
            reasons.Add("missing_member_claim");
        else if (accountType != "0")
            reasons.Add("not_tenant_member");
        if (!user.IsInRole("Chatty.User"))
            reasons.Add("missing_chatty_role");
        return reasons;
    }

    public static string Owner(ClaimsPrincipal user) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
            $"{user.FindFirstValue("tid")}:{user.FindFirstValue("oid")}")));
}

public sealed class ChattyException(string code, int statusCode = 503) : Exception(code)
{
    public string Code { get; } = code;
    public int StatusCode { get; } = statusCode;
}
