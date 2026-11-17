# Teach Chatty in ten minutes

The lesson: **an output guardrail does not replace screening before inference.**
Use fictional data only. This is deliberately a small ASP.NET Core app, not an
agent framework tutorial.

## Start with the agent

Open these files under `src/Chatty.Web/Agent`:

- **`instructions.md`** is the actual prompt, not a copy in documentation.
- **`definition.json`** identifies the ordinary prompt agent and its model.
- **`baseline-definition.json`** identifies `chatty-no-pii`, bound to a separate
  model deployment without custom PII controls. It uses the same `instructions.md`.

`scripts/Deploy-FromJumpBox.ps1` reads these files, adds the same `instructions`
to both Foundry definitions, and verifies each pinned agent before publishing. Line
endings are normalized; prompt content must still match. An unexpected prompt,
model, harness, tool list, or version stops publication. Editing the local file
does not silently update the live agent or select `latest`.

The live app references the explicitly configured name/version through the
Responses API. It does not send the instructions as a request-level system
prompt. There is no local/harness agent hiding behind the web UI.

## Follow the request

| File under `src/Chatty.Web` | Read it for |
| --- | --- |
| `Program.cs` | Startup, employee policy, CSRF, rate limit, HTTP endpoints, content-free request logging |
| `ChatService.cs` | `CompareAsync`: prepare screened input/context once, run two independent arms, redact each answer, check citations; `SendAsync` preserves the legacy history route |
| `PiiScreen.cs` | `AzurePiiScreen`, the Azure AI Language call; `ScreenedText` is the explicit screened-value type |
| `Knowledge.cs` | `SyntheticKnowledge`, bounded keyword matching against three original synthetic references |
| `FoundryPromptAgent.cs` | Select one of two configured pinned agents; each Responses API call disables storage/streaming/tools |
| `wwwroot/app.js` | Plain browser JavaScript; all returned text uses `textContent`, never `innerHTML` |

`ConversationStore` lives next to the orchestration in `ChatService.cs`. It keeps
screened turns only, is owner-bound, expires at 20 minutes, and allows six
answered turns. There is no database, vector service, upload pipeline, or extra
abstraction to explain.
The browser uses `/api/compare`, starts fresh on every **Screen & ask**, and
replaces both results and logs. Comparisons never read or write the conversation
store. The legacy `/api/chat` history and isolation behavior is unchanged.

Authentication plumbing stays explicit because it is a real trust boundary.
Do not simplify this teaching app by removing the Entra role/member checks,
CSRF, owner isolation, or fail-closed screening.

## Give the demo

1. Open Chatty from the jump box. Point out the route map is an explanation of
   the code, not fabricated live service telemetry.
   Expand **Prompts to try** for six fictional examples and what to observe.
   Selecting a prompt fills the composer without submitting it. Examples cover
   no identifiers, email, name/phone, mixed identifiers, keeping masks, and no
   matching reference. They do not bypass application screening to test Foundry.
2. Choose **Income + email**, then **Screen & ask**. Expand/collapse the
   **Screened question prepared for both agents** panel. It is open by default so the mask is
   visible. The backend supplied that exact question; the LLM did not reconstruct it.
3. Explain that screened references also cross the model boundary but
   are not exposed in the preview. Each browser submission starts fresh, without
   earlier turns; it replaces the previous result and log even if the request
   fails. The aggregate finding count can include
   repeat findings at different screening stages; it is not a quality score.
4. Choose **No reference match**. The preview explicitly says no agent call
   occurred. Do not present an abstention as successful inference.
5. Under **Compare the evidence**, inspect the two agent responses and expand
   each **Agent log**. One has `ChattyStrict`; the other has `ChattyWithoutPii`.
   A failed or withheld arm opens its log, releases no partial answer, and leaves
   a valid answer in the other arm visible. Shared screening errors prevent both.
   The **Shared screening log** has preparation stages and a trace ID; correlate
   that ID with private App Service logs. Each graphical agent timeline repeats
   the real shared screening events, labeled as run once, then shows that agent's
   checks. All times use the comparison's start. Input annotations refer to
   screened model-bound text; output annotations precede final Language redaction.
   Unreported annotations are not labeled clean. Expand estimated model cost to
   inspect reported tokens, cache/reasoning handling, verified rates, and exclusions.
6. Open [architecture.drawio](architecture.drawio), then the
   [PII handling guide](pii-in-foundry.md). Distinguish the deployed app path from
   proposed OneLake/Purview/Defender integrations.

## Show both PII boundaries

Application PII screening runs before inference and after the buffered answer.
The guarded Foundry deployment additionally has **46 blocking input PII/secret
controls**, plus **45 blocking personal-data/secret completion controls
and detect-only Name Protection** on `ChattyStrict`, alongside the unchanged
original nine safety controls. The name exception reduces unwanted output
blocks; Azure AI Language still masks detected names in the buffered answer.
Input Name Protection remains blocking. Input blocking rejects rather than
redacts, so Language still masks the normal UI question before either call.
The UI labels input and output PII signals separately, when annotations are returned.
The prompt agent
inherits its model policy; its definition has no guardrail override.
The baseline agent inherits `ChattyWithoutPii` from `gpt-5-mini-no-pii`.
Its nine harm/attack controls match the guarded policy; custom PII controls are
absent. Both receive identical screened messages and use identical instructions,
model version, SKU, capacity, and upgrade setting. Both answers still pass
Azure Language screening and citation checks. Two calls cost more than one;
parallel execution waits for both outcomes. Differences in wording are not
proof of filtering, and similar allowed responses are expected for safe prompts.

The original rejection was a naming mistake, not an account-availability block:
policy names are `Name Protection`, not catalog resource IDs like `NameProtection`.
`infra/pii-filter-names.json` is shared by Bicep and the bounded policy updater.

`scripts/Enable-InputPiiGuardrails.ps1` sets the 46 input controls at `Prompt`
with explicit `BLOCKING` using API `2026-09-01`, preserving all existing controls.
`scripts/Test-InputPiiGuardrails.ps1` proved the pinned guarded agent rejected a
synthetic email on input (HTTP 400, prompt-side detected/filtered/blocked),
while the baseline accepted that same input. Clean and masked guarded controls
completed. The private application redaction/comparison smoke also passed.
This test bypasses application preprocessing only for fixed fictional probes;
normal UI requests never bypass it.

`scripts/Test-PiiGuardrails.ps1` invokes the deployed model directly through the
private project endpoint with synthetic data only. It asks for identifiers to be
assembled from pieces so the input filter does not obscure output enforcement.
It checks a clean completion
and identical email-bearing completions on both model deployments, inspects completion-specific PII signals, and
removes its temporary jump-box permission. The email completion was detected and
blocked; the clean control completed. It does not change the prompt agent or
change either deployed policy.
The fictional-name case is detected but not blocked, using the explicit
`ANNOTATING` policy action. Normal app responses still go through Azure Language
redaction before display.

The main-path privacy smoke check separately proves synthetic canary absence in
the actual outbound request. Neither check measures overall PII recall, proves
every configured category, or makes real borrower data appropriate for this POC.

If an arm is blocked, the UI explains that Foundry's safety policy withheld
the answer. The comparison result reports `status: withheld` with
`foundry_output_blocked`; HTTP 200 only means the comparison returned its outcomes.
The legacy chat route still returns HTTP 422 for this block. Logs include only the safe
code, and releases no partial text. Strict categories can flag synthetic or
benign-looking text too; a block is not proof that the input contained real PII.
