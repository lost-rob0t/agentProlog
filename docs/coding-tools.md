# Coding tools and deterministic experts

This product package requires the paired `prolog-rlm` deterministic-expert
change (`library(rlm_expert)`). The existing Nix runtime pin predates it;
the pin must advance after the upstream change is accepted. These modules do
not change the DSH bridge or claim to complete the interactive coding agent.

## Host composition

```prolog
:- use_module(library(rlm_tool)).
:- use_module(library(rlm_effect)).
:- use_module(prolog/agentprolog_coding).

% All configuration below is trusted host input, never consulted from a repo.
Profiles = [profile{id:"unit", snapshot:"host-snapshot-42",
    executable:'/absolute/path/to/test-runner', argv:['--unit'],
    env:['PATH'='/usr/bin:/bin','LANG'='C.UTF-8'], kind:test, seconds:60}],
coding_registry_create('/project', '/usr/bin/git', Profiles, Registry, ok(_)),
rlm_effect_store_open('/host-state/effects.pl'),
tool_invoke(Registry, [tool(project_read)], project_read,
            _{path:"src/main.pl"}, [], Outcome, Trace).
```

The host attaches this registry to its normal Prolog-RLM completion/plan
configuration and explicitly grants the required `tool(Name)` capabilities.
Loading never grants capabilities or changes authority. Open the upstream
durable effect store before writes/processes. Default approval remains intact;
use the existing pending-approval API to review and resolve operations.
Destroy the registry using `tool_registry_destroy/1` at session teardown.

| Tool | Inputs and behavior |
| --- | --- |
| `project_read` | Relative path; returns bounded UTF-8 content and SHA-256. |
| `project_search` | Relative file path and literal query; returns numbered matching lines, at most 100, with an explicit truncation flag. |
| `project_write` | Path, content, expected SHA-256; `"missing"` permits exclusive creation. |
| `project_patch` | Path, expected SHA-256, old text, new text; requires exactly one occurrence. |
| `git_status` | Empty object; fresh porcelain status. |
| `git_diff` | Empty object; tracked worktree changes against HEAD. |
| `git_show` | Empty object; current HEAD commit and diff. |
| `process_run` | Select a fixed host executable/argv profile by id. |
| `run_tests` | Same boundary, but accepts only profiles tagged `test`. |
| `write_expert` | Supplied path/content/old/new; derives an unexecuted patch proposal or a blocked result. |
| `test_result_expert` | Supplied exit code; classifies process success/failure, without claiming whole-Spec verification. |

The two experts use `rlm_expert` selection and the ordinary registered-tool
projection. They perform local inference without a model or filesystem access.
Execute a write expert's proposal through `project_patch`; the proposal itself
provides no write capability or approval.

## Guarantees and limits

Files are limited to 64 KiB. Paths reject traversal, symlinks, and `.git`
components. Mutation checks the exact content preimage before approval and
again immediately before replacement; it preserves ordinary POSIX permission
bits and publishes through a same-filesystem temporary file. Creation uses an
exclusive hard link. Namespace checks run again after approval. This is a
trusted local workspace boundary: hostile concurrent directory replacement
requires OS confinement/openat-style primitives not supplied by this package.
Atomic rename is not a multi-process compare-and-swap or an fsync durability
guarantee. ACLs, ownership, xattrs, and hard-link identity are not preserved.

Search is currently **within one supplied file**, not recursive repository
discovery. Git calls disable optional locks, fsmonitor, hooks, external diff,
textconv, global configuration, paging, and terminal prompts. Git failures,
including an unborn HEAD for diff/show, remain explicit nonzero results.

Process profiles contain an absolute executable, fixed argv, bounded deadline
(at most 300 seconds), explicit environment, and trusted snapshot identity.
Only PATH/LANG/LC_ALL/TZ/TMPDIR environment names are accepted. Repository test
code is executable host-approved code; cwd binding is not an OS sandbox.
Output is combined and bounded to 65,536 characters; excess output or timeout
fails the tool and cleanup kills its process group. Process groups do not
confine programs that deliberately escape into another session.

Process effects use upstream replay semantics. Repeating a profile with the
same snapshot replays the admitted result instead of executing it twice.
After source changes, the host must create a fresh registry with a new trusted
snapshot identity and rebind profiles. The receipt echoes that identity; it
does not independently prove source freshness. The host must not reuse an old
receipt as fresh verification evidence. Automatic source-KB refresh and the
full Verify/repair loop remain separate integration work.

## Local verification

```sh
swipl -q -p library=/path/to/prolog-rlm/prolog -s test/run_coding_tests.pl
node --test packages/deepseek-harness/test/*.test.js
```

The Prolog suite exercises real tool registry, capability, authority, effect
store, filesystem, Git, and process paths. It includes expert-to-edit flow,
stale approval, no mutation before approval, output/deadline limits, process
replay versus a new host snapshot, and permission preservation.

The language-aware extension is described in [language-tools.md](language-tools.md).
