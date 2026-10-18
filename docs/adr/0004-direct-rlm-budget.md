# ADR 0004 — Direct-RLM and operator budget controls

Status: draft. Stacked on PR #48.

AgentProlog exposes `direct-rlm` over the shared Prolog-RLM completion runtime. This mode admits bounded RLM child operations (depth at most 2), unlike `direct` (depth 0). It does not yet claim to invoke the distinct upstream `rlm_direct/4` native-loop strategy. That requires a reviewed canonical managed-native-turn entrypoint upstream.

The TUI accepts per-mode, per-session overrides through `/budget`; defaults remain Prolog-RLM's values. A setting in `/symbolic` does not affect `/direct` or `/direct-rlm`. The upstream 8192 limit is a **completion execution token budget**, not a provider context window. Explicit overrides cannot bypass the mode recursion ceilings.

Structured token-budget errors retain `kind`, `used` and `limit`. Explicit AgentProlog skills/tools inventory questions in the TUI resolve to the canonical catalog rather than infer runtime skills from conversation instructions.

## Product warm-context integration

The AgentProlog sidecar uses the pinned, existing `rlm_artifact` and
`rlm_conversation_warm` public APIs. By default, for `direct` and
`direct-rlm` only, it publishes a **maximum of 48** completed
historical messages after at least **24 eligible unprocessed messages**
accumulate, keeping the newest 12 messages hot. Set
`AGENTPROLOG_AUTO_WARM=0` to disable this product-layer producer.
This is a message-count threshold, not measured token-pressure compaction.

Production derives new immutable warm artifacts and reuses their
representation-selected context on the managed turn. Old messages stay
durable and cold-addressable, including when generation fails.
The model-based generator may incur **an additional completion** with
its own budget; there is not yet a joint token/cost reservation with
the enclosing managed turn. Failures are reported as compaction status
and are not silently treated as successful compaction.

A sidecar companion artifact store is derived from the admitted
private conversation store path with suffix `.warm.db`.
The `session.kb` protocol operation and `/kb` command project
**read-only** typed observation records from warm summaries, scoped
to the admitted conversation/project root. These are
`model_claim` observations, not trusted runtime facts or executable
Prolog clauses. The TUI output is capped at 100 observations; it
reports truncation. `/status` exposes the last compaction status.
The canonical runtime skills catalog is independent of those records.

## Remaining work

- Native `rlm_direct/4` message/tool projection as a managed
  conversation strategy; `direct-rlm` currently uses the canonical
  `rlm_completion` direct-or-plan supervisor.
- Upstream PR #519 provides a generic opt-in warm publisher with
  explicit batch options; adopt a reviewed upstream release/pin
  instead of maintaining the product wrapper indefinitely.
- A full semantic Prolog project-KB materialization, typed
  relational observation indexing and provenance-aware querying,
  not just the current read-only warm-context observation projection.
- Durable multi-writer concurrency guarantees, restart crash tests,
  token-pressure thresholds and live provider verification.

Do not claim all of these follow-ups are done because
the TypeScript and keyless sidecar checks pass.

Never edit immutable source messages, grant executable authority to extracted claims, or install a chat preference as a trusted skill.
