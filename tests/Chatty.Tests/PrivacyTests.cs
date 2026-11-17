using System.Security.Claims;
using Chatty.Web;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging.Abstractions;

namespace Chatty.Tests;

public sealed class PrivacyTests : IDisposable
{
    private readonly MemoryCache cache = new(new MemoryCacheOptions { SizeLimit = 1024 });
    private readonly TestScreen screen = new();
    private readonly TestKnowledge knowledge = new();
    private readonly RecordingAgent agent = new();
    private readonly ConversationStore store;
    private readonly ChatService service;

    public PrivacyTests()
    {
        store = new(cache);
        service = new(screen, knowledge, agent, store, NullLogger<ChatService>.Instance,
            new RequestLog(NullLogger<RequestLog>.Instance));
    }

    [Fact]
    public async Task Comparison_shares_one_screened_request_and_independently_screens_both_answers()
    {
        var result = await service.CompareAsync(new($"Income documentation {TestScreen.Canary}"), default);

        Assert.Equal([AgentVariant.Guarded, AgentVariant.Baseline], agent.Variants);
        Assert.Equal(agent.Calls[0], agent.Calls[1]);
        Assert.All(agent.Calls.SelectMany(call => call),
            message => Assert.DoesNotContain(TestScreen.Canary, message.Content.Text));
        Assert.Equal(1, screen.Calls.Count(text => text.StartsWith("Income documentation", StringComparison.Ordinal)));
        Assert.Equal(2, screen.Calls.Count(text => text == agent.Reply));
        Assert.Equal(2, result.Agents.Count);
        Assert.All(result.Agents, arm =>
        {
            Assert.Equal("completed", arm.Status);
            Assert.DoesNotContain(TestScreen.Canary, arm.Answer!);
            Assert.Single(arm.Citations);
            Assert.Equal(1, arm.OutputRedactions);
            Assert.Contains(arm.RequestLog, entry => entry.Stage == "Output screening" && entry.Outcome == "Passed");
            Assert.DoesNotContain(arm.RequestLog, entry => entry.Stage == "Input screening");
        });
        Assert.NotSame(result.Agents[0].RequestLog, result.Agents[1].RequestLog);
    }

