# 0003: Prolog-configured agents and executable CRUD acceptance

Status: accepted for this product slice (Auto-RAGE, 2026-11-12).
Source: operator request in OpenCode `ses_e2d88a7fdffe7xMwHvay2rOGqk`.

## Analysis

Main only packaged a runtime-ready banner. PR #51 already supplies the real
session host, canonical approval continuations, native tool registry and confined
workspace tools. This branch integrates that candidate rather than forking it.
Its pinned upstream runtime is the execution authority. Existing trusted Prolog
plugins configure tools/providers/budgets, but named agents, native skill files
and local Prolog package composition are absent. `system_prompt` is accepted by
the loader but is not projected into provider requests.

## Design

- Keep `agentprolog_config/1` the single executable configuration entrypoint.
  Add named `agents` and `default_agent`; `--agent` selects one before a session
  starts. Agent settings inherit the merged configuration, narrow capabilities
  and budgets, and become part of durable configuration identity.
- Reuse local SWI-Prolog packs, not a new package manager. `--package DIR`
  explicitly trusts a local pack and its `prolog/agentprolog_plugin.pl` config
  entrypoint. No downloads, installation, remote dependencies or implicit trust.
- Native skill files contain one inert `agentprolog_skills([prompt_unit{...}])`
  term. The payload is the existing upstream compiler IR, not a second skill
  language or selector. Read it as bounded data, never consult it. The import
  command uses upstream `rlm_skill` to convert Markdown into these same units.
- Use upstream `rlm_prompt_compiler` for native skill/instruction projection.
  A small trusted model/planner callback forwards compiled system context through
  the canonical provider boundary. It is deliberately non-streaming when this
  projection is needed; it does not implement provider transport or an agent loop.
- Skills cannot grant tools, authority, mandatory status or capabilities.
  Explicit skill activation must fail if the compiler cannot admit the skill.
- Build a model-generated Node HTTP todo application in an isolated temporary
  workspace. An independent test starts the generated application with a clean
  environment and exercises real HTTP create/list/update/delete, error paths and
  its HTML page. Model prose and successful file writes alone cannot pass.

## Adversarial review

Reject unknown agents, agent capability/budget expansion, duplicate package or
skill identities, malformed/oversized/multiple-term skill files, directives and
rules, forged mandatory skill policy, missing explicit selections and changes to
configuration identity on reconnect. Preserve native per-write approval and
preimage hashes. Tests must cover actual provider-request context, not just
catalog registration. Do not execute model-generated code with provider secrets
in its environment. Generation/test timeouts and failure must not report success.

Rejected: copying generic runtime modules, a second scheduler/compiler, arbitrary
shell tools, model-loaded executable skills, inventing another package manifest,
or treating a deterministic model double as live acceptance.

## Acceptance and limits

Required: Prolog config/agent/package/skill regression tests; existing session,
workspace, UI and integration suites; Nix packaging; a bounded actual OpenRouter
run authorized by the operator with a USD 0.10 target. The target is not a
provider billing guarantee. No merge, deployment or publication is authorized.
This is a headless coding-agent slice, not completion of all refinery or UI epics.
