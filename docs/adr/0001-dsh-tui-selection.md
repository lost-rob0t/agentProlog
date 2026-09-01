# ADR 0001: DSH TUI selection for agentProlog

## Status

Accepted for research purposes only. No TUI is installed, vendored, or depended on in this slice; agentProlog runs headless. The chosen TUI is consumed in a later slice, re-verifying command interoperability against the then-current release before anything is added to `package.json`.

## Context

agentProlog is a DSH-native symbolic coding-agent layer: DSH owns the harness (sessions, model providers, tools, approvals, cancellation, durable events), and agentProlog contributes a mode router plus direct/symbolic/symbolic-recursive execution adapters as an ordinary DSH plugin. The user-facing surface will be an existing DSH TUI; agentProlog must not build, fork, or vendor a TUI.

Hard requirements for the future TUI choice:

- Composes into a DSH profile as an out-of-tree plugin/bundle without patching DSH.
- Forwards slash commands registered by other plugins in the same profile, so `/direct`, `/symbolic`, and `/symbolic-recursive` appear without modifying the TUI.
- Renders streaming output, reasoning, tool calls, diffs, approval dialogs, and ask-user questions; supports session resume and cancellation.
- Works on Linux with the Node engines range DSH requires (`^22.19 || >=24`).
- Survives DSH pre-release API churn (the harness is at 0.1.0-rc.8 in this checkout).

Research date: 2026-09-01, against DSH 0.1.0-rc.8 (this checkout).

## Candidates

### @dsh-tui/dsh-tui

npm 0.1.2 (published 2026-08-14), GitHub `dsh-tui/dsh-tui` (31 stars, 4 forks, 18 commits), MIT. Built on `@earendil-works/pi-tui` (pinned 0.80.7 with a pnpm patch, bundled into `lib/`). Installs via `dsh plugin --profile tui add @dsh-tui/dsh-tui`. Composes over the official `@deepseek-ai/dsh-base` bundle — the same plugin stack the official web surface uses. Documented features: streaming model output and reasoning as Markdown; tool-call cards with terminal/diff/generic render intents; approval and `ask_user_question` dialogs including plan-mode review; slash commands `/model`, `/resume`, `/compact`, `/details`, `/help`, **and every command other plugins register**; todo panel; token usage and context-pressure status line; session resume; configurable theme. The implementation was recovered from DeepSeek Harness repository history (`packages/ui/tui`, removed upstream in commit `10bb9cbf4a`) and ported to the published rc API, so it tracks the architecture the DSH team originally shipped. Known limitations: the recovered test suite predates the port and does not run yet; peer dependencies pin the tested rc line.

### @openma/deepseek-harness-tui → Martty

The package was renamed; the maintained form is Martty (`openma-ai/Martty`), a DSH-first Rust/ratatui agent TUI distributed as native binaries (macOS arm64/x64, Linux arm64/x64, Windows x64) inside the npm release. It is an ACP client: the recommended profile path mounts an ACP plugin on the dsh Base Host tree and starts a separate TUI client process. Extensible through Cordis client-tree plugins, themes, views, and commands, and can attach to any ACP-compatible agent, not just DSH. Install: `dsh plugin --profile martty add martty@latest`.

### @riesbri/dsh-tui

Does not exist. No npm package, repository, or directory listing found under this name. Dropped from evaluation.

### Discovered during research (secondary)

- `@deepseek-harness-tui/dsh-tui` (npm 0.9.0, 2026-08-23, GitHub `ccch1mneyyy/dsh-TUI`): Claude Code-style full-screen TUI on a ported Ink/Yoga core; "zero core changes, pure plugin mounting"; featured by the official DeepSeek Harness channel as a community pick. Strong popularity signal.
- `@tomowang/dsh-tui`: out-of-tree mode bundle stacking on `dsh-base` exactly like the shipped `dsh-web-app`/`dsh-headless` bundles; renders the durable session log; small (4 stars).
- `@mcswift/dsh-tui` (`TheMcSwift/DeepSeek-TUI`): pi-tui client with approval waterfall, userQuestions provider, slash menu, session branching; out-of-tree profile bundle.
- `@chalk/dsh-tui` (`DanielOu1208/deepseek-harness-tui`): standalone pi-tui interaction plane; launcher + cordis.patch.yml profile overlay.
- Blue, dsh-tui-pro, dsh-mini-tui: additional community TUIs of varying scope; none showed stronger evidence on the deciding criteria.

## Evaluation

