# Security compatibility

## CVE-2026-82533 — DeepSeek Harness local control-plane privilege escalation

AgentProlog must not run on DeepSeek Harness `0.1.1-rc.2` or earlier. Those releases are affected by CVE-2026-82533: a sandboxed coding agent could reach the Harness local control plane and mutate its own session to `danger-full-access`, disabling the file sandbox and approval prompts.

The reviewed fixed compatibility target is:

- DeepSeek Harness: `0.1.2-rc.1`
- upstream tag: `dsh-v0.1.2-rc.1`
- upstream commit: `a66e4702047846cdaa10c66c9d3df3951f5ea70d`
- Cordis: `4.0.2`

AgentProlog pins every directly consumed `@deepseek-ai/dsh-*` package to the exact fixed release and checks the lockfile for the same resolved train. Floating `latest`, `next`, caret, or tilde ranges are not accepted as a security boundary.

The runtime host identity gate remains fail-closed. `assertHarnessCompatibility()` runs before the sidecar transport is constructed, before the AgentFactory is registered, and before commands or the AgentProlog service are published. A vulnerable, missing, or unreviewed version/revision therefore aborts startup rather than degrading to a permissive mode.

When reviewing a future Harness upgrade, update the package pins, lockfile, `SUPPORTED_HARNESS`, shipped profile identity, and compatibility/security tests together, then run build, typecheck, unit tests, real headless sidecar integration, and `nix flake check`.
