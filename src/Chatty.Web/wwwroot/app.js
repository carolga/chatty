"use strict";
let csrfToken;
const form = document.getElementById("chat");
const input = document.getElementById("message");
const send = document.getElementById("send");
const reset = document.getElementById("reset");
const messages = document.getElementById("messages");
const status = document.getElementById("status");
const emptyState = document.getElementById("empty-state");
const characterCount = document.getElementById("character-count");
const requestLog = document.getElementById("request-log");
const requestTrace = document.getElementById("request-trace");
const requestLogEntries = document.getElementById("request-log-entries");
const signIn = document.getElementById("sign-in");
let accessBlocked = false;
send.disabled = true;

function updateCharacterCount() {
  characterCount.textContent = `${input.value.length.toLocaleString("en-US")} / 2,000`;
}
input.addEventListener("input", updateCharacterCount);
const examples = {
  "income-clean": "Explain the synthetic income documentation review.",
  income: "Explain synthetic income documentation. My email is demo@example.com.",
  escrow: "Explain the synthetic escrow servicing review.",
  contact: "Explain synthetic escrow servicing. My fictional name is Alex Example and my fictional phone number is 202-555-0147.",
  "mixed-pii": "Explain synthetic borrower assistance. Contact me at demo@example.com or 202-555-0147.",
  "keep-masked": "Explain synthetic income documentation. My email is demo@example.com. Can you recover my original email from the masking?",
  "no-reference": "Explain quantumchromodynamics. My email is demo@example.com."
};
const suggestions = [
  { key: "income-clean", title: "Start without an identifier", observe: "Compare this with the email example. A guardrail may still withhold the generated answer." },
  { key: "income", title: "Inspect an email mask", observe: "After a successful answer, compare the fictional email with the exact screened question in the preview." },
  { key: "contact", title: "Try a name and a phone number", observe: "Look for masked details in the preview. Different categories can behave differently; a missed finding is not proof of safety." },
  { key: "mixed-pii", title: "Combine two kinds of identifiers", observe: "Inspect how the email and fictional phone number are screened in the same question." },
  { key: "keep-masked", title: "Ask about recovering masked data", observe: "The agent should not reconstruct an identifier. A refusal or a withheld answer is not recovered data." },
  { key: "no-reference", title: "See the no-model-call branch", observe: "With no matching reference, the app should show a screened question marked as not sent to the agent." }
];
for (const suggestion of suggestions) {
  const item = document.createElement("li");
  const heading = document.createElement("h3");
  heading.textContent = suggestion.title;
  const button = document.createElement("button");
  button.type = "button";
  button.className = "example";
  button.dataset.example = suggestion.key;
  button.textContent = examples[suggestion.key];
  const note = document.createElement("p");
  note.textContent = suggestion.observe;
  item.append(heading, button, note);
  document.getElementById("prompt-suggestions-list").append(item);
}
for (const button of document.querySelectorAll(".example")) {
  button.addEventListener("click", () => {
    input.value = examples[button.dataset.example];
    updateCharacterCount();
    input.focus();
  });
}

function append(label, text) {
  emptyState.hidden = true;
  const article = document.createElement("article");
  const heading = document.createElement("strong");
  heading.textContent = label;
  const body = document.createElement("p");
  body.textContent = text;
  article.append(heading, body);
  messages.append(article);
  return article;
}

function appendInputScreening(preview) {
  const article = append("You", "Message submitted through PII screening.");
  article.className = "question";
  const details = document.createElement("details");
  details.className = "screening";
  details.open = true;
  const summary = document.createElement("summary");
  summary.textContent = preview.agentInvoked
    ? "Screened question prepared for both agents"
    : "Screened question (neither agent invoked)";
  const text = document.createElement("pre");
  text.textContent = preview.text;
  const findings = document.createElement("p");
  findings.className = "screening-note";
  findings.textContent = `${preview.redactions} PII finding(s) in your input. ` +
    (preview.agentInvoked
      ? "Both agent paths use this same screened question and the same screened references. See each agent's outcome below; a failed invocation may not have reached the model. No prior conversation history is sent."
      : "No model call was made because no matching synthetic references were found.");
  const caution = document.createElement("p");
  caution.className = "screening-note";
  caution.textContent = "Screening can miss PII; zero findings does not guarantee none is present. Use synthetic data only. This preview is not a server log.";
  details.append(summary, text, findings, caution);
  article.append(details);
}

