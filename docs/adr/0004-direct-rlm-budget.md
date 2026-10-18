# ADR 0004 — Direct-RLM and operator budget controls

Status: draft. Stacked on PR #48.

AgentProlog exposes `direct-rlm` over the shared Prolog-RLM completion runtime. This mode admits bounded RLM child operations (depth at most 2), unlike `direct` (depth 0). It does not yet claim to invoke the distinct upstream `rlm_direct/4` native-loop strategy. That requires a reviewed canonical managed-native-turn entrypoint upstream.

The TUI accepts per-turn overrides through `/budget`; defaults remain Prolog-RLM's values. The upstream 8192 limit is a **completion execution token budget**, not a provider context window. Explicit overrides cannot bypass the mode recursion ceilings.

Structured token-budget errors retain `kind`, `used` and `limit`. Explicit AgentProlog skills/tools inventory questions in the TUI resolve to the canonical catalog rather than infer runtime skills from conversation instructions.

## Deferred to upstream runtime

- Native direct-loop message projection as a managed conversation strategy.
- Automatic incremental warm publication using `rlm_conversation_warm` and `rlm_artifact`.
- Project-scoped KB observation indexing, provenance and replay-safe generation.
- A CI-validated upstream pin and updated `flake.lock`.

Never edit immutable source messages, grant executable authority to extracted claims, or install a chat preference as a trusted skill.
