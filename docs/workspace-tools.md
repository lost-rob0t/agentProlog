# Bounded workspace file tools

`prolog/agentprolog_workspace_tools.pl` is a generic optional Prolog tool pack.
A trusted plugin calls `workspace_tools(ProjectRoot, Tools)` and supplies the
returned `tool(Schema, Handler)` records in its configuration. The root is chosen
by trusted configuration, never by model arguments. Each tool also needs its
exact operator-granted `tool(Name)` capability.

| Tool | Arguments | Result |
|---|---|---|
| `workspace_read` | `path` | path, content, SHA-256, byte count |
| `workspace_create` | `path`, `content` | path, SHA-256, byte count |
| `workspace_write` | `path`, `content`, `expected_sha256` | path, SHA-256, byte count |
| `workspace_modify` | `path`, `old_text`, `new_text`, `expected_sha256` | path, SHA-256, byte count |

Paths are workspace-relative. Existing parent directories are required. Absolute
paths, empty/dot/parent segments, backslashes, control characters, directories
and symlink components are rejected. Files and replacement content are capped
at 65,536 UTF-8 bytes. `workspace_modify` requires exactly one nonempty match.
`workspace_create` never overwrites an existing file. Write/modify compare the
expected hash both before authority mediation and immediately before execution,
so edits made while an approval is pending cause a `stale_content` failure.

All mutations declare `effect:write`. Register the returned `tool_handler`
preflight/execute pair unchanged through Prolog-RLM's native registry. Preflight
normalizes and validates the exact target before native authority mediation;
the handler never creates an approval or widens authority. The default native
`approve_diff` mode must remain in force until an explicit decision. Rejection
and owner cancellation invalidate the pending native continuation. A changed
payload cannot reuse an old approval.

Writes use a sibling temporary file followed by atomic rename. Creation uses a
hard link to install the prepared file only if the destination is still absent.
Temporary files are cleaned on failure. Newly written files use owner-only read
and write permissions; replacing a file does not preserve executable bits or
other metadata. These tools intentionally do not create directories, delete
files, follow links, invoke shells, or expose unrestricted process execution.

This is a bounded trusted-workspace tool pack, **not an OS sandbox**. Static
symlink escapes are rejected and paths are rechecked at execution, but a hostile
concurrent process could race filesystem checks. Use a dedicated workspace not
writable by untrusted concurrent actors. For adversarial multi-user directories,
an OS-level sandbox or descriptor-relative no-follow file API is required before
claiming isolation against concurrent path replacement.

## Validation

`test/agentprolog_workspace_tools_test.pl` performs real filesystem operations in
new temporary directories and deletes only its own test directories. Tests assert
exact created/modified/replaced bytes, hashes, stale-write errors, containment,
size limits, and absence of unapproved files. Native registry tests prove
capability denial, pending approval, exact approval execution, stale-decision
rejection, denial and owner cancellation. These tests use no model and are not
live-model acceptance evidence.

```sh
swipl -q -p library=/path/to/prolog-rlm/prolog \
  -g "load_files(test/agentprolog_workspace_tools_test),(run_tests->halt(0);halt(1))"
```
