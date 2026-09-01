---
name: agentprolog-reasoning-modes
description: Choosing between direct, symbolic, and symbolic-recursive execution for agentProlog turns and explaining their budget semantics.
---

# Reasoning modes

The ModeRouter resolves exactly one backend per turn from session state.
Default is `direct`; an explicit command overrides until changed.

- `direct` — bounded non-symbolic conversation. The sidecar grants no `rlm`
  capability and caps recursion depth at 0. Use for short questions, quick
  edits, and anything that does not need structured decomposition.
- `symbolic` — the Prolog-RLM direct-or-plan supervisor. The model may answer
  directly or emit a typed plan that Prolog validates and executes under
  runtime-authoritative capabilities; child plans stay model-only, so
  recursion stays at depth 1. Use when the task benefits from explicit,
  validated steps.
- `symbolic-recursive` — child plans may select symbolic work themselves
  (recursive RLM decomposition). The sidecar raises `max_recursion_depth`
  (default 2) on top of prolog-rlm's own budget ceilings: max_iterations,
  max_model_calls, max_total_tokens, and a wall-clock limit. Use for genuinely
  decomposable long-horizon work; it is the most expensive mode.

Budgets are enforced inside the Prolog runtime and fail closed with a
`budget_exhausted` error code. Cancellation is terminal: a cancelled turn is
never resumed silently.
