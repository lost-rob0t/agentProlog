% Repository-scoped troubleshooting, promoted from ses_e2d88a7fdffe7xMwHvay2rOGqk.
% Implementation revision is evidence provenance, not a claim about arbitrary heads.
:- discontiguous diagnostic_case/1, diagnostic_symptom/2, diagnostic_cause/2,
                 diagnostic_fix/2, diagnostic_evidence/4.

diagnostic_case(connect_before_snapshot).
diagnostic_symptom(connect_before_snapshot, command_rejected(snapshot_required, after_successful_negotiation)).
diagnostic_cause(connect_before_snapshot, connect_promise_resolved_before_canonical_snapshot).
diagnostic_fix(connect_before_snapshot, await_snapshot_before_resolving_connect).
diagnostic_evidence(connect_before_snapshot,
    '511a154e19847c78ab5e1aca32f3c2fad86edb37',
    'packages/conversation-ui/src/client.js',
    test('packages/conversation-ui/test/transport.test.js',
         'connect is not ready until a separately delivered canonical snapshot')).

diagnostic_case(failed_run_loses_usage).
diagnostic_symptom(failed_run_loses_usage, failed_run_missing_completed_provider_usage).
diagnostic_cause(failed_run_loses_usage, usage_projected_only_on_successful_completion).
diagnostic_fix(failed_run_loses_usage, project_error_usage_before_finishing_failed_run).
diagnostic_evidence(failed_run_loses_usage,
    '511a154e19847c78ab5e1aca32f3c2fad86edb37',
    'prolog/agentprolog_session.pl',
    test('test/agentprolog_session_test.pl', failed_run_retains_actual_usage)).
