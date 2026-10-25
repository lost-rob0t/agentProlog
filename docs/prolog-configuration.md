# Generic Prolog plugins and project configuration

AgentProlog is a reusable Prolog-RLM agent application. Its plugins define tools,
provider/model options and optional artifact policy in Prolog. A downstream
harness supplies its own domain tools and behavior; AgentProlog does not contain
research prompts, collection adapters or domain schemas.

The model, tool invocation, capability/authority checks, budgets and cancellation
remain in Prolog-RLM. A plugin is not an alternative agent loop.

## Trust and loading

Prolog configuration is executable code. It can execute directives while loading
and can perform arbitrary operations in its predicates. **The loader is not a
sandbox, and native tool capability restrictions do not sandbox trusted plugin
code.** Never silently consult configuration found in an untrusted checkout.

The host calls:

```prolog
load_configuration(ProjectDirectory,
    [ plugin('/absolute/operator-approved/word_count.pl'),
      trusted_project(true),
      allowed_capabilities([tool(word_count), context(peek)])
    ], Config).
```

- Each explicit `plugin(Path)` means the operator trusts that file as executable
  code. Relative paths resolve against the host working directory, not project
  metadata supplied over the wire. Prefer absolute paths.
- The only automatically discovered filename is
  `ProjectDirectory/.agentprolog/config.pl`. If it exists and
  `trusted_project(true)` was not explicitly supplied, loading fails before
  consulting it. The UI flag is `--trust-project`.
- `--plugin PATH` explicitly trusts a plugin. `--allow-tool NAME` and
  `--allow-context OP` and `--allow-model NAME` grant the corresponding native
  capability ceilings. The `rlm` mode requires the explicit `model(ProviderName)`
  capability matching its configured provider name.
- With no plugins or project config, the configuration is generic and has no
  tool or context grants. A plugin may request capabilities but cannot grant
  them to itself: every requested capability must be present in the operator's
  `allowed_capabilities` list.
- Never create trust or grants from model output, retrieved content, sidecar
  events, repository instructions, or an incoming session command.
- Run one sidecar process per project/configuration. Changing a project or its
  trusted code requires stopping that sidecar and loading in a new process.
  Module names must be unique across distinct source files; collisions fail.
- Configuration errors prevent starting the session. Failed source predicates
  are unloaded, but arbitrary initialization effects cannot be undone. The
  host must terminate after a load failure and start a fresh process after a
  correction. This is failure recovery, not a claim of transactional sandboxing.

The loader reads the first term to require an explicit module declaration before
consulting a trusted file. Modules must export `agentprolog_config/1`. The
configuration predicate must yield exactly one configuration within five
seconds. That bound does not contain arbitrary loading directives: trust is
required before loading any code at all.

## Configuration schema and precedence

A plugin or project module returns a dict containing any of:

| Field | Meaning |
|---|---|
| `profile` | Nonempty atom/string displayed as the profile identity |
| `mode` | `direct` or `rlm`; host selects the canonical runtime entrypoint |
| `tools` | List of `tool(Schema, QualifiedHandler)` registrations |
| `capabilities` | Exact native capability list, bounded by operator grants |
| `runtime_options` | Whitelisted native options described below |
| `budget` | Dict narrowing the operator budget ceiling |
| `hooks` | Trusted artifact policy hook described below |

Precedence is defaults, then plugins in explicit command-line order, then the
trusted project configuration. `profile` and `mode` use the last supplied value.
Native options override earlier options by name. Budget keys override earlier
keys but cannot exceed the operator ceiling. Capabilities replace the earlier
list when specified; omitting them preserves it. The tool list is additive;
**duplicate tool names fail instead of shadowing handlers**. Duplicate sources,
duplicate keys within option lists, duplicate capabilities, unknown keys,
unsupported options and invalid schemas fail closed.