| Criterion | @dsh-tui/dsh-tui | Martty | @deepseek-harness-tui/dsh-tui |
|---|---|---|---|
| Native DSH plugin/profile composition | Yes — out-of-tree bundle over dsh-base | Via ACP plugin + separate client process | Yes — pure plugin mounting |
| Plugin slash-command forwarding | Documented: renders every command other plugins register | Not evidenced; command model is its own | Not evidenced in sources reviewed |
| Streaming + reasoning display | Yes | Yes | Yes |
| Tool-call/diff rendering | Yes, render-intent based | Yes | Yes |
| Approvals / ask-user dialogs | Yes, including plan-mode review | Yes | Yes |
| Session resume | Yes | Yes | Yes |
| Cancellation | Yes (Esc interrupt, Ctrl+C) | Yes | Yes |
| Context/token display | Yes | Yes | Yes |
| Linux support | Node-based, yes | Native binaries, yes | Node-based, yes |
| Maintenance activity | npm publish within days of research date | Active (rename/migration recent) | Active (0.9.0, recent) |
| Fidelity to DSH APIs | Highest — ported official `packages/ui/tui` | Own architecture over ACP | Own ported Ink core |
| Dependency footprint | pi-tui (patched, bundled) | Native Rust binary | Ported Ink/Yoga runtime |
| Test quality | Recovered suite present, not yet running upstream | CI builds binaries | Unknown |
| Community size | 31 stars | Large install base, official-ecosystem listings | Featured by official channel |

Deciding factors, in order:

1. **Plugin slash-command forwarding.** agentProlog's whole UX contract is three plugin-registered commands. `@dsh-tui/dsh-tui` is the only candidate whose documentation explicitly commits to rendering every command other plugins register; the others route commands through their own command models.
2. **Upstream fidelity.** It is the recovered official DSH TUI, ported to the published rc API — the least likely to drift from DSH's own session/event/service contracts as DSH evolves.
3. **Composition model.** Same out-of-tree bundle mechanism as `dsh-web-app` and `dsh-headless`; agentProlog's bundle joins the same profile without any TUI awareness in agentProlog.

Popularity alone was not treated as decisive: `@deepseek-harness-tui/dsh-tui` has the strongest popularity signal, but neither it nor Martty evidenced the third-party command forwarding this slice depends on.

## Decision

**Recommend `@dsh-tui/dsh-tui`** as the TUI agentProlog consumes in a later slice. Re-verify at integration time that (a) its pinned rc is compatible with the DSH release agentProlog targets, and (b) a plugin-registered command from a test bundle appears in its slash menu. Runner-up to re-evaluate if verification fails: `@deepseek-harness-tui/dsh-tui`. Martty remains the fallback if a native/ACP client becomes a requirement.

## Risks

- **Upstream churn.** DSH is pre-release (rc line); `@dsh-tui/dsh-tui` pins the tested rc and expects breakage. Mitigation: pin both sides; re-verify on every DSH bump.
- **Single-maintainer recovery project.** 31 stars, one organization, 18 commits. The ported-official provenance lowers but does not eliminate bus-factor risk. Mitigation: the runner-up stays one `dsh plugin add` away; agentProlog keeps zero TUI dependencies in its own package.
- **Upstream re-adoption.** DeepSeek could ship an official TUI again (the code originated there), making this project redundant. agentProlog's headless-first design means switching is a profile change, not a code change.
- **Unverified at runtime in this slice.** The recommendation rests on documentation and source review, not an executed interop test. The later TUI slice must verify before committing to the dependency.

## Integration Notes

- Profile composition (no agentProlog code changes needed):

  ```sh
  npm i -g @deepseek-ai/dsh@next
  dsh plugin --profile agentprolog add <agentProlog plugin package>
  export AGENTPROLOG_DSH_PLUGIN=<agentProlog plugin package path>
  export AGENTPROLOG_SIDECAR=$(nix build .#agentprolog-sidecar --print-out-paths)/bin/agentprolog-sidecar
  dsh --profile agentprolog --patch profiles/agentprolog.patch.yml
  ```

- agentProlog registers `/direct`, `/symbolic`, `/symbolic-recursive` through the standard DSH command registry (`ctx.commands.register` in `packages/agentprolog/src/commands.ts`, no TUI dependency); dsh-tui's command menu picks them up per its documented forwarding behavior.
- Headless testing never touches the TUI: `pnpm test` covers the router, commands, adapters, and the real sidecar process (`packages/agentprolog/test/headless.integration.test.ts`), and `nix flake check` covers the pinned Prolog closure without any API key.
- Git-hosted installs require allowing the `prepare` build under `allowBuilds` in `~/.dsh/profiles/agentprolog/pnpm-workspace.yaml`.
