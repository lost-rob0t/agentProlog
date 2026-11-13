verification_command(deterministic, 'bash scripts/check.sh /path/to/pinned/prolog-rlm').
verification_command(recorded_real_app, 'node packages/conversation-ui/test/verify-recorded-todo.js ARTIFACT_DIR').
acceptance_target(todo_app, [html,create,list,update,delete,validation,other_todo_isolation]).
acceptance_boundary(todo_app, http_tested_not_browser_automated).
runtime_invariant(connection_ready, negotiation_and_canonical_snapshot).
failure_mode(node24_permission_flag, '--experimental-permission rejected', 'Use stable --permission and test a positive server fixture').
failure_mode(generated_source, syntax_errors, 'workspace_check runs fixed Node --check through native process authority; independent HTTP verification remains required').
failure_mode(model_completion, unverified_artifact, 'Separate native completion from independent artifact acceptance').

acceptance_receipt_component(recorded_real_app, observed_provider_and_selected_model).
acceptance_receipt_component(recorded_real_app, successful_native_source_mutation).
acceptance_receipt_component(recorded_real_app, current_source_hash_matches_mutation_observation).
acceptance_receipt_component(recorded_real_app, successful_native_syntax_check).
acceptance_receipt_component(recorded_real_app, fresh_independent_http_checks).
acceptance_evidence_boundary(recorded_real_app, recorded_model_io_not_fresh_provider_io).
checker_control(required, functional_server_passes).
checker_control(required, static_mock_fails).
checker_control(required, unstartable_module_fails).
accounting_boundary(max_cost_usd, reported_usage_guard_not_provider_billing_reservation).
accounting_boundary(invocation_target, does_not_cover_separately_started_invocations).
accounting_boundary(final_turn_cost, not_whole_session_spend).
repair_constraint(todo_app, original_requirements_unchanged).
repair_constraint(existing_file, hash_guarded_write_or_modify_not_create).
repair_constraint(automatic_retry, unknown_cost_blocks_additional_turns).

acceptance_source(checker_controls,
    '511a154e19847c78ab5e1aca32f3c2fad86edb37',
    ['packages/conversation-ui/test/todo-app-proof.js',
     'packages/conversation-ui/test/todo-app-proof.test.js']).
acceptance_source(recorded_real_app,
    '511a154e19847c78ab5e1aca32f3c2fad86edb37',
    ['packages/conversation-ui/test/verify-recorded-todo.js']).
acceptance_source(repair_and_accounting,
    '511a154e19847c78ab5e1aca32f3c2fad86edb37',
    ['packages/conversation-ui/test/todo-app-acceptance.js',
     'docs/todo-app-acceptance.md']).
