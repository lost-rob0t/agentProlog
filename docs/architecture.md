# AgentProlog architecture

AgentProlog is a symbolic coding-agent layer composed into DeepSeek Harness (DSH) as one out-of-tree plugin. DSH owns the harness: sessions, model providers, tools, filesystem/shell capabilities, approvals, cancellation, and durable events. AgentProlog owns reasoning-mode selection and Prolog/RLM orchestration. [prolog-rlm](https://github.com/lost-rob0t/prolog-rlm) owns canonical execution semantics through its public APIs.

## Composition

```text
DSH runtime (dsh-base profile)
   |
   +-- agentProlog plugin (packages/agentprolog)
   |       |
   |       +-- ModeRouter          one authoritative backend decision per turn
   |       +-- mode commands       /direct  /symbolic  /symbolic-recursive
   |       +-- adapters            mode -> canonical sidecar request shaping
   |       +-- PrologAgentFactory  the single DSH AgentFactory
   |       +-- SidecarTransport    persistent NDJSON/stdio bridge
   |
   +-- Prolog sidecar (prolog/agentprolog_dsh_sidecar.pl)
           |
           +-- public prolog-rlm APIs (rlm_conversation, rlm_completion, rlm_chain)
```

## Module map

| Module | Responsibility |
| --- | --- |
| `src/modes.ts` | The closed mode set (`direct`, `symbolic`, `symbolic-recursive`) and validation. |
| `src/router.ts` | Session-scoped mode state and the single `executeTurn` dispatch point. |
| `src/commands.ts` | The three slash commands as DSH `CommandDefinition`s; handlers perform router transitions and return `Mode: <mode>` results. |
| `src/adapters.ts` | Typed boundary to the sidecar: canonical turn payloads per mode, structured failure classification, recursion-ceiling forwarding. |
| `src/bridge.ts` | Request/response correlation, cancelled/error rejection, monotonic runtime events. |
| `src/sidecar.ts` | Process lifecycle for the persistent Prolog sidecar; fail-closed on exit, malformed output, and protocol mismatch. |
| `src/agent-factory.ts` | DSH `Agent`/`AgentFactory` backed by the sidecar; one DSH user turn maps to one canonical Prolog-RLM trajectory. |
| `src/plugin.ts` | Cordis `apply()`: compatibility pin check, sidecar startup, factory registration, command registration, service provisioning, cleanup. |
| `src/protocol.ts` | NDJSON frame vocabulary and validation shared with the sidecar. |

## Turn flow

```text
user turn (DSH)
   -> PrologBackedAgent.runTurn
   -> ModeRouter.executeTurn            (mode resolved from session state)
   -> adapter shapes session.turn       (mode + text + explicit ceilings)
   -> sidecar dispatches by mode:
        direct                -> capabilities without rlm, recursion depth 0
        symbolic              -> runtime default direct-or-plan supervisor
        symbolic-recursive    -> child symbolic capabilities + explicit depth budget
   -> rlm_conversation_runtime:conversation_turn (canonical trajectory)
   -> structured reply (ok | error | cancelled) or runtime events
   -> DSH session events (assistant/message, turn/end)
```

## Termination controls

Recursion and iteration ceilings are owned by Prolog-RLM's budget system and enforced inside the runtime; the sidecar forwards explicit ceilings (`max_recursion_depth`, `max_iterations`, and friends) from the plugin payload and rejects non-conforming values before any provider call. Direct mode makes symbolic recursion structurally impossible (no `rlm` capability, depth 0). Cancellation flows DSH `agent.cancel()` -> `session.cancel` -> the Prolog cancellation token, and settles the turn as aborted — it never leaves a zombie trajectory.

## Failure semantics

Everything fails closed: unknown modes, malformed frames, harness pin mismatch, sidecar crash, protocol mismatch, and unsupported providers surface as structured errors with codes. There is no silent fallback from symbolic modes to direct execution.

## Scoping and observability

The router instance is owned by the plugin; state is keyed by DSH session id and dropped on agent disposal. Observability is emitted as Cordis events (`agentprolog/mode/change`, `agentprolog/turn/settled`, `agentprolog/runtime/event`) and structured log lines carrying `mode`, `session`, `backend`, `duration`, and `cancelled` — never prompts or secrets.
