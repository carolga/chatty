# Chatty

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Developers learning pre-model PII protection and Foundry defense in depth.
The application is a teaching POC demonstrated through a private jump box.

## Product Purpose

Make the path from an entered question to a screened, referenced answer easy
to understand, inspect, and explain.

## Capabilities and Constraints

- Private ASP.NET Core web application with employee-only Entra sign-in.
- Azure AI Language screens questions, synthetic references, history, and answers.
- Ordinary Foundry prompt agent; no harness, tools, uploads, or streaming.
- The UI displays the backend-supplied screened question, not an LLM reconstruction.
- Synthetic mortgage references only; no real borrower data or lending decisions.
- Detection can miss PII. No claim of guaranteed prevention or production readiness.
- Logs must contain operational metadata, not conversation text or identity claims.

## Product Principles

- Show the actual mechanism, not decorative claims of safety.
- Prefer obvious names and a short, readable execution path.
- Make the agent definition and instructions easy to find.
- Explain the boundaries of each control and distinguish deployed from proposed.
