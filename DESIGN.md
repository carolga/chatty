# Chatty visual system

## Direction

User-selected route-map story for developers learning pre-model PII protection.
The UI is an operating teaching surface, not a marketing dashboard. A question
moves through five actual control points. The route is architecture, explicitly
not live progress telemetry.

## Visual language

Light working canvas for a screen-shared developer demo. Navy `#142b40` anchors
the route panel; signal yellow `#ffdc52` connects numbered stations and marks
the model boundary. White and slate content areas keep returned text readable.
No external fonts, images, UI libraries, or build step.

Segoe UI/system sans for interface text; Consolas only for source paths and
screened text. Large sentence-case premise, smaller operational labels. Borders
separate regions; numbers communicate the actual sequence rather than decoration.

## Composition

Desktop: premise/composer at left, route map at right. One full-width screened
question precedes two side-by-side agent results: with and without custom Foundry
PII controls. Each owns its response, references, outcome, and expandable log.
Shared preprocessing and its trace ID have one separate log. The source guide
points directly to teaching files. Mobile stacks the two clearly labeled arms.

## Behavior and truth

Examples fill the composer but do not submit. Input and examples are disabled
during requests. Every submission starts a new conversation and clears the old
result and log before sending; no previous conversation ID is reused. The exact
screened-question panel opens by default. Clear results clears the result and
draft. Focus indicators, visible labels, native details, a
skip link, live status, and literal text rendering remain.

The expandable logs show only actual backend events for the latest comparison:
shared preparation timing and independent per-arm elapsed time, outcomes, counts,
and available guarded input/output PII signals. Each agent's graphical timeline
also includes shared question/reference screening, clearly marked as run once.
All branches use the comparison's clock; duration is shown only for paired events.
Clock markers read "At T+mm:ss.mmm"; measured operations read "Duration".
Configuration is outside the timeline and labeled not timed. Foundry safety
reports have receipt timestamps but explicitly unreported execution durations.
Baseline report copy states that custom PII filters are absent.
Missing annotations remain explicitly unreported, not clean. Failures open affected logs. Reset clears them; no
shared log history or payloads are exposed. The static route remains distinct.
The guarded path additionally blocks all 46 input PII categories. On output it
retains detect-only Name Protection and 45 blocking PII controls;
the baseline omits custom PII controls, not baseline safety. Both retain fail-closed
Language screening. Missing annotations are not labeled clean. A blocked arm
never suppresses a valid other arm. Different answer wording alone proves nothing.

Do not show invented stage timing, safety percentages, detector accuracy, or
guardrail success. The Foundry PII note describes the saved policy and bounded
synthetic runtime evidence, not live per-request telemetry or perfect detection.

Per-agent model token usage drives a public-retail USD estimate, with an explicit
comparison total or an unknown/partial total when usage is unavailable. The
expandable breakdown names cache/reasoning handling, rate date, and excluded
screening/guardrail/infrastructure charges. Never imply this is a full Azure bill.
