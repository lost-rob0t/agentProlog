verification_command(deterministic, 'bash scripts/check.sh /path/to/pinned/prolog-rlm').
verification_command(recorded_real_app, 'node packages/conversation-ui/test/verify-recorded-todo.js ARTIFACT_DIR').
acceptance_target(todo_app, [html,create,list,update,delete,validation,other_todo_isolation]).
acceptance_boundary(todo_app, http_tested_not_browser_automated).
runtime_invariant(connection_ready, negotiation_and_canonical_snapshot).
failure_mode(node24_permission_flag, '--experimental-permission rejected', 'Use stable --permission and test a positive server fixture').
failure_mode(generated_source, syntax_errors, 'workspace_check runs fixed Node --check through native process authority; independent HTTP verification remains required').
failure_mode(model_completion, unverified_artifact, 'Separate native completion from independent artifact acceptance').
