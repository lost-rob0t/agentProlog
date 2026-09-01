---
name: agentprolog-sidecar-protocol
description: Debugging or extending the NDJSON sidecar protocol between TypeScript frontends and the Prolog runtime.
---

# Sidecar protocol

One UTF-8 NDJSON frame per line over the sidecar's stdio, protocol version 1.
Requests carry `{version, request_id, session_id, operation, payload}`;
replies carry `{version, request_id, session_id, status: ok|error|cancelled,
payload, error?}` with matching request_id and session_id. Runtime events
omit request_id and carry `{version, session_id, run_id, event, sequence}`
with per-run monotonic sequences.

## Operations

- `runtime.describe` — handshake; capabilities include modes and skills.
- `session.start` — creates the canonical conversation; default mode direct.
- `session.mode` — canonical reasoning-mode transition (`direct`,
  `symbolic`, `symbolic-recursive`); validated against a closed set.
- `session.turn` — one canonical trajectory. Payload: `text` (required),
  `mode` override, `provider` (openrouter only), `model`,
  `max_recursion_depth`, budget fields. Replies with assistant text, provider,
  model, usage, and the resolved mode.
- `session.cancel` — cancels the active turn through the Prolog cancellation
  token; the turn settles as `cancelled`.
- `session.inspect` — mode, busy flag, conversation stats.
- `skill.load` / `skill.list` / `skill.reset` — confined skill catalog
  management; loads merge on top of the runtime default catalog.

## Rules

- Errors are structured: `{code, message}`; budget exhaustion reports
  `budget_exhausted`. Never parse Prolog terms to classify failures.
- The transport fails closed on sidecar exit, malformed JSON, and protocol
  mismatch. Cancellation and crashes are terminal, never retried silently.
