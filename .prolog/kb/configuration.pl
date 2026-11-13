configuration_entry(operator, 'agentprolog_options/1', '--config FILE').
configuration_entry(product, 'agentprolog_config/1', '--plugin FILE or trusted project config').
configuration_entry(local_swi_pack, 'prolog/agentprolog_plugin.pl', '--package DIR').
skill_representation(native, 'agentprolog_skills([prompt_unit{...}])', inert_data).
skill_compiler('rlm_prompt_compiler', upstream).
permission_invariant(named_agent, narrows_parent_capabilities_and_budget).
permission_invariant(native_skill, no_capability_or_authority_grant).
configuration_runtime_state(project_scoped, fresh_sidecar_process).
projection_limitation(native_skill_or_system_prompt, non_streaming_model_callback).

projection_path(native_skill_or_system_prompt,
    [upstream_prompt_compiler, trusted_model_or_planner_callback, canonical_provider_context]).
configuration_source(operator_and_named_agents,
    '511a154e19847c78ab5e1aca32f3c2fad86edb37',
    ['prolog/agentprolog_config.pl','test/agentprolog_agents_test.pl']).
configuration_source(native_skills_and_projection,
    '511a154e19847c78ab5e1aca32f3c2fad86edb37',
    ['prolog/agentprolog_skills.pl','prolog/agentprolog_prompt.pl',
     'test/agentprolog_skills_test.pl', 'test/agentprolog_session_test.pl']).
