# Canonical conversation client

`packages/conversation-ui` is a generic terminal projection of the public
[`prolog_agent_ui_v1`](https://github.com/lost-rob0t/prolog-rlm/blob/fa03bb5b48c858b16ec6061d5b49804ee6f29070/docs/prolog-agent-ui-v1.md)
contract. It contains no research prompts, OSINT tools, collection adapters,
provider calls, tool execution or autonomous agent loop. Those belong to the
selected external harness/profile. It does not replace PR #8's DSH integration
or claim the desktop/Android scope of epic #25.

## Run

```sh
node packages/conversation-ui/src/cli.js --sidecar /absolute/path/to/sidecar
# Or use the packaged application:
nix run .#conversation -- --sidecar /absolute/path/to/sidecar
```

Additional arguments are individual `--sidecar-arg VALUE` options. There is no
shell evaluation. `AGENTPROLOG_SIDECAR` can supply the executable path.

The UI shows conversation text, generic tool arguments/results, pending and
resolved approvals/questions, subagents, verification, usage/budgets, trace
references, uncertain effects and arbitrary optional extensions. Evidence,
citations, reports and artifacts remain runtime data; the UI renders those
records without interpreting their workflow semantics. Terminal controls from
runtime content are stripped. Completion is not presented as publication.

Commands: `/inspect`, `/cancel`, `/approve ID DECISION`, `/answer ID TEXT`,
`/reconnect`, `/help`, `/quit`. Decisions must be offered by a pending canonical
approval. The runtime must also revalidate authority/correlation; local checks
are merely protection against stale interaction.

Reconnect starts the configured sidecar again and negotiates a canonical
checkpoint. Durable recovery depends on that sidecar's canonical store. The
client does not persist or replay mutations. A timeout reports an uncertain
outcome and requires inspection before retrying. Old state remains visible but
marked stale while disconnected. Gaps, wrong-session responses, malformed
payloads and unsupported required extensions fail closed.

## Integration status and dependencies

This is an **incomplete integration**, not a usable research harness release.
The existing default Nix probe is preserved until the external product sidecar
and profile contract are coordinated. The conversation application is available
as the explicit `conversation` app.

The public v1 document does not specify session creation/selection, objective or
turn commands, profile negotiation, or a research execution sidecar. This client
does not invent those semantics. Needed from the backend owner through the
parent: exact runtime/harness pins, launch argv, negotiated generic profile
capabilities, command payloads and the canonical publication/report lifecycle.
The intended integration uses generic profile selection and typed metadata,
never built-in research logic in AgentProlog.

## Validation matrix

- Unit/golden: all v1 event types; bounded canonical snapshot projection;
  duplicate replay; gaps; wrong sessions; stale approvals; malformed payloads;
  unknown required extensions; timeout uncertainty; control-character safety;
  generic product boundary.
- Native fixture: actual official SWI-Prolog module from the existing flake pin;
  projection compared to Prolog's own canonical snapshot; cancellation command;
  process crash and reconnect; malformed wire input; actual CLI interaction.
- Installed CLI smoke: npm installation and executable `--help`.
- Nix check: packaged conversation CLI `--help`.
- **Not yet proven:** objective → actual fixture tools → report; approval
  reject/approve across an executing harness; active execution cancellation;
  canonical durable restart; budget enforcement. The official protocol fixture
  does not execute these workflows. Its cancellation acknowledgment is not
  evidence of cancelling an active research process.

CI keeps native-fixture evidence separate from unit results and uploads the
terminal transcript. Both use the exact runtime commit already in `flake.nix`.
The official hyphenated fixture launcher initializes `main/0` but defines
`main/1` at the inspected pin. Tests invoke the exported
`ui_fixture_server_loop/2` from the official module directly, without patching
or vendoring runtime implementation.

The copied golden NDJSON fixture originates from that pinned upstream. Its
optional-extension payload and outcome encoding differ from the live fixture;
therefore native snapshot equality, not the historical golden, is authoritative
for native conformance.
