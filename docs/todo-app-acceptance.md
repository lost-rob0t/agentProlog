# Real coding-agent acceptance: CRUD todo app

This slice uses the canonical AgentProlog session host and its pinned Prolog-RLM
runtime. The model receives a fixed requirements file and real confined tools.
It must produce the application, not a code suggestion. The trusted coding
package selects the custom `builder` agent and native `build-todo` skill. An
operator Prolog file supplies every grant, package and budget setting.

`workspace_check` is a fixed `node --check` tool: no shell, no arbitrary command
arguments, no inherited credentials, a five-second process timeout and bounded
diagnostics. It uses the native `process` effect/approval boundary. Syntax errors
are observations, not evidence of success. Source changes still require exact
native approval and content preconditions.

The independent checker starts `app.mjs` with a clean environment, Node filesystem
permissions restricted to the workspace, subprocess permission denied and a
bounded heap. This is **not** an OS security sandbox or network isolation.
It exercises actual loopback HTTP:

- HTML page, input and browser script present;
- create two independently identified todos;
- list them, change title/completion and observe the change;
- reject invalid input and missing IDs;
- delete one todo without changing the other.

HTML presence is checked; browser interactions are not yet an automated gate.
The application uses an in-memory collection, so restart persistence is not part
of this intentionally small target.

## Run

Only use an existing authorized credential. There is no provider fallback.
OpenRouter execution was explicitly authorized by the operator with a USD 0.10
target for this session; that is not authorization for future unattended calls.
Runtime cost accounting is not a provider-enforced billing cap.

```sh
export PROLOG_RLM_SOURCE=/path/to/pinned/prolog-rlm
export OPENROUTER_API_KEY=... # resolve through your normal credential mechanism
AGENTPROLOG_TODO_LIVE=1 AGENTPROLOG_TODO_PROVIDER=openrouter \
  node packages/conversation-ui/test/todo-app-acceptance.js
```

Default per-invocation target is USD 0.04; `AGENTPROLOG_TODO_MAX_COST` may narrow
it. At most three verification-driven turns are permitted. A repair does not
weaken the original requirements. Known cumulative cost constrains repair;
unknown cost blocks it. Admission is not a hard monetary reservation, so callers
must use provider-side limits when a guaranteed billing ceiling is required.
The target applies to one invocation, not all separately initiated invocations.

Artifacts and categorical runtime receipts remain under `/tmp/opencode/` unless
`AGENTPROLOG_TODO_ARTIFACT_DIR` selects another directory. A preserved existing
app is repaired, never overwritten using the create operation. Generated code
is never run with provider credentials in its environment.

After generation, re-run the independent checks without any credential or new
model call:

```sh
node packages/conversation-ui/test/verify-recorded-todo.js /path/to/artifact-directory
```

This checks the recorded actual provider/model route, successful native source
mutation and syntax check, source hash equality, then executes the HTTP checks
again. Its receipt explicitly labels model I/O as recorded rather than fresh.
Deterministic positive and negative checker fixtures are never supplied to the
model and never count as live-provider evidence.
