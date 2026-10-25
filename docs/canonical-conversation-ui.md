# Generic Prolog-RLM agent application

AgentProlog owns a reusable application/session host and terminal UI. Prolog-RLM
owns the native model/tool execution loop, authority, capabilities and budgets.
Downstream harnesses provide trusted Prolog profiles, tools and behavior; no
research prompts, OSINT tools, source collection or StarIntel business logic is
built into this application. Existing DSH PR #8 remains separate and untouched.

## Run and configure

```sh
nix run . -- --project /absolute/project --state /absolute/private/session-state
nix run . -- --project /absolute/project --plugin /absolute/plugin.pl \
  --allow-tool word_count --allow-context peek
# Explicitly authorize executable project-local Prolog:
nix run . -- --project /absolute/project --trust-project --allow-tool word_count
```

Plugins and project configuration are executable trusted code. Explicit
`--plugin FILE` trusts that plugin; `--trust-project` trusts
`.agentprolog/config.pl` in the selected project. These flags are operator input,
never accepted from model output or remote protocol commands. Capabilities
remain bounded by explicit `--allow-tool NAME` / `--allow-context OP` grants.
See [Prolog configuration](prolog-configuration.md) for loading, precedence,
conflicts, budgets, examples and the limits of trusted-code isolation.

Without `--state`, the CLI derives a stable directory under
`$XDG_STATE_HOME/agentprolog` (or `~/.local/state/agentprolog`) from the canonical
project path. Separate state directories select separate sessions. Never point
different workspaces at the same state directory.

The installed default application now starts the interactive client instead of
printing runtime-ready and exiting. `agentprolog-session` is the generic native
host; `AGENTPROLOG_SESSION` can select its launcher during local development.

External adapters can also provide the same canonical contract:

```sh
node packages/conversation-ui/src/cli.js --sidecar /absolute/adapter \
  --sidecar-arg argument
```

No shell evaluation occurs. External argv is explicit and cannot be combined
with the bundled host's project/config flags. Adapter paths and profile behavior
are operator configured, not inferred from a model or repository title.

## Interaction and authority

Type an objective/follow-up to send `session.turn {objective}`. `/create` and
`/select` initialize or refresh the configured session; `/resume` explicitly
starts a new run for the previous objective. `/profile` shows runtime-advertised
profile/capabilities. `/inspect`, `/cancel`, `/approve ID DECISION`,
`/answer ID TEXT`, `/reconnect`, `/help` and `/quit` expose generic operations.

The UI projects canonical snapshots and ordered events: messages, generic tool
arguments/results, approvals/questions, subagents, verification, usage/budgets,
trace/artifact references, uncertain effects and optional extensions. It never
executes tools or chooses the next model action. Run truth comes from
`state.run.outcome.status`; protocol stream status `finished` alone is not
success. An accepted artifact is not publication.

Reconnect restarts the configured sidecar and negotiates a canonical checkpoint.
The UI does not replay uncertain mutations or rebuild authority from logs. Old
state stays visible but marked stale while disconnected. Duplicate events are
ignored; gaps, wrong sessions, malformed payloads and unsupported required
extensions fail closed. Approval decisions must still be pending and offered;
the runtime independently validates them. Terminal controls in runtime text are
stripped before display.

## Contracts and pins

The protocol remains `prolog_agent_ui_v1`. Runtime pin
`de9f4b3126f1dbd776ec2272b5cc63bc85260a14` is the coordinated integration
candidate containing snapshot/schema validation, supported MCP execution APIs
and the Z.AI coding provider. The generic native host consumes public runtime
APIs; protocol identity remains unchanged.

Downstream integration tests use an explicitly pinned external synthetic
harness fixture; no live research is enabled. The external harness must consume
the generic profile mechanism instead of duplicating AgentProlog's lifecycle.
That migration remains coordinated with its owner.

## Validation and remaining acceptance

Unit/adversarial tests cover all v1 event types, snapshot bounds, replay,
correlation, stale decisions, malformed payloads, timeouts, required capabilities,
connect/close races and child termination. Official native fixture tests compare
the JS projection directly with the Prolog reducer and exercise crash/reconnect,
malformed input and the executable CLI. Generic native host/config/tool tests
are separate from downstream harness tests and from the final real-model gate.

This work is **not production-ready yet**. Full generic mutation-approval
continuation, final downstream report acceptance and
a bounded real-model filesystem task must all pass. No model-provider credential
was present in the implementation environment. The requested Z.AI subscription integration is proceeding with the upstream
provider owner. Final acceptance needs existing authorized access and confirmed
key type/quota; no credentials were available here and no paid usage was started.

## Hosted CI status

The original private cross-repository dependency failure was confirmed against
correct URLs and existing commits. The user made Prolog-RLM public, and the
retry at AgentProlog `071e17f…` fetched it successfully. Nix flake checks, default
package build/smoke and all 40 native config/host/filesystem tests passed on
GitHub. No credentials or visibility settings were changed by this work.

At implementation head `fd6b512…`, Nix CI, all 26 JavaScript tests, 40 native
tests, four official fixture tests and installed CLI checks passed. Generic E2E
passed 9/11 on both hosted and local SWI 9.0.4. Both cancellation tests passed
after cleanup ordering was repaired; the two mutation-approval gates still fail.
The newer coordinated runtime candidate is being checked separately and does
not inherit those results automatically.
See [manual real-model acceptance](real-model-acceptance.md) for the opt-in
`ZAI_API_KEY` mapping, exact model, bounds and required final proof.

Downstream synthetic integration against Auto-Dig
`9aa52295ef42b011459e541a649b04e3279a7d58` and runtime
`de9f4b3126f1dbd776ec2272b5cc63bc85260a14` passed all five tests locally on
SWI 9.0.4: typed fixture tool/report/approval, denial, durable reconnect and stale
decisions, cancellation/crash recovery, questions and budget/error handling.
The report remained a canonical draft with `published:false`. This is mock model
I/O with actual native tools and processes, separate from real-model acceptance.
