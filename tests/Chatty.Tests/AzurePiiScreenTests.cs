using Azure;
using Azure.AI.TextAnalytics;
using Azure.Core;
using Chatty.Web;

namespace Chatty.Tests;

public sealed class AzurePiiScreenTests
{
    [Fact]
    public async Task Uses_sdk_redacted_text_and_disables_service_logging()
    {
        var client = new StubLanguageClient();
        var result = await new AzurePiiScreen(client).RedactAsync("Contact " + TestScreen.Canary, default);
        Assert.Equal("Contact [MASKED]", result.Text);
        Assert.Equal(1, result.Redactions);
        Assert.True(client.ServiceLogsDisabled);
        Assert.Equal("en", client.Language);
    }

    [Fact]
    public async Task Azure_service_error_becomes_content_free_failure()
    {
        var client = new StubLanguageClient { Fail = true };
        var failure = await Assert.ThrowsAsync<ChattyException>(() =>
            new AzurePiiScreen(client).RedactAsync(TestScreen.Canary, default));
        Assert.Equal("pii_screening_unavailable", failure.Code);
        Assert.DoesNotContain(TestScreen.Canary, failure.ToString());
    }

    private sealed class StubLanguageClient : TextAnalyticsClient
    {
        public bool Fail { get; set; }
        public bool ServiceLogsDisabled { get; private set; }
        public string? Language { get; private set; }

        public override Task<Response<PiiEntityCollection>> RecognizePiiEntitiesAsync(
            string document, string? language = null, RecognizePiiEntitiesOptions? options = null,
            CancellationToken cancellationToken = default)
        {
            ServiceLogsDisabled = options?.DisableServiceLogs == true;
            Language = language;
            if (Fail)
                throw new RequestFailedException(503, TestScreen.Canary);
            var entity = TextAnalyticsModelFactory.PiiEntity(TestScreen.Canary, "Email", "", .99, 8, TestScreen.Canary.Length);
            return Task.FromResult(Response.FromValue(
                TextAnalyticsModelFactory.PiiEntityCollection([entity], "Contact [MASKED]"), new StubResponse()));
        }
    }

    private sealed class StubResponse : Response
    {
        public override int Status => 200;
        public override string ReasonPhrase => "OK";
        public override Stream? ContentStream { get; set; }
        public override string ClientRequestId { get; set; } = "";
        public override void Dispose() { }
        protected override bool ContainsHeader(string name) => false;
        protected override IEnumerable<HttpHeader> EnumerateHeaders() => [];
        protected override bool TryGetHeader(string name, out string value) { value = ""; return false; }
        protected override bool TryGetHeaderValues(string name, out IEnumerable<string> values) { values = []; return false; }
    }
}
