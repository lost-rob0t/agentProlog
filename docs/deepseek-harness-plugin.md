# DeepSeek Harness plugin bridge

Status: **GO for a narrow protocol spike; HOLD evolutionary algorithm implementation until prolog-rlm#142 defines the reusable API.**

This note implements the downstream design gate from #2. It deliberately keeps DeepSeek Harness/Cordis types out of `prolog-rlm`.

## Verified Harness surface

DeepSeek Harness is currently developer preview and explicitly warns that compatibility-breaking changes are expected. The adapter therefore pins a tested Harness revision/version and treats its Cordis-facing surface as replaceable.

The current architecture is plugin-first: host plugins contribute services, typed events, and reversible effects to a Cordis `Context`. Profiles stack bundles plus out-of-tree plugins and patch rows. Required services are declared through `inject`; disappearance of a required service disposes dependent plugins and they reactivate when the service returns. `ctx.effect()` owns external resources and its disposer is awaited on unload.

For AgentProlog this makes the narrowest stable integration point an **out-of-tree host plugin that provides one namespaced bridge service and owns one persistent Prolog sidecar as a reversible effect**. Do not patch Harness core and do not couple the bridge to the browser plugin loader.

Primary upstream references:

- https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md
- https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/develop/framework/service.md
- https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/develop/basic/index.md
- https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-api/fiber.md
- https://github.com/deepseek-ai/deepseek-harness/blob/master/.agents/notes/implemented/architecture/2026-07-23-client-plugin-loading-model.md

## Package and profile boundary

Proposed package:

```text
packages/deepseek-harness/
  package.json
  src/index.ts
  src/protocol.ts
  src/sidecar.ts
  src/genotype.ts
  test/
```

The package is an out-of-tree Cordis plugin. A profile/bundle row mounts it beside Harness plugins. Installation must be reproducible through this repository's Nix outputs; no runtime `npm install`, clone, or curl bootstrap.

The plugin provides a namespaced service such as `agentPrologRlm`. It may consume Harness services only when a concrete product operation needs them. Optional capabilities should be queried at the use site rather than turned into hard `inject` dependencies. This prevents gratuitous disposal/reload coupling.

## Bridge decision: persistent sidecar

Use a **persistent SWI-Prolog sidecar over framed NDJSON/stdio for the first implementation**.

Why:

1. It preserves `agentProlog -> prolog-rlm` dependency direction without Node embedding or FFI ownership hazards.
2. Nix can pin the Prolog runtime and library closure independently of Harness's Node dependency graph.
3. The process lifetime maps directly to a Cordis reversible effect: plugin load starts it; disposer requests cancellation, drains/terminates within a deadline, then kills only as a last resort.
4. NDJSON matches existing AgentProlog/prolog-rlm protocol work and is easy to fixture-test without Harness UI.
5. It keeps reconnect/version negotiation explicit while Harness is developer preview.

Do not create a second scheduler in TypeScript. The sidecar is a transport endpoint to canonical Prolog runtime operations.

## Protocol envelope

Every frame is a JSON object with an explicit protocol version and correlation identifiers.

```text
request
  version
  request_id
  session_id
  operation
  payload
  deadline_ms?

response
  version
  request_id
  session_id
  status = ok | error | cancelled | timeout | denied
  payload?
  error?
  usage?
  verification?
  trace?

runtime_event
  version
  session_id
  run_id
  sequence
  event
  payload
  parent_run_id?
  subagent_run_id?
```

The allow-listed initial operations are intentionally small:

```text
runtime.describe
session.start
session.cancel
session.inspect
experiment.start
experiment.cancel
experiment.inspect
experiment.population
experiment.lineage
```

`experiment.*` remains unavailable until upstream #142 reaches GO and exposes the corresponding public predicates. Generated payloads are data; no frame may contain arbitrary Prolog goals, JavaScript source, shell source, or an unrestricted `call` operation.

Unknown versions, operations, fields that violate the selected schema, duplicate request IDs with conflicting payloads, and out-of-order non-replayable events fail closed.

## Lifecycle and cancellation

Cordis owns the external process through `ctx.effect()`.

Load:

1. resolve the Nix-pinned sidecar executable;
2. spawn with an explicit project/config root and no ambient shell;
3. negotiate protocol/runtime capabilities with `runtime.describe`;
4. publish the bridge service only after negotiation succeeds.