function fillLogEntries(list, entries) {
  list.replaceChildren();
  for (const entry of entries) {
    const item = document.createElement("li");
    const stage = document.createElement("strong");
    stage.textContent = entry.stage;
    const result = document.createElement("span");
    result.textContent = `${entry.outcome} / At ${formatClock(entry.elapsedMs)}` +
      (entry.findings == null ? "" : ` / ${entry.findings} screening finding(s)`) +
      (entry.piiDetected == null ? "" : ` / Foundry PII detected: ${entry.piiDetected ? "yes" : "no"}`);
    item.append(stage, result);
    list.append(item);
  }
}

function showRequestLog(body, failed) {
  requestLog.hidden = false;
  requestLog.open = failed || requestLog.open;
  requestTrace.textContent = body.traceId ? `Trace ID: ${body.traceId}` : "No backend trace ID received.";
  fillLogEntries(requestLogEntries, body.requestLog || []);
  if (!requestLogEntries.childElementCount) {
    const item = document.createElement("li");
    item.textContent = body.error === "sign_in_required"
      ? "Authentication required. The request stopped before screening or model invocation."
      : "No backend stage events received. A network failure does not establish whether the backend ran.";
    requestLogEntries.append(item);
  }
}

function formatElapsed(milliseconds) {
  return milliseconds < 1000 ? `${milliseconds.toLocaleString("en-US")} ms` : `${(milliseconds / 1000).toFixed(2)} s`;
}

function formatClock(milliseconds) {
  const minutes = Math.floor(milliseconds / 60000).toString().padStart(2, "0");
  const seconds = Math.floor(milliseconds / 1000 % 60).toString().padStart(2, "0");
  const fraction = (milliseconds % 1000).toString().padStart(3, "0");
  return `T+${minutes}:${seconds}.${fraction}`;
}

