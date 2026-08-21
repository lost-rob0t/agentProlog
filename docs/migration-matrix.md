# AgentProlog migration matrix

This matrix is deliberately ownership-first. The nested `prolog-rlm/agentProlog/` tree remains intact until explicit user authorization permits removal.

| Concern | Existing nested harness / upstream surface | Standalone target | Migration action |
|---|---|---|---|
| runtime ownership | `prolog-rlm` public `library(rlm)` facade | pinned flake/SWI dependency | REUSE VIA PROLOG-RLM API |
| provider/model execution | generic provider/completion runtime in `prolog-rlm` | product selects/routes through public runtime | REUSE VIA PROLOG-RLM API |
| async/Futures | generic runtime concern | no downstream scheduler | KEEP CORE |
| authority | generic authority mediation | product projects requests only | KEEP CORE |
| effects | generic durable-effect semantics | coding tools cross upstream effect boundary | KEEP CORE |
| Spec/Plan/Verify | generic workflow primitives | one headless coding workflow composes them | REUSE VIA PROLOG-RLM API |
| project/source KB | reusable project/source knowledge | coding workflow consumes public APIs | REUSE VIA PROLOG-RLM API |
| coding tools | nested product tools + external tool-loader seam | downstream filesystem/Git/process/test packs | MIGRATE / REIMPLEMENT DOWNSTREAM |
| frontend protocol | `prolog_agent_ui_v1`, NDJSON fixtures, replay/correlation semantics | renderer-independent product client contract | REUSE VIA PROLOG-RLM API; migrate only product adapter |
| UI/TUI | nested/reference client work | Bubble Tea default frontend plugin | MIGRATE / REIMPLEMENT DOWNSTREAM |
| configuration | upstream trusted runtime config is not package loading | downstream product defaults + upstream config APIs | SPLIT: KEEP CORE semantics, product UX downstream |
| persistence | generic runtime/session concern | client renders/reconnects; does not own truth | KEEP CORE |
| MCP | generic runtime concern | product configuration/UX only | KEEP CORE |
| traces/usage/subagents | generic structured runtime events | frontend/headless projections | REUSE VIA PROLOG-RLM API |
| tests/fixtures | upstream deterministic runtime/protocol fixtures | downstream conformance against public contract | REUSE + ADD DOWNSTREAM CONFORMANCE |
| packaging | upstream SWI pack; flake output required by #141 | standalone flake consumes pinned upstream package | BLOCKED ON #141 FLAKE OUTPUT |

## Current blocking contract

Standalone packaging intentionally expects `prolog-rlm.packages.${system}.default`. Current upstream `main` has `pack.pl` but no `flake.nix`, so this branch is expected to fail until #141 lands a first-class package output. Do not copy the upstream source tree or smuggle it through a tool plugin to make the build green.

## Next downstream slices after upstream packaging lands

1. lock the flake input and prove `nix flake check`, `nix build`, and `nix run` from a clean checkout;
2. replace the readiness stub with the first headless Spec/Plan/Execute/Verify product entrypoint over public runtime APIs;
3. migrate/adapt renderer-side `prolog_agent_ui_v1` fixtures without moving authority/execution into the frontend;
4. add confined coding tool packs through `rlm_tool_loader` after auditing its current safety contract;
5. implement the Bubble Tea renderer as a client of the same headless workflow.
