# Managed-turn cleanup verification

Upstream pin: `d4e639e93f7598f2ba4735daac1cd4ad62355a8b` (draft prolog-rlm #519).
The NAR hash was calculated from its clean git archive with Nix 2.26.3.
The same procedure reproduced the previous lock's hash exactly. Nix fetched
and evaluated the new locked source without a hash mismatch.

Local verification on 2026-10-18 used Node 24.19.0, the project's pnpm 10.28.0,
and SWI-Prolog 9.2.9 installed into an isolated workspace toolchain.

- Build and strict typecheck passed.
- Plugin: 73 tests passed, including real sidecar process integration.
- TUI: 22 tests passed, including real sidecar integration.
- Prolog sidecar: 9 tests passed, including all four managed modes with native
  or symbolic deterministic model callbacks, real project-read schemas,
  confined file reads, skill option consumption, and preserved history.
- A built CLI session using the installed-copy sidecar showed `Mode: symbolic`,
  eight core/project skills, `project_read`, `/direct-rlm`, budget and status.
- Source regressions failed before fixes for skill selections and parent/child
  project-read capability grants. Prolog test failures now exit nonzero.

The installed copy contains the pinned runtime source and skills, sidecar and
an executable SWI wrapper outside the source tree. This verifies installed-copy
behavior, not a successful local Nix derivation build. Local `nix flake check`
evaluated its derivations but failed building dependencies: cache.nixos.org
returned proxy 403 and the relocated store could not open a bash source path.

Upstream runtime head `9735394` CI passed: CI 39138195954, Nix 39138196009, clean pack install
39138195950, Tree-sitter 39138196007. Paid OpenRouter 39138195955 was skipped.
Local upstream deterministic corpus passed 1290 tests; benchmarks passed 16/16
and 15/15. No live provider credential was available locally. Fake callbacks
and fixture usage are not live-provider evidence. No merge is authorized.

The first downstream CI run passed Nix sidecar packaging and all TypeScript
checks, then failed the new Prolog catalog regression: the bare upstream pack
used by the dev shell had no skills. The upstream pack now owns `skills/` and
checks its default catalog outside the source tree. The downstream duplicate
skill copy is removed, and its pack-load check also requires that catalog.
Final-head CI results are recorded in the PR description.