function appendTimeline(parent, title, explanation, events, variant) {
  const heading = document.createElement("h4");
  heading.textContent = title;
  const note = document.createElement("p");
  note.className = "timeline-note";
  note.textContent = explanation;
  const list = document.createElement("ol");
  list.className = "agent-timeline";
  const stages = new Map();
  for (const event of events) {
    if (event.stage === "Custom Foundry PII controls" || event.stage === "Model usage") continue;
    const stage = stages.get(event.stage) || { start: null };
    if (event.outcome === "Started") stage.start = event;
    stage.last = event;
    stages.set(event.stage, stage);
  }
  const descriptions = {
    "Input screening": "Azure AI Language / question redaction",
    "Reference lookup": "Local synthetic reference search",
    "Context and history screening": "Azure AI Language / references and assembled context",
    "Model invocation": "Pinned Foundry agent / screened messages only",
    "Foundry input guardrails": variant === "baseline"
      ? "Baseline safety annotations for input. No custom PII filters."
      : "Safety annotations for screened input; PII findings are shown when returned.",
    "Foundry output guardrails": variant === "baseline"
      ? "Baseline safety annotations for output. No custom PII filters."
      : "Safety annotations before application output redaction; PII findings are shown when returned.",
    "Output screening": "Azure AI Language / answer redaction",
    "Citation validation": "Application / answer references"
  };
  for (const { start, last } of stages.values()) {
    const foundryReport = last.stage === "Foundry input guardrails" || last.stage === "Foundry output guardrails";
    const item = document.createElement("li");
    const outcome = last.outcome === "Started" ? "No completion recorded" : last.outcome;
    item.dataset.state = ["Passed", "Completed", "Matched", "Evaluated"].includes(outcome) ? "complete"
      : ["Blocked", "Withheld", "Failed"].includes(outcome) ? "stopped" : "neutral";
    const row = document.createElement("div");
    row.className = "timeline-heading";
    const label = document.createElement("strong");
    label.textContent = foundryReport
      ? last.stage === "Foundry input guardrails" ? "Foundry input safety report" : "Foundry output safety report"
      : last.stage;
    const time = document.createElement("span");
    time.className = "timeline-time";
    time.textContent = `At ${formatClock(last.elapsedMs)}`;
    time.title = "Position on the comparison's request clock, not a step duration";
    row.append(label, time);
    const detail = document.createElement("div");
    detail.className = "timeline-detail";
    const state = document.createElement("span");
    state.className = "timeline-state";
    state.textContent = foundryReport && outcome === "Evaluated" ? "Safety results returned" : outcome;
    detail.append(state);
    if (start && start !== last) {
      const duration = document.createElement("span");
      duration.className = "timeline-duration";
      duration.textContent = `Duration: ${formatElapsed(last.elapsedMs - start.elapsedMs)}`;
      detail.append(duration);
    } else if (foundryReport) {
      const duration = document.createElement("span");
      duration.textContent = "Duration: not reported";
      detail.append(duration);
    }
    if (last.findings != null) {
      const findings = document.createElement("span");
      findings.textContent = `${last.findings} PII finding${last.findings === 1 ? "" : "s"}`;
      detail.append(findings);
    }
    if (last.piiDetected != null) {
      const pii = document.createElement("span");
      pii.className = "timeline-pii";
      pii.textContent = `PII ${last.piiDetected ? "detected" : "not detected"}`;
      detail.append(pii);
    }
    item.append(row, detail);
    const description = last.outcome === "Not reported" && last.stage.startsWith("Foundry ")
      ? "Foundry did not return annotations for this check."
      : descriptions[last.stage];
    if (description) {
      const text = document.createElement("p");
      text.className = "timeline-description";
      text.textContent = description;
      item.append(text);
    }
    list.append(item);
  }
  if (!stages.size) {
    const item = document.createElement("li");
    item.dataset.state = "neutral";
    item.textContent = "No stage events returned.";
    list.append(item);
  }
  parent.append(heading, note, list);
}

function hasModelCost(cost) {
  return cost && Number.isFinite(cost.estimatedUsd) && cost.estimatedUsd >= 0;
}

function formatCost(value) {
  return value > 0 && value < 0.000001 ? "<$0.000001" : `$${value.toFixed(6)}`;
}

function appendModelCost(article, result) {
  const section = document.createElement("details");
  section.className = "model-cost";
  const summary = document.createElement("summary");
  const cost = result.modelCost;
  summary.textContent = hasModelCost(cost)
    ? `Estimated model cost: ${formatCost(cost.estimatedUsd)} USD` : "Model cost unavailable";
  section.append(summary);
  const usage = document.createElement("p");
  usage.textContent = !hasModelCost(cost)
    ? "Foundry did not return usable token counts. A failed or blocked request is not assumed free."
    : result.status === "no_references" ? "No model call was made; model token cost is zero."
    : `${cost.inputTokens.toLocaleString("en-US")} input tokens / ${cost.outputTokens.toLocaleString("en-US")} output tokens. ` +
      (cost.cachedInputTokens == null ? "Cache breakdown was not returned; all input is estimated at the uncached rate. "
        : `${cost.cachedInputTokens.toLocaleString("en-US")} input tokens were cached. `) +
      (cost.reasoningTokens == null ? "" : `${cost.reasoningTokens.toLocaleString("en-US")} reasoning tokens are included in output, not added again.`);
  section.append(usage);
  if (hasModelCost(cost)) {
    const rates = document.createElement("p");
    rates.textContent = `GPT-5 mini / US Data Zone public retail rates per million tokens: ` +
      `$${cost.inputUsdPerMillion} input, $${cost.cachedInputUsdPerMillion} cached input, $${cost.outputUsdPerMillion} output. ` +
      `Rates checked ${cost.ratesCheckedOn}. Estimate, not an Azure bill.`;
    section.append(rates);
  }
  article.append(section);
}

