documentation_entry(repository, 'README.org').
documentation_entry(wiki, 'docs/wiki/Home.org').
documentation_entry(navigation, 'docs/wiki/_Sidebar.org').
documentation_entry(configuration_examples, 'examples/configurations/').
documentation_entry(scripting_examples, 'examples/scripts/').
documentation_format(canonical, org).
documentation_format(legacy_markdown_paths, compatibility_links_only).
documentation_check(local_integrity, 'python3 -B scripts/check-docs.py').
documentation_check(parser_fixtures,
    'python3 -B -m unittest discover -s test -p test_documentation.py').
documentation_check(tutorial_configuration,
    'python3 -B scripts/check-tutorial.py --runtime-lib /path/to/pinned/prolog-rlm/prolog').
documentation_boundary(local_integrity, not_publication_authorization).
documentation_boundary(tutorial_configuration, actual_loader_without_model_io).
documentation_boundary(canonical_client_scripts, no_automatic_approvals_or_questions).
documentation_boundary(provenance, audited_kb_ingest_writer_private_default).
prolog_goal_constraint(command_line_goal, use_get_dict_instead_of_compiler_expanded_dot_access).
module_import_constraint(workspace_and_check_tools,
    explicit_import_lists_avoid_execute_4_collision).
approval_bridge_mode(resumable_interactive_tool_approval, direct).
approval_bridge_limitation(typed_rlm_tool_approval, not_wired_into_direct_cursor_ui).
artifact_review_recovery(abrupt_checkpoint_restore, can_remain_pending).
artifact_review_recovery(normal_shutdown, requests_cancellation).
documentation_evidence_source('test/documented_configs_test.pl').
documentation_evidence_source('packages/conversation-ui/test/documented-scripts.test.js').
documentation_evidence_source('scripts/check-tutorial.py').
