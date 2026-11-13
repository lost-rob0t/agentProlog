# AgentProlog

AgentProlog is the reusable generic agent application built on [`lost-rob0t/prolog-rlm`](https://github.com/lost-rob0t/prolog-rlm).

The repository owns product composition and UX. `prolog-rlm` remains the reusable SWI-Prolog runtime/library.

```text
AgentProlog
  -> DeepSeek Harness / Cordis integration
  -> AgentFactory / frontend adapters
  -> product configuration and defaults
  -> coding workflow + coding tool packs
  -> public prolog-rlm APIs
  -> Prolog-RLM runtime
```

Dependency direction is strictly:

```text
agentProlog -> prolog-rlm
```

## Current state

The standalone packaging and persistent DSH/Prolog bridge substrate are on `main`.

Current DSH work is tracked in:

- issue #7 — plugin-only DeepSeek Harness AgentFactory;
- PR #8 — active executable AgentFactory slice.

The current integration uses the official DeepSeek Harness/Cordis surface as the workspace and presentation layer while keeping Prolog-RLM authoritative for provider/model calls, context compilation, tools, capabilities, authority, effects, conversations, agents/subagents, Spec/Plan/Verify, tracing, and usage.

The old nested `prolog-rlm/agentProlog/` product harness has been removed upstream. Generic `prolog_agent_ui_v1` protocol/facade behavior remains reusable runtime infrastructure in `prolog-rlm`.

## Repository responsibilities

AgentProlog owns:

- DeepSeek Harness / Cordis integration;
- AgentFactory and frontend/session adapters;
- product configuration and defaults;
- headless coding workflow composition;
- filesystem, Git, process, and test tool packs;
- DSH/TUI/editor UX;
- product-specific skill refinery and evolutionary-agent integrations.

Generic runtime changes belong upstream in `prolog-rlm` rather than being duplicated here.

## Optional Zara runtime profile

AgentProlog can be exposed to Zara as a **profile of the Prolog-RLM runtime**.
It is not a second runtime implementation and it does not make Zara depend on
AgentProlog.

```text
Zara -> ZARA-RUNTIME/1 -> Prolog-RLM
                         ^
                         |
                  profile: agentprolog
```

The Nix output `agentProlog-zara-runtime` starts the upstream
`prolog-rlm-zara` sidecar with `--profile agentprolog`:

```bash
nix run .#zara-runtime -- --port 18765
```

Zara discovers the runtime as `prolog-rlm` and may render `agentprolog` in
the descriptor's profile list. Provider/model calls, planning, recursive
execution, budgets, cancellation and trace semantics remain owned by
Prolog-RLM. Zara remains the host for chat/project context, plugins, approvals
and platform integration.

This profile is optional. Normal AgentProlog usage and normal Zara usage do not
require it.

Cross-repo authority: `lost-rob0t/zara#1046`; upstream bridge:
`lost-rob0t/prolog-rlm#448`.

## Development

```bash
nix develop
nix flake check
```

The repository consumes `prolog-rlm` through its Nix flake dependency.

## Architecture authority

- AgentProlog product epic: issue #1
- DSH AgentFactory implementation: issue #7 / PR #8
- upstream repository boundary: `lost-rob0t/prolog-rlm#141`

## Generic native agent and terminal application

```sh
nix run . -- --project /absolute/project --state /absolute/private/session-state
```

The default application opens an interactive canonical session. Type a task;
inspect tools, usage and artifacts; answer questions; decide approvals; cancel or
reconnect. Prolog-RLM owns execution. Trusted plugins and explicit project-local
Prolog configuration provide tools/profiles; downstream harnesses own their
business logic. See [application and validation status](docs/canonical-conversation-ui.md)
and [Prolog configuration](docs/prolog-configuration.md).

This draft is not production-ready: hosted dependency access, complete native
mutation-approval continuation and final real-model acceptance remain gates.