    [Theory]
    [InlineData("foundry_output_blocked", "withheld")]
    [InlineData("foundry_input_blocked", "withheld")]
    [InlineData("foundry_request_failed", "failed")]
    public async Task One_agent_failure_does_not_hide_the_other_screened_answer(string code, string status)
    {
        agent.FailureCode = code;
        agent.FailVariant = AgentVariant.Guarded;
        var result = await service.CompareAsync(new("Income documentation"), default);

        Assert.Equal(status, result.Agents[0].Status);
        Assert.Equal(code, result.Agents[0].Error);
        Assert.Null(result.Agents[0].Answer);
        Assert.Empty(result.Agents[0].Citations);
        Assert.DoesNotContain(result.Agents[0].RequestLog, entry => entry.Stage == "Output screening");
        Assert.Equal("completed", result.Agents[1].Status);
        Assert.DoesNotContain(TestScreen.Canary, result.Agents[1].Answer!);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Failed_output_screen_or_bad_citations_are_isolated_to_the_affected_arm(bool screenFailure)
    {
        agent.BaselineReply = $"Baseline answer {TestScreen.Canary}" + (screenFailure ? " [S1]" : " [S99]");
        screen.FailWhen = text => screenFailure && text.StartsWith("Baseline answer", StringComparison.Ordinal);
        var result = await service.CompareAsync(new("Income documentation"), default);

        Assert.Equal("completed", result.Agents[0].Status);
        Assert.Equal("failed", result.Agents[1].Status);
        Assert.Equal(screenFailure ? "pii_screening_unavailable" : "unsupported_agent_citations", result.Agents[1].Error);
        Assert.Null(result.Agents[1].Answer);
        Assert.Empty(result.Agents[1].Citations);
        Assert.DoesNotContain(TestScreen.Canary, System.Text.Json.JsonSerializer.Serialize(result));
    }

    [Theory]
    [InlineData("question")]
    [InlineData("passage")]
    [InlineData("context")]
    public async Task Shared_screening_failure_prevents_both_comparison_calls(string stage)
    {
        screen.FailWhen = text => stage switch
        {
            "question" => text.StartsWith("Income", StringComparison.Ordinal),
            "passage" => text.Contains("\"Publisher\"", StringComparison.Ordinal),
            _ => text.Contains("\"references\"", StringComparison.Ordinal)
        };
        await Assert.ThrowsAsync<ChattyException>(() =>
            service.CompareAsync(new("Income documentation"), default));
        Assert.Empty(agent.Calls);
    }

    [Fact]
    public async Task Comparison_without_references_skips_both_agents_and_rejects_replayed_conversations()
    {
        knowledge.Results = [];
        var result = await service.CompareAsync(new($"Unrelated {TestScreen.Canary}"), default);
        Assert.False(result.InputScreening.AgentInvoked);
        Assert.All(result.Agents, arm => Assert.Equal("no_references", arm.Status));
        Assert.All(result.Agents, arm => Assert.Equal(0m, arm.ModelCost?.EstimatedUsd));
        var error = await Assert.ThrowsAsync<ChattyException>(() =>
            service.CompareAsync(new("Income documentation", Guid.NewGuid()), default));
        Assert.Equal("comparison_requires_new_conversation", error.Code);
        Assert.Empty(agent.Calls);
    }

    [Fact]
    public async Task Screens_input_retrieved_context_output_and_replayed_history()
    {
        var first = await service.SendAsync("employee", new($"Income documentation for {TestScreen.Canary}"), default);
        var second = await service.SendAsync("employee", new("Explain the income documentation.", first.ConversationId), default);

        Assert.DoesNotContain(TestScreen.Canary, knowledge.LastQuery!);
        Assert.All(agent.Calls.SelectMany(call => call),
            message => Assert.DoesNotContain(TestScreen.Canary, message.Content.Text));
        Assert.DoesNotContain(TestScreen.Canary, first.Answer);
        Assert.DoesNotContain(TestScreen.Canary, second.Answer);
        Assert.All(store.Get("employee", first.ConversationId).Session.Messages,
            message => Assert.DoesNotContain(TestScreen.Canary, message.Content.Text));
        Assert.Contains(first.Answer, screen.Calls);
        Assert.Contains(agent.Calls[1], message =>
            message.Role == "assistant" && message.Content.Text == first.Answer);
        Assert.Single(second.Citations);
        Assert.True(first.InputScreening.AgentInvoked);
        Assert.Equal(agent.Calls[0][^1].Content.Text, first.InputScreening.Text);
        Assert.DoesNotContain(TestScreen.Canary, first.InputScreening.Text);
        Assert.Equal(1, first.InputScreening.Redactions);
        Assert.Equal(agent.Calls[1][^1].Content.Text, second.InputScreening.Text);
        Assert.Equal(0, second.InputScreening.Redactions);
    }

    [Theory]
    [InlineData("question")]
    [InlineData("passage")]
    [InlineData("assembled-context")]
    public async Task Screening_failure_before_inference_prevents_all_model_calls(string failure)
    {
        screen.FailWhen = text => failure switch
        {
            "question" => text.StartsWith("Income", StringComparison.Ordinal),
            "passage" => text.Contains("\"Publisher\"", StringComparison.Ordinal),
            _ => text.Contains("\"references\"", StringComparison.Ordinal)
        };
        await Assert.ThrowsAsync<ChattyException>(() =>
            service.SendAsync("employee", new("Income documentation"), default));
        Assert.Empty(agent.Calls);
    }

    [Fact]
    public async Task History_findings_contribute_to_the_total_but_not_the_current_input_preview()
    {
        var (id, session) = store.Get("employee", null);
        session.Messages.Add(new SafeMessage("user", new ScreenedText($"Earlier input {TestScreen.Canary}", 0)));
        session.Messages.Add(new SafeMessage("assistant", new ScreenedText("Earlier screened answer.", 0)));

        var result = await service.SendAsync("employee", new("Income documentation", id), default);

        Assert.Equal(0, result.InputScreening.Redactions);
        Assert.Equal(3, result.Redactions);
        Assert.Equal("Income documentation", result.InputScreening.Text);
        Assert.All(agent.Calls.Single(), message => Assert.DoesNotContain(TestScreen.Canary, message.Content.Text));
    }

    [Fact]
    public async Task Failed_output_screen_does_not_commit_a_turn()
    {
        var (id, session) = store.Get("employee", null);
        screen.FailWhen = text => text.StartsWith("Synthetic income documentation requires", StringComparison.Ordinal);
        await Assert.ThrowsAsync<ChattyException>(() =>
            service.SendAsync("employee", new("Income documentation", id), default));
        Assert.Single(agent.Calls);
        Assert.Empty(session.Messages);
    }

    [Fact]
    public async Task Failed_history_rescreening_blocks_follow_up()
    {
        var first = await service.SendAsync("employee", new("Income documentation"), default);
        screen.FailWhen = text => text == first.Answer;
        await Assert.ThrowsAsync<ChattyException>(() =>
            service.SendAsync("employee", new("Follow-up about income", first.ConversationId), default));
        Assert.Single(agent.Calls);
    }

    [Fact]
    public async Task Another_employee_cannot_read_or_append_to_a_conversation()
    {
        var first = await service.SendAsync("employee-one", new("Income documentation"), default);
        var failure = await Assert.ThrowsAsync<ChattyException>(() =>
            service.SendAsync("employee-two", new("Income documentation", first.ConversationId), default));
        Assert.Equal(404, failure.StatusCode);
        Assert.Single(agent.Calls);
    }

    [Fact]
    public async Task No_references_returns_explicit_insufficient_evidence_without_inference()
    {
        knowledge.Results = [];
        var result = await service.SendAsync("employee", new($"Unrelated question {TestScreen.Canary}"), default);
        Assert.Contains("Insufficient evidence", result.Answer);
        Assert.Empty(agent.Calls);
        Assert.Empty(result.Citations);
        Assert.False(result.InputScreening.AgentInvoked);
        Assert.DoesNotContain(TestScreen.Canary, result.InputScreening.Text);
        Assert.Equal(1, result.InputScreening.Redactions);
    }

    [Theory]
    [InlineData("Unsupported claim")]
    [InlineData("Unsupported claim [S99]")]
    public async Task Missing_or_invented_citations_are_rejected(string reply)
    {
        agent.Reply = reply;
        var failure = await Assert.ThrowsAsync<ChattyException>(() =>
            service.SendAsync("employee", new("Income documentation"), default));
        Assert.Equal("unsupported_agent_citations", failure.Code);
    }

    [Fact]
    public async Task Oversize_question_never_reaches_screening_or_model()
    {
        await Assert.ThrowsAsync<ChattyException>(() =>
            service.SendAsync("employee", new(new string('x', 2001)), default));
        Assert.Empty(screen.Calls);
        Assert.Empty(agent.Calls);
    }

    [Theory]
    [InlineData("0", "Chatty.User", "11111111-1111-1111-1111-111111111111", true)]
    [InlineData("1", "Chatty.User", "11111111-1111-1111-1111-111111111111", false)]
    [InlineData("", "Chatty.User", "11111111-1111-1111-1111-111111111111", false)]
    [InlineData("0", "Unassigned", "11111111-1111-1111-1111-111111111111", false)]
    [InlineData("0", "Chatty.User", "22222222-2222-2222-2222-222222222222", false)]
    public void Employee_policy_requires_member_claim_tenant_and_assigned_role(
        string accountType, string role, string tenant, bool allowed)
    {
        var user = new ClaimsPrincipal(new ClaimsIdentity(
        [
            new("acct", accountType), new("roles", role), new("tid", tenant),
            new("oid", "33333333-3333-3333-3333-333333333333")
        ], "Test", "oid", "roles"));
        Assert.Equal(allowed, EmployeeAccess.IsAllowed(user, "11111111-1111-1111-1111-111111111111"));
    }

    public void Dispose() => cache.Dispose();
}