Unload/reload:

1. stop accepting new product requests;
2. issue cancellation for active sessions/experiments;
3. await structured terminal outcomes until a bounded deadline;
4. close stdin and await process exit;
5. force terminate only after the deadline;
6. dispose the service/effect so dependent Cordis plugins cannot retain a dead bridge.

Harness hot reload therefore cannot silently orphan an evolutionary experiment. Whether an experiment may be resumed after a bridge restart is an upstream persistence decision, not a TypeScript invention.

## Error mapping

Transport/process failures are distinct from Prolog runtime outcomes.

```text
bridge_spawn_failed
bridge_protocol_mismatch
bridge_disconnected
bridge_malformed_frame
runtime_denied
runtime_cancelled
runtime_timeout
runtime_failed
verification_failed
```

Never turn disconnect, timeout, malformed output, failed verification, or unavailable upstream capability into success.

## Usage, verification, and subagents

The adapter transports structured usage and verification records without interpreting them as policy. At minimum preserve token/cost/time counters, verifier outcome/evidence references, trace/run IDs, and effect uncertainty supplied by upstream.

Subagent scheduling remains upstream. Once prolog-rlm exposes the canonical RLM subagent tool and terse-KB command binding, the bridge only transports the typed command/event/result. `parent_run_id` and `subagent_run_id` preserve correlation. TypeScript must not decide when to spawn a subagent or execute generated code.

## Product genotype schema

AgentProlog owns validation for coding-product fields while generic candidate/lineage/mutation/selection semantics remain upstream.

Initial product fields may include:

```text
roles
prompt_refs
skill_refs
model_routes
allowed_tool_sets
loop_profile
verifier_profile
context_profile
budget_profile
```

Values are references/enums/validated data constrained by immutable upstream ceilings. A candidate cannot add authority, widen filesystem roots, disable required verification, raise host budget ceilings, or replace an allow-listed operation with executable source.

## Benchmark composition

Downstream benchmark definitions bind a product task corpus to upstream evaluator hooks. A result reports separate correctness, verification, cost, latency, robustness/failure and resource evidence. Do not collapse those dimensions into one TypeScript-owned magic scalar; upstream #142 owns generic fitness representation and selection.

## Headless inspection

The bridge service must work without Web UI. `experiment.inspect`, `experiment.population`, and `experiment.lineage` return structured snapshots suitable for CLI/TUI/client rendering. UI plugins project those snapshots; they do not own experiment state.

## Compatibility gate

Because Harness is developer preview, CI for this plugin must pin a known Harness revision/version and test:

- plugin load and service publication;
- required-service disappearance/reload behavior where used;
- sidecar startup/negotiation;
- protocol-version mismatch rejection;
- malformed/unknown operation rejection;
- request correlation and ordered events;
- cancellation and timeout propagation;
- unload with active work leaves no child process;
- restart does not falsely report interrupted work as successful;
- headless operation;
- subagent event/result pass-through once upstream exposes it;
- evolution operations remain capability-unavailable until #142 reaches GO.

A second compatibility lane may track Harness `master` as allowed-to-fail signal while the pinned revision remains the required gate. Never silently widen the supported surface because `master` changed.

## Nix dependency path

The eventual flake should package the Node plugin and sidecar closure together while pinning `prolog-rlm` as a flake input. The runtime executable path is injected into plugin config by Nix. Harness itself may be supplied by the profile/user environment, but compatibility tests must build against the pinned supported Harness source/version.

No runtime dependency downloads.

## Implementation slices

1. **GO now:** protocol types/schema + fake sidecar fixture + Cordis lifecycle/service plugin + load/unload/cancel/version tests. This does not require evolutionary algorithms.
2. **GO when upstream subagent contract lands:** typed subagent event/result pass-through conformance only.
3. **HOLD until prolog-rlm#142 GO:** `experiment.*` calls backed by the real reusable evolutionary library, genotype mapping, benchmark composition and population/lineage inspection.
4. **REJECT:** implementing mutation/crossover/selection, generic fitness, authority, verification, effects, scheduler, or subagent scheduling in TypeScript.

This split lets the product integration become executable now without racing upstream workers or fossilizing DeepSeek-specific concepts into core.