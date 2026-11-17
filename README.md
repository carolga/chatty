# Chatty

A C#/ASP.NET Core teaching POC for pre-model PII screening. Azure AI Language screens
input, retrieved context, replayed history, and output. Only screened text is sent
to two version-pinned Microsoft Foundry prompt agents for a controlled comparison.

**Public sample:** private deployment state, credentials, tenant identifiers, and
operational artifacts are excluded. Resource names containing `demo0001` and
`00000000-0000-0000-0000-00000000000N` identifiers are examples, not live resources.
Deployment scripts require configuration for your own approved Azure environment.
Runtime observations below describe the original POC, not a deployment created by
cloning this repository. Use synthetic data only.

## Start here: the teaching POC

**The actual agent prompt is
[`src/Chatty.Web/Agent/instructions.md`](src/Chatty.Web/Agent/instructions.md).**
Its adjacent `definition.json` and `baseline-definition.json` name the guarded
and baseline agents and their separate model deployments. **Both use that one
shared instructions file.** The
publisher reads these files; the instructions are no longer buried in a
deployment script. `FoundryPromptAgent.cs` is the explicit Responses API adapter.

- [Ten-minute teaching/code walkthrough](docs/teaching-walkthrough.md)
- [PII in Foundry: control boundaries, Defender, Purview, and OneLake](docs/pii-in-foundry.md)
- [Editable draw.io architecture: software, Azure, and PII governance](docs/architecture.drawio)

The route-map UI shows one exact screened question above two separate answers
and per-agent logs. **Prompts to try** expands six fictional test prompts with observation
notes; selecting one fills the composer without submitting it.
Every **Screen & ask** submission starts a fresh conversation (`conversationId:
null`) through `/api/compare` and replaces the previous question, answers, and logs, including
when the new request fails. **Clear results** clears the current result and draft.
The browser does not replay earlier turns; the API's owner-bound history support
remains available to authorized `/api/chat` callers. Comparisons neither store
nor replay conversation history.
Application/container logging is enabled with content-free stage,
count, duration, trace-ID, and safe-error events. No prompts or responses are
logged; no subscription-wide Defender/Purview data-sharing feature was enabled.
The expandable **Shared screening log** contains the latest request's common
preparation stages and trace ID. Each **Agent log** independently reports
shared input preparation, invocation, Foundry input/output decisions, final
redaction, and citation checks. All times start at comparison request logging.
No shared raw-log viewer is exposed.

## What the comparison changes

| Path | Agent / model deployment | Foundry policy |
| --- | --- | --- |
| With custom PII controls | `chatty` / `gpt-5-mini` | `ChattyStrict`: 46 input PII/secret blocks; 45 output blocks and output Name Protection detect-only; nine original harm/attack controls |
| Without custom PII controls | `chatty-no-pii` / `gpt-5-mini-no-pii` | `ChattyWithoutPii`: the same nine harm/attack controls, no custom PII controls |

Both deployments use the same model version, SKU, capacity, and upgrade setting.
Input and references are screened **once**, then the identical screened values
are sent to both pinned agents concurrently. Both retain Language output
redaction, citation checks, employee access, private networking, and platform
safety. **This is not a raw/unfiltered bypass.** A withheld or failed arm releases
no answer and does not hide the other arm. Shared preprocessing failure prevents
both calls; no references skips both calls.

One UI request can make **two billable model calls**, not one; parallel execution
does not halve cost and the UI waits for both outcomes. Safe answers may look
similar, and generation is nondeterministic: different wording is not evidence
of a guardrail intervention. The baseline intentionally does not display a
misleading "PII detected: no" when custom PII detection is unconfigured.
The guarded arm labels Foundry **input** and **output** checks separately.
Input annotations concern text already screened by the app; output annotations
concern generated text before final Language redaction.

