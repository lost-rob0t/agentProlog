---
name: agentprolog-architecture
description: Boundary rules for agentProlog changes — one canonical Prolog runtime, DSH and TUI as frontends, fail-closed errors.
---

# agentProlog boundaries

Dependency direction is strictly `agentProlog -> prolog-rlm`. Never copy
private prolog-rlm internals into TypeScript; consume public APIs
(`rlm_conversation`, `rlm_completion`, `rlm_skill`, `rlm_chain`), or hand a
focused upstream fix to the prolog-rlm repository.

## Structure

- `packages/agentprolog` — the DeepSeek Harness plugin: session-scoped
  ModeRouter, `/direct` `/symbolic` `/symbolic-recursive` commands, mode
  adapters, NDJSON bridge, persistent sidecar transport, AgentFactory.
- `packages/tui` — terminal frontend (`pnpm run dev`). Presentation only; it
  never re-implements turn, mode, or skill semantics.
- `prolog/agentprolog_dsh_sidecar.pl` — the canonical runtime process. One
  DSH user turn maps to exactly one Prolog-RLM trajectory.
- `profiles/agentprolog.patch.yml` — disables the stock agent-loop so exactly
  one AgentFactory is authoritative.

## Failure rules

- Everything fails closed: unknown modes, malformed frames, harness pin
  mismatch, sidecar crash, unsupported providers surface as structured errors.
  There is no silent fallback from symbolic to direct execution.
- Mode state is per session (keyed by session id), never a process-global
  singleton; concurrent sessions must not leak modes into each other.
- Skills load through `rlm_skill`'s confined catalog and grant no execution
  authority.