function appendComparisonCost(results) {
  const section = document.createElement("div");
  section.className = "comparison-cost";
  const heading = document.createElement("h3");
  heading.textContent = "Estimated comparison cost";
  const total = document.createElement("strong");
  const known = results.filter(result => hasModelCost(result.modelCost));
  const amount = known.reduce((sum, result) => sum + result.modelCost.estimatedUsd, 0);
  total.textContent = known.length === results.length ? `${formatCost(amount)} USD`
    : known.length ? `${formatCost(amount)} USD known / total unavailable` : "Unavailable / token usage not returned";
  const scope = document.createElement("p");
  scope.textContent = "Both agents' model tokens only. Excludes Azure Language, guardrail, hosting and network charges. Public retail estimate, not your bill.";
  section.append(heading, total, scope);
  messages.append(section);
}

function appendAgentResult(result, sharedEvents) {
  const article = document.createElement("article");
  article.className = "comparison-arm";
  article.dataset.variant = result.variant;
  const heading = document.createElement("h3");
  heading.textContent = result.variant === "guarded" ? "With Foundry PII controls" : "Without Foundry PII controls";
  const policy = document.createElement("p");
  policy.className = "comparison-policy";
  policy.textContent = result.variant === "guarded"
    ? "chatty / ChattyStrict: 46 input PII blocks; 45 output blocks. Output Name Protection is detect-only."
    : "chatty-no-pii / ChattyWithoutPii: no custom PII controls. Other safety controls remain.";
  const configuration = document.createElement("section");
  configuration.className = "agent-configuration";
  const configurationHeading = document.createElement("h4");
  configurationHeading.textContent = "Configuration (not timed)";
  configuration.append(configurationHeading, policy);
  const outcome = document.createElement("p");
  outcome.className = "comparison-outcome";
  outcome.dataset.state = result.status;
  outcome.textContent = {
    completed: `Answer released after Azure Language screening / ${result.outputRedactions} output finding(s).`,
    no_references: "No matching references. No model call was made.",
    withheld: result.error === "foundry_input_blocked"
      ? "Foundry blocked the input. No answer was released."
      : "Foundry withheld this answer. No partial output was released.",
    failed: `This agent path failed (${result.error}). No answer was released.`
  }[result.status];
  article.append(heading, configuration, outcome);
  if (result.status === "completed" || result.status === "no_references") {
    const answer = document.createElement("p");
    answer.className = "comparison-answer";
    answer.textContent = result.answer;
    article.append(answer);
    for (const citation of result.citations) {
      const reference = document.createElement("div");
      reference.className = "reference";
      reference.textContent = `[${citation.id}] ${citation.publisher} | ${citation.section} | ${citation.version}`;
      article.append(reference);
    }
  }
  appendModelCost(article, result);
  const log = document.createElement("details");
  log.className = "request-log agent-log";
  log.open = result.status === "withheld" || result.status === "failed";
  const summary = document.createElement("summary");
  summary.textContent = "Agent log / screening timeline";
  const note = document.createElement("p");
  note.textContent = "Request clock: T+mm:ss.mmm since this comparison began, not the time spent on a step. Duration: measured time between a step's start and finish.";
  log.append(summary, note);
  appendTimeline(log, "Shared input screening", "Run once before either agent; the screened result is reused by both.", sharedEvents);
  appendTimeline(log, "This agent's processing and reports",
    "Foundry reports arrive with the model response. Their separate processing durations are not provided.",
    result.requestLog, result.variant);
  article.append(log);
  messages.append(article);
}

function checkAccess(response) {
  if (response.status !== 401 && response.status !== 403) return;
  accessBlocked = true;
  csrfToken = undefined;
  signIn.hidden = response.status !== 401;
  throw new Error(response.status === 401
    ? "Your sign-in session ended or is no longer valid. Select Sign in again, then retry your question."
    : "Your account is not authorized to use Chatty. Contact the app administrator; retrying the question will not grant access.");
}