Each agent's **screening timeline** includes the real shared question/reference
screening events (marked as run once), its own Foundry input/output annotations,
application answer screening, and citation validation. All timestamps share the
comparison's clock. Paired start/finish events provide measured stage durations;
checks without returned annotations are labeled **Not reported**, never "clean."
Foundry annotations are recorded when the response arrives, not streamed live.
Clock positions are explicitly labeled **At T+mm:ss.mmm** in both shared and
per-agent logs; only measured start/finish pairs show **Duration**.
Foundry safety reports say **Duration: not reported** because the service does
not provide separate filter execution times. Model invocation duration includes
the Foundry round trip; do not add report timestamps to it. Configuration is
displayed separately as **not timed**, not as a processing step. Baseline reports
explicitly distinguish ordinary safety checks from absent custom PII filters.

**Estimated model cost** is shown per agent and summed only when both agents
return usable token counts. `ModelCostEstimate.cs` applies public West US 3
GPT-5 mini DataZoneStandard USD retail rates checked November 17, 2026:
$0.275 input, $0.0275 cached input, and $2.20 output per million tokens.
Reported output tokens already include reasoning; they are not added twice.
Missing cache details use the uncached input rate and are labeled explicitly.
Missing usage means **unknown cost**, not free; no model invocation means zero
model tokens. This estimate excludes Language screening, guardrail, hosting,
network, discounts, taxes, and other Azure charges. It is not a bill.
The rates are sample-specific: update them if the deployed model or SKU changes.
Source: [Azure Retail Prices API](https://prices.azure.com/api/retail/prices),
service `Foundry Models`, product `Azure OpenAI GPT5`, region `westus3`,
meters `GPT 5 Mini Inpt DZone 1M Tokens`, `GPT 5 Mini cchd Inpt DZone 1M Tokens`,
and `GPT 5 Mini outpt DZone 1M Tokens`.

**Foundry input PII blocking is also enabled and runtime-verified.** All 46
PII/secret categories use `source: Prompt`, `action: BLOCKING` on `ChattyStrict`
through policy API `2026-09-01`. The pinned `chatty:1` rejected a synthetic
email-bearing input with HTTP 400 and prompt-side PII detection/filtering.
Clean and masked equivalents completed; `chatty-no-pii:1` accepted the same
email-bearing input. This blocks rather than redacts. Normal UI requests still
go through Language first, so an input block is not expected just because the
original question contained an email. The timeline distinguishes input annotations
from output annotations. The baseline and application protections are unchanged.
`scripts/Enable-InputPiiGuardrails.ps1` preserves existing controls and checks
readback; `scripts/Test-InputPiiGuardrails.ps1` verifies actual enforcement and
the application redaction/comparison smoke over the private endpoint.

**Foundry PII output controls are enabled.** Of 46 personal-data/secret completion
controls on `ChattyStrict`, 45 block and **Name Protection is detect-only** to
reduce unwanted blocks on ordinary answers. The original nine safety controls
are unchanged. A private runtime check confirmed a synthetic email completion was
detected and blocked, while a clean control passed. This is representative
enforcement evidence, not a detection-quality benchmark. Application pre-model
and post-model Language screening remains unchanged.

The original API rejection came from using catalog resource IDs such as
`NameProtection` instead of policy names such as `Name Protection`. The corrected
names are shared by Bicep and `scripts/Enable-PiiGuardrails.ps1`.
`scripts/Test-PiiGuardrails.ps1` separately checks actual output enforcement from
the private jump box without changing the agent or weakening the active policy.
Guardrail-blocked answers are withheld with a clear UI message and safe
`foundry_output_blocked` code, rather than displayed as partial responses.
`/api/compare` returns HTTP 200 with explicit per-arm `withheld`/`failed` outcomes;
transport success does not mean either answer succeeded. The legacy `/api/chat`
route retains HTTP 422 for a Foundry block.
Strict filters can also block synthetic or benign-looking text.

## Boundaries

- Microsoft Entra single-tenant sign-in, `Chatty.User` application role, and
  `acct=0` member claim are all required. Guests, missing claims, and unassigned
  users are denied. No development authentication bypass is shipped.
- PII screening failures stop processing. No regex-only or unscreened fallback.
  Detection is imperfect; do not enter real borrower data into this POC.
- Azure AI Language sees raw text to redact it; the browser and trusted backend
  briefly hold it too. The privacy goal concerns the generative model.
- Server-side, user-bound history contains only sanitized messages; it expires
  after 20 minutes and is limited to six answered turns. In-memory sessions are
  single-instance only and are lost on restart. A busy conversation returns 409.
- Raw content, token values, and identity claims are not deliberately logged.
  Service-side retention/abuse monitoring and hosting diagnostics need a separate
  deployment review; `store=false` is not a blanket zero-retention guarantee.
- Responses are buffered, screened, and checked for recognized citation markers.
  Citation checks are structural, not proof of factual grounding.
- No agent tools, user uploads, embedding calls, or live browsing. Ordinary
  application users receive no direct Foundry permissions. Existing Azure
  administrators retain their independent administrative access; this application
  does not prevent an administrator from bypassing it.

## Inspect redaction in the UI

After a response, expand **Screened question prepared for both agents**.
It displays the exact screened current question prepared for both Foundry calls,
with Azure AI Language's masks preserved, plus the input-only finding count.
This is backend-supplied text, not the model describing what it received.
Screened references are also supplied but are not exposed in this panel.
No previous turns are included in a comparison. Shared and per-agent counts
can include repeated findings across screening stages; they are not counts of
distinct people or a detection-quality score.

Try a fictional input such as:
`Explain synthetic income documentation. My email is redaction-demo@example.com.`
Use synthetic data only: detection can miss PII, and zero findings does not prove
there is none. For questions with no matching references, the panel explicitly
says **neither agent invoked**. Shared screening errors do not echo the question.

The preview is returned only to the authorized requester with `no-store`.
It does not expose tokens, server logs, a separate list of original entity
values, or other users' history.
It is rendered as literal text in the current page, is cleared by **Clear
results** or the next submission, and is not written to browser storage. Legacy server-side
conversation history still contains only screened messages under the existing
retention/ownership rules.

## Knowledge

`src\Chatty.Web\Knowledge\synthetic.json` contains three original, clearly labeled
test references about income documentation, escrow servicing, and borrower
assistance. They are **not Fannie Mae or Freddie Mac requirements** and must not
be used for actual loan or credit decisions.

The backend performs bounded keyword retrieval and re-screens every result.
Questions without matching passages receive an insufficient-evidence response
without a model call. Try: `Explain the synthetic income documentation review.`

`knowledge\sources.json` records official Fannie Mae/Freddie Mac candidate sources.
No full guides have been downloaded or indexed. Content-use authorization and a
reviewed ingestion pipeline are required before enabling those sources. The app
does not automatically ingest local files or the source inventory.

## Build

Prerequisite: .NET 10 SDK.

```powershell
dotnet restore Chatty.sln --configfile NuGet.config
dotnet test Chatty.sln --no-restore
dotnet publish src\Chatty.Web -c Release -o artifacts\web
```

Dependencies are pinned with lock files. `NuGet.config` uses Microsoft's
`dotnet-public` package mirror because nuget.org TLS negotiation failed in this
development environment. For repeatable CI restores, use `--locked-mode`.
Tests use test-project-only authentication and service doubles; no Azure account
or PII service is required. They are not a benchmark of actual PII detection.

## Entra setup required before sign-in

An authorized administrator must create/configure a single-tenant confidential web
application in the selected deployment tenant:

1. Register the HTTPS redirect URI `https://<chatty-host>/signin-oidc`. For local
   development, also register `https://localhost:7083/signin-oidc`.
2. Add the ID-token optional claim `acct`. The backend requires value `0`;
   omission fails closed. Configure group/application assignments to exclude
   guests; the claim check is additional protection.
3. Define an enabled user app role with value `Chatty.User`. Require assignment
   on the enterprise application, and assign that role to the approved employee
   group or explicitly approved initial users.
4. Configure confidential-client authentication. For Azure, use a federated
   identity credential trusting the App Service managed identity and
   `AzureAd:ClientCredentials:0:SourceType=SignedAssertionFromManagedIdentity`.
   The deployed app must not need a client secret. Development may instead use
   user-secrets with an approved credential. Never commit secrets.
5. Apply organizational MFA/Conditional Access policies. Do not weaken existing
   tenant policies for the POC.

No Microsoft Graph access or on-behalf-of token flow is required for chat. The
application uses its own managed identity for Language and Foundry.

The employee session cookie has a fixed 20-minute lifetime (no sliding renewal).
An invalid or expired session stops API requests with HTTP 401,
`sign_in_required`, and a trace ID before screening or inference. The UI shows
**Sign in again**, disables further submissions, and does not automatically
redirect, retry, or persist the draft. Reopen Chatty on the jump box to sign in;
the timeout and authorization requirements are not relaxed. HTTP 403 instead
means the authenticated account does not satisfy access policy.

If sign-in succeeds but access is denied, the authenticated-only
`/MicrosoftIdentity/Account/AccessDenied` endpoint returns HTTP 403 with short
`reasons` codes, not a missing-page 404. These checks use the same policy as chat
and disclose no token, cookie, identity, or claim values. For example,
`missing_member_claim` means the current session lacks the required `acct`
claim; `missing_chatty_role` means that session does not satisfy `Chatty.User`.
Confirm the registration and assignment, then use a fresh InPrivate sign-in
before changing permissions. A directory assignment alone does not establish
which claims an existing browser session contains.

Claim mapping must be disabled in both the named `MicrosoftIdentityOptions`
and `OpenIdConnectOptions`. Configuring only the latter left the actual
Microsoft.Identity.Web token handler renaming `tid`, `oid`, and `roles`, causing
valid members to fail the tenant, user-ID, and role checks. The sign-in-handler
regression exercises a locally signed synthetic token. The `__Host-Chatty-v2`
cookie forces fresh sign-in instead of reusing tickets with the old claim names;
it does not relax any tenant, membership, or app-role requirement.

## Application configuration

Use environment variables or .NET configuration. Empty/invalid endpoints,
tenant/client IDs, or agent versions prevent startup.

| Setting | Value |
| --- | --- |
| `AzureAd__TenantId` | Single deployment tenant GUID |
| `AzureAd__ClientId` | Entra web app registration client GUID |
| `AzureAd__ClientCredentials__0__SourceType` | `SignedAssertionFromManagedIdentity` for secretless Azure sign-in; configure the matching Entra federated credential |
| `Chatty__LanguageEndpoint` | `https://<language-resource>.cognitiveservices.azure.com/` |
| `Chatty__ProjectEndpoint` | `https://<foundry-resource>.services.ai.azure.com/api/projects/<project>` |
| `Chatty__AgentName` | Deployed prompt agent name, default `chatty` |
| `Chatty__AgentVersion` | Positive, explicitly approved version number; never `latest` |
| `Chatty__BaselineAgentName` | Separate baseline prompt agent, default `chatty-no-pii` |
| `Chatty__BaselineAgentVersion` | Positive pinned baseline version; required at startup, never `latest` |
| `Chatty__ManagedIdentityClientId` | Optional user-assigned managed identity client GUID |
| `Chatty__TrustedProxyNetwork` | Explicitly trusted reverse-proxy CIDR; this App Service deployment uses `169.254.0.0/16`. Only the original scheme is forwarded, with a one-proxy limit; forwarded hosts and client addresses are not trusted |
| `AllowedHosts` | Exact application hostname(s), separated with semicolons |

For local development, sign in with Azure CLI to the approved tenant; the
Development environment uses `AzureCliCredential`. All other environments use
managed identity only. Network connectivity to the private endpoints is still
required, for example by developing/running from the Bastion-accessible jump box.

The content root is pinned to the application's binary directory. The complete
`wwwroot` output must include nonempty `index.html`, `app.js`, and `app.css`;
startup fails explicitly otherwise. Synthetic knowledge is also loaded and
validated before serving requests. The private `/health/ready` endpoint reports
the application DLL and UI SHA-256 hashes, never user data or tokens. The publisher
requires those live hashes to match the package before reporting success, avoiding
acceptance of an older process with unchanged UI files. UI files themselves still
require the Employee policy. `/health/live` alone is not deployment acceptance.

```powershell
dotnet dev-certs https --trust
dotnet run --project src\Chatty.Web --launch-profile https
```

Use a secret store for the required configuration first. Do not replace missing
identity/service settings with fake values outside the automated tests.

## Private deployment setup

The sample infrastructure creates private endpoints for Foundry, Language, and
App Service, plus a Windows jump box accessed through Azure Bastion. The VM has
no public IP. NAT provides outbound connectivity, not an egress firewall.
Review the template, service availability, regional model quota, and ongoing
costs before provisioning. Private networking does not make this a
production-ready or compliance-certified solution.

The scripts are **deployment examples**, not a one-click installer. Before use,
configure a local deployment copy with your approved environment:

| Example | Replace with |
| --- | --- |
| `00000000-0000-0000-0000-000000000001` | Your Azure subscription ID |
| `00000000-0000-0000-0000-000000000002` | Your Entra tenant ID |
| `00000000-0000-0000-0000-000000000005` | Your jump VM's managed-identity principal ID, after provisioning |
| `demo0001` | Your globally unique resource-name suffix, consistently across infrastructure and scripts |
| `rg-chatty-westus3-demo` | Your new resource group |

Keep deployment-specific values and generated files out of public commits.
Do not run the scripts against existing resources without reviewing their
scope checks. The sample targets West US 3 and GPT-5 mini DataZoneStandard;
changing region/model requires reviewing the checks and cost-estimate rates too.
The original POC's `securitycontrol`/`costcontrol` tags are organization-specific
metadata, not security controls. Review or remove them according to your
organization's governance policy rather than copying exemptions blindly.

Use PowerShell 7 on Windows, Azure CLI with Bicep installed, and an authorized
member identity in the deployment tenant. These scripts use the Windows Azure
CLI Python installation. The deployment identity needs resource provisioning,
role-assignment authority, and appropriate Entra application permissions.
No subscription, tenant policy, MFA coverage, or quota approval is implied by
this public repository.

1. Review `infra/main.bicep`, then run `scripts/Deploy-Infrastructure.ps1` with
   explicit `-SubscriptionId` and `-TenantId`. It compiles Bicep, validates ARM,
   requires a successful non-destructive what-if, and refuses automatic recovery
   of a nonempty resource group. Inspect provisioning completion before proceeding.
2. Run `scripts/Configure-Entra.ps1` with `-WebPrincipalId` set to the App Service
   managed identity. It creates a single-tenant registration with required
   assignment and secretless managed-identity federation. The local record is
   written under ignored `artifacts/`.
3. Use `scripts/Publish-Chatty.ps1` after reviewing the example environment values.
   It transfers source through VM Run Command, builds on the private jump box,
   verifies the shared agent prompt and pinned versions, and publishes through
   private SCM. Temporary deployment grants are removed in `finally`.
4. Open the private application from the jump box through Bastion. Complete
   employee sign-in and send a fictional question. Verify your own authorization,
   redaction, policy enforcement, readiness hashes, and temporary-grant cleanup.

`Enable-PiiGuardrails.ps1`, `Enable-InputPiiGuardrails.ps1`, and
`Enable-AgentComparison.ps1` are bounded policy-update examples for an existing,
reviewed Chatty deployment. The `Test-*PiiGuardrails.ps1` scripts use fixed
synthetic probes; direct Foundry probes bypass application preprocessing only
to test Foundry itself. They are not a detection-quality benchmark.

Evaluation-generation scripts are optional, require the relevant `azd ai`
commands, and can incur model charges. Submitted dataset/evaluator jobs are not
completed evaluation runs. No evaluation state or generated dataset is shipped.

## Infrastructure attribution

The upstream infrastructure is pinned to Microsoft Foundry samples commit
`8ed496738e26d91cde993d7fa6b6804590b55a2e`. The account module is adapted for
Chatty's authentication and PII comparison policies. Original license notices
are retained; see [third-party notices](THIRD_PARTY_NOTICES.md).
