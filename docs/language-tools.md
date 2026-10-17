# Common Lisp and Prolog coding support

The coding registry now includes:

- `project_analyze({path})`: reads one confined `.pl`/`.prolog` or
  `.lisp`/`.lsp`/`.cl`/`.asd` file and returns source structure plus its hash.
- `source_inspect_expert({language, content})`: the same inert analysis over
  supplied text. Use `"prolog"` or `"common_lisp"`.
- `source_edit_expert({language, content, path, start, replacement})`: selects
  the definition/clause at the exact character start reported by inspection,
  checks that replacement is a single compatible definition, reparses the
  complete changed source, and returns an unexecuted `project_write` proposal.
- `compiler_diagnostics_expert({language, output, exit_code})`: extracts error
  and warning records from SWI/SBCL output, including SWI file/line/column where
  present, and retains raw compiler output. Nonzero exits or explicit errors
  produce failed status.

All three experts are ordinary capability-gated tools from `rlm_expert`.
`project_analyze` independently requires `tool(project_analyze)`; knowing a
path or receiving an edit proposal does not grant read/write authority.
The existing `project_write` approval and durable-effect boundary rechecks the
source hash. A stale proposal cannot overwrite a changed file.

For example, inspect `math.lisp`, select the `DEMO:SUM` definition's `start`,
and ask the edit expert to replace that whole form. In Prolog, each clause has
its own span, so two `p/1` clauses can be edited separately. Edits preserve the
file's ordered definition names/kinds/scopes and known Prolog arities. Lisp
lambda-list arity and method specializers are not checked. Renaming/moving a
definition is deliberately a different operation and is blocked here.

These are structural checks, not complete language semantics. Prolog custom
operator/conditional reader state and unsupported Lisp reader syntax produce
incomplete results and block edits. Lisp macro expansion, imported package
bindings, method dispatch, and runtime behavior still require the real
compiler/tests. Unknown call targets stay unresolved. See upstream
`docs/source-structure.md` for the precise supported subset.

Run compilers/tests through explicitly configured `run_tests`/`process_run`
profiles. Loading Prolog and compiling Lisp can execute project code; these
remain approved process effects. After editing, refresh the host snapshot and
profile bindings as required by the process replay contract. Diagnostic
classification reports supplied output; it does not certify independent or
fresh evidence, or satisfy a Frozen Spec on its own.

## Verification

```sh
swipl -q -p library=/path/to/prolog-rlm/prolog -s test/run_coding_tests.pl
AGENTPROLOG_SWIPL=/absolute/path/to/swipl \
AGENTPROLOG_SBCL=/absolute/path/to/sbcl \
swipl -q -p library=/path/to/prolog-rlm/prolog -s test/run_language_compiler_tests.pl
```

The explicit compiler lane hard-fails when either executable is not configured.
It uses real SWI plunit and SBCL compile/load/assert checks: fail, inspect,
propose a structural repair, apply it through the real write tool, bind a new
snapshot, and pass. The fixtures generate their own isolated test projects;
they do not execute an arbitrary repository's initialization code.
