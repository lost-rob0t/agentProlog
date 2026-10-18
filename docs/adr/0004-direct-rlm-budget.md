# ADR 0004 — Managed native turns and separate budgets

Status: draft, stacked on PR #48. Requires the exact upstream PR #519 pin.

`direct` and `direct-rlm` invoke the canonical managed `strategy(native)` path,
which uses `rlm_direct/4`. Direct grants project reads and opaque result
inspection without recursion; direct-rlm adds bounded recursive operations.
Symbolic is the startup default. Both symbolic modes explicitly grant project
read authority to the parent before narrowing children.

Skill controls use flat canonical unary options; loading skills does not grant
authority. Execution budgets are per mode and per session. The 8192 execution
limit counts cumulative prompt and completion usage, separately from the
131072 context window. Provider output caps do not reserve prompt costs;
last-response overruns are reported and further execution stops.

The sidecar consumes the upstream opt-in warm publisher rather than maintaining
a second range-selection implementation. Publication uses estimated context
pressure and fills the first uncovered interval. Batches are bounded to 48;
the source transcript is immutable and has no lifetime cap. Compaction has its
own bounded completion and separately reported usage. It cannot inherit the
project registry, active skills or recursive authority.

`/kb` remains a read-only projection of attributable model claims, not trusted
executable facts. Native-loop deterministic tests do not establish live
provider behavior. Credentialed live tests, cross-process publication safety,
and full project semantic materialization remain unverified or out of scope.
