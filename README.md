# AgentProlog

AgentProlog is the standalone coding-agent product built on [`lost-rob0t/prolog-rlm`](https://github.com/lost-rob0t/prolog-rlm).

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