Native options allowed in configuration are unary terms named `provider`,
`provider_name`, `model_handler`, `planner_handler`, `prompt_compile_mode`, and
`system_prompt`. Model/planner handlers must be ground module-qualified callables.
`model_handler` supplies deterministic direct/nested model I/O; `planner_handler`
supplies deterministic root planner I/O for `mode:rlm`. Both use the canonical
runtime callback contract `call(Handler, Request, Outcome)` and must stay in trusted
test plugins; neither is selectable through model/wire payloads. Registry,
capabilities and budget cannot be overridden through `runtime_options`.
Provider credentials should remain environment references resolved by the
provider, never literal values printed in configuration or session events.

Budget defaults are 8 model calls, 16 tool calls, 16 iterations, 32,768 total
tokens, 262,144 output bytes, recursion depth 1, 120 seconds, and USD 0.25.
`budget_limits(Dict)` can narrow this ceiling; project and plugin configurations
cannot expand it. Cost bounds depend on canonical provider usage/accounting and
do not replace verification of a real provider's billing behavior.

`load_configuration/3` returns the merged fields plus canonical absolute `project`
and `sources` paths. The host creates a native registry and calls
`register_config_tools(Config, Registry)` before passing the registry,
`Config.capabilities`, `Config.budget`, and `Config.runtime_options` into the
canonical Prolog-RLM execution API.

## Tools and artifact policy

`Schema` is the native `tool_schema` accepted by `rlm_tool:tool_register/4`,
including matching `name` and `capability:tool(Name)`, effect class, strict argument
and result schemas, and bounded tool limits. AgentProlog validates each schema
through a temporary native registry without executing its handler.

Handlers must be module-qualified. Both ordinary `Module:Closure` and native
`tool_handler(Module:Preflight, Module:Execute)` bindings are accepted. The
preflight form is appropriate for filesystem or other operations that need exact
confinement/target validation before native authority mediation.

A native tool result is retained as opaque context. A model must use the runtime's
native context inspection tools to read it; it must not assume an inline copy of
the result is present in the tool message. Grant only the needed context
capabilities, such as `context(peek)`, within the operator ceiling.

An optional `hooks:_{validate_artifact:Module:Closure}` receives the canonical
runtime result through `call(Closure, Result, Decision)`. It returns either
`complete(Artifact)` or `approval(Artifact)`, where `Artifact` is a JSON dict. This
lets a downstream harness validate or request review of its own artifact format
without placing domain policy in AgentProlog. The hook is trusted code, not a
model-selected callable. Approval does not imply publication or deployment.

## Generic example

[`examples/plugins/word_count.pl`](../examples/plugins/word_count.pl) registers a
harmless read-only tool that counts words in caller-provided text. It contains no
network, shell, filesystem mutation or model loop. Load it with an explicit
`tool(word_count)` grant and `context(peek)` when the model needs to inspect its
result. [`examples/project/.agentprolog/config.pl`](../examples/project/.agentprolog/config.pl)
shows project-local profile/budget overrides; it requires explicit project trust.

```sh
agentProlog --project ./examples/project \
  --plugin "$PWD/examples/plugins/word_count.pl" \
  --trust-project --allow-tool word_count --allow-context peek
```

Use the application's sidecar/state options for the selected installation.
The example requires a separately configured authorized provider to execute a
model turn. Deterministic model fixtures live under test support, not in this
plugin, and a live-model acceptance run must be reported separately.

## Validation

`test/agentprolog_config_test.pl` exercises trust-before-load, precedence,
capability ceilings, malformed configs, conflicts, budget narrowing, native tool
execution, source/module isolation and recovery. Run it with the pinned runtime:

```sh
swipl -q -p library=/path/to/prolog-rlm/prolog \
  -g 'load_files(test/agentprolog_config_test),run_tests,halt'
```

These deterministic tests do not establish that arbitrary trusted plugin code is
safe, nor do they replace the final bounded real-model acceptance gate.