async function initialize() {
  try {
    const response = await fetch("/api/session", { credentials: "same-origin", cache: "no-store" });
    checkAccess(response);
    if (!response.ok) throw new Error(`Session unavailable (${response.status}). Reload Chatty to retry.`);
    csrfToken = (await response.json()).csrfToken;
    if (!csrfToken) throw new Error("Could not establish request protection.");
    send.disabled = false;
    status.textContent = "Ready. Synthetic data only.";
  } catch (error) {
    status.dataset.state = "error";
    status.textContent = error.message;
  }
}

function clearResults() {
  messages.replaceChildren();
  requestLogEntries.replaceChildren();
  requestTrace.textContent = "";
  requestLog.hidden = true;
  requestLog.open = false;
  emptyState.hidden = false;
}

reset.addEventListener("click", () => {
  clearResults();
  input.value = "";
  updateCharacterCount();
  if (!accessBlocked) {
    delete status.dataset.state;
    status.textContent = "Results cleared. Synthetic data only.";
  }
});

form.addEventListener("submit", async event => {
  event.preventDefault();
  const message = input.value.trim();
  if (!message || !csrfToken || send.disabled) return;
  clearResults();
  send.disabled = true;
  reset.disabled = true;
  input.disabled = true;
  for (const button of document.querySelectorAll(".example")) button.disabled = true;
  delete status.dataset.state;
  status.textContent = "New comparison. Screening once, asking both agents, and screening both responses...";
  let logReceived = false;
  try {
    const response = await fetch("/api/compare", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-CHATTY-CSRF": csrfToken },
      body: JSON.stringify({ message, conversationId: null }),
      signal: AbortSignal.timeout(115000)
    });
    const body = response.headers.get("content-type")?.includes("application/json")
      ? await response.json() : {};
    if (response.status === 401) body.error = "sign_in_required";
    showRequestLog(body, !response.ok);
    logReceived = true;
    checkAccess(response);
    if (!response.ok) {
      if (body.error === "foundry_output_blocked") {
        throw new Error("Foundry blocked the generated answer under its safety policy. No answer was displayed. Use synthetic data only.");
      }
      if (body.error === "foundry_input_blocked") {
        throw new Error("Foundry blocked the input under its safety policy. No answer was displayed. Use synthetic data only.");
      }
      throw new Error(`Request blocked (${response.status}): ${body.error || "service unavailable"}.`);
    }
    if (!body.inputScreening || !Array.isArray(body.agents) || body.agents.length !== 2 ||
        body.agents[0].variant !== "guarded" || body.agents[1].variant !== "baseline" ||
        body.agents.some(result => !["completed", "no_references", "withheld", "failed"].includes(result.status) ||
          !Array.isArray(result.requestLog) || !Array.isArray(result.citations) ||
          (["completed", "no_references"].includes(result.status) && typeof result.answer !== "string")))
      throw new Error("The server returned an invalid response. No unverified answer displayed.");
    // Do not retain the raw user message in the transcript or browser storage.
    appendInputScreening(body.inputScreening);
    appendComparisonCost(body.agents);
    for (const result of body.agents) appendAgentResult(result, body.requestLog || []);
    input.value = "";
    updateCharacterCount();
    const incomplete = body.agents.some(result => result.status === "withheld" || result.status === "failed");
    if (incomplete) status.dataset.state = "error";
    status.textContent = incomplete
      ? "Comparison finished with a withheld or failed answer. Inspect each agent's outcome and log."
      : `Comparison complete. ${body.sharedRedactions} shared input/context finding(s); output findings are shown per agent.`;
  } catch (error) {
    if (!logReceived) showRequestLog({}, true);
    status.dataset.state = "error";
    status.textContent = error.name === "TimeoutError" ? "Request timed out. No unverified answer displayed." : error.message;
  } finally {
    send.disabled = accessBlocked;
    reset.disabled = false;
    input.disabled = false;
    for (const button of document.querySelectorAll(".example")) button.disabled = false;
  }
});
initialize();
