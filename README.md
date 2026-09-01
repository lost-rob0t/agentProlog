# AgentProlog

**Prolog-RLM coding-agent layer as a DeepSeek Harness plugin.**

AgentProlog makes [Prolog-RLM](https://github.com/lost-rob0t/prolog-rlm) the canonical symbolic reasoning runtime behind the [DeepSeek Harness (DSH)](https://github.com/deepseek-ai/deepseek-harness) agent harness. DSH keeps owning sessions, model providers, tools, approvals, cancellation, and durable events; AgentProlog owns reasoning-mode selection and symbolic orchestration through one authoritative mode router.

```text
            optional DSH TUI (see docs/adr/0001-dsh-tui-selection.md)
                             |
                             v
                +------------------------+
                |   DeepSeek Harness     |   sessions, tools, approvals,
                |   (dsh --profile ...)  |   model providers, events
                +------------------------+
                             |
                agentProlog DSH plugin
                packages/agentprolog
                             |
                       mode router
                     /     |      \
                direct  symbolic  symbolic-recursive
                    \       |       /
                     Prolog sidecar (NDJSON/stdio)
                             |
                     public prolog-rlm APIs
```

## Reasoning modes

One session-scoped router resolves exactly one backend per turn. Mode transitions are canonical state changes performed by real DSH commands — the model never interprets them.

| Command | Mode | Execution |
| --- | --- | --- |
| `/direct` | `direct` | Bounded non-symbolic turn through the canonical Prolog-RLM conversation boundary. No symbolic planning, no recursion: the sidecar grants no `rlm` capability and caps recursion depth at 0. |
| `/symbolic` | `symbolic` | The Prolog-RLM direct-or-plan supervisor: typed symbolic plans, one recursion level (runtime defaults). |
| `/symbolic-recursive` | `symbolic-recursive` | Bounded recursive RLM decomposition: child plans may select symbolic work, with an explicit `max_recursion_depth` budget on top of Prolog-RLM's own iteration/budget ceilings. |

The default mode is `direct`. Modes are validated against a closed set; unknown modes are rejected, never coerced. Symbolic failures propagate as structured, fail-closed errors — there is **no** silent fallback to direct mode.

## Installation and development

Everything runs through the Nix flake — Node, pnpm, SWI-Prolog, and the pinned prolog-rlm pack closure:

```sh
direnv allow                      # or: nix develop
pnpm install
pnpm build && pnpm test
```

The sidecar binary is flake-provided (`nix build .#agentprolog-sidecar`); the dev shell exposes it as `agentprolog-sidecar` on `PATH` with `SWIPL_PACK_PATH` pointed at the pinned prolog-rlm pack.

### Composing into a DSH profile

```sh
dsh plugin --profile agentprolog add <path-or-package-of-packages/agentprolog>
export AGENTPROLOG_DSH_PLUGIN=<plugin package path>
export AGENTPROLOG_SIDECAR=$(nix build .#agentprolog-sidecar --print-out-paths)/bin/agentprolog-sidecar
dsh --profile agentprolog --patch profiles/agentprolog.patch.yml
```

The profile patch disables only the stock `agent-loop` row (exactly one `AgentFactory` remains authoritative) and mounts the AgentProlog plugin with the pinned harness identity. DSH provider/model selection stays in DSH settings; the sidecar's model is configurable through plugin `defaults.model`.

## Headless operation and testing

The plugin has no TUI dependency. Headless coverage:

- `pnpm test` — the full unit suite (router isolation, mode commands, adapter payload shaping, bridge correlation, fail-closed transport).
- `packages/agentprolog/test/headless.integration.test.ts` — drives the real Prolog sidecar process (set `AGENTPROLOG_SIDECAR`; the dev shell sets it for you) through describe/start/mode/inspect/cancel paths without any API key.
- `nix flake check` — pure checks: pinned prolog-rlm pack load, sidecar protocol smoke, and mode-validation fail-closed behavior.

A live model turn additionally needs an OpenRouter-compatible key in the environment (see `.env.example`); everything else — composition, command dispatch, mode transitions, approvals rendering — works keyless.

## How mode state is scoped

`ModeRouter` is owned by the plugin instance (one per composed profile) and keys mode state by DSH session id. Concurrent sessions cannot observe or leak each other's modes; disposing an agent forgets its state. There is no process-global singleton. Mode changes and turn settlements are emitted as `agentprolog/mode/change` and `agentprolog/turn/settled` events plus structured log lines (`mode`, `session`, `backend`, `duration`, `cancelled`) — never prompts or secrets.

## Known limitations

- Session resume, steer/inject, and maintenance operations are not implemented yet and fail closed.
- The canonical sidecar runtime currently speaks to an OpenRouter-compatible provider (`defaults.model` selects the model); DSH-side provider selection applies to DSH surfaces.
- DSH compatibility is pinned fail-closed to `0.1.1-rc.2` (see `packages/agentprolog/src/compatibility.ts`); bump both sides together with the flake's prolog-rlm pin.
- No TUI ships in this repository; the recommendation and integration plan live in [docs/adr/0001-dsh-tui-selection.md](docs/adr/0001-dsh-tui-selection.md).

## Repository layout

```text
packages/agentprolog/    the DSH plugin (TypeScript): router, commands, adapters, bridge, transport
prolog/                  the persistent Prolog sidecar (public prolog-rlm APIs only)
profiles/                official DSH profile overlay (disables stock agent-loop, mounts the plugin)
flake.nix                toolchain, sidecar package, keyless checks
docs/adr/                decision records (TUI selection)
```
