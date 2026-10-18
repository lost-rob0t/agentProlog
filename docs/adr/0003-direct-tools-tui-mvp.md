# ADR 0003: Direct tools and terminal control surface

## Status

Accepted for this slice (Auto-RAGE decision, 2026-10-16).

## Analyze

The current sidecar gives `direct` only `model(openrouter)`, although the pinned public `rlm_tool` API supports a confined project-read tool. Skills already load through `rlm_skill`, but the TUI can only list them. The TUI presents raw event JSON in verbose mode and has no canonical session status command. The upstream reasoning-mode contract for `/auto` remains open, so a downstream selector would create competing mode authority.

## Design

Register one project-read tool per sidecar session, rooted at that session's admitted working directory. Pass the registry through the existing completion option and grant `tool(project_read)` in direct mode. Destroy the registry with the sidecar session. The TUI exposes canonical `session.inspect`, `skill.load`, `skill.reset`, and `skill.list` operations as commands, and renders bounded runtime event summaries. Skill packages remain prompt units and never grant tool authority. `/auto` waits for the upstream public contract.

## Adversarial review

- A client-supplied root may point elsewhere: require an existing directory and use the upstream project-read preflight for path confinement and symlink rejection. The local client already controls its process working directory; root admission is not a remote authentication seam.
- A tool registry created before a failed session start could leak: create it after conversation creation and clean up on registration failure.
- A skill package may request capabilities: catalog loading is separate from registry/capability construction, so it cannot widen them.
- Runtime events may be malformed or huge: present only known event labels and bounded text; structured protocol validation remains in the bridge.
- A mode command can race a turn: retain existing turn-start mode resolution; a new selection applies to the next turn.

## Decision and acceptance

Use only the pinned public `rlm_tool` and `rlm_skill` contracts. Cover read-tool registration and confinement through real sidecar tests, command requests and failures through TUI tests, then run the repository gates. This slice is a foundation for issue #9 and #10; it does not claim upstream `/auto`, session resume, or a full-screen TUI.
