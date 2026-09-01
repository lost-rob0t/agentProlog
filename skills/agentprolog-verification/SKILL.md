---
name: agentprolog-verification
description: How to build, typecheck, test, and verify agentProlog changes before claiming they work.
---

# Verifying agentProlog

Never claim a change works without running the checks. Everything runs through
the Nix flake; there is no host toolchain.

## Commands

- Enter the toolchain first: `nix develop` (or `direnv allow` once). pnpm and
  swipl exist only inside that shell.
- `pnpm build` — compiles both workspace packages (tsc, NodeNext ESM).
- `pnpm typecheck` — strict tsc over src and tests.
- `pnpm test` — vitest. Unit tests are keyless. Integration tests need
  `AGENTPROLOG_SIDECAR` on PATH, which the dev shell exports; they drive the
  real Prolog sidecar process and stay keyless.
- `nix flake check` — pure Nix checks: pinned prolog-rlm pack load, sidecar
  NDJSON protocol smoke, fail-closed mode validation.

## Rules

- Tests must not need an API key. A live model turn is a manual step, not
  verification evidence.
- A frontend-only change (TUI rendering) does not prove runtime behavior; the
  canonical state lives in the Prolog sidecar.
- If a published `@deepseek-ai` API does not behave as expected, read the
  installed package types in node_modules and adapt; never paper over it.
