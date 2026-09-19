# AgentProlog Workbench client

Shared protocol/state client for AgentProlog Workbench frontends.

It consumes the canonical `prolog_agent_ui_v1` snapshot/event/command boundary from `prolog-rlm`.
It deliberately does **not** execute tools, own authority, implement agent scheduling, or infer canonical state from logs.

## Guarantees

- protocol identifier is validated;
- snapshots replace the local projection at their authoritative cursor;
- duplicate/overlapping replay events are ignored;
- forward sequence gaps fail closed;
- session identity changes fail closed;
- optional extension events are retained generically;
- required unknown extensions fail closed;
- unknown tools remain normal data and renderers may present them generically.

## Test

```bash
node --test packages/workbench-client/test/*.test.js
```

To additionally test against the upstream polyglot golden fixture:

```bash
PROLOG_RLM_SOURCE=/path/to/prolog-rlm \
  node --test packages/workbench-client/test/*.test.js
```

The repository Nix check supplies the pinned `prolog-rlm` source automatically.
