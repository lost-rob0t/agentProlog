configuration_entry(operator, 'agentprolog_options/1', '--config FILE').
configuration_entry(product, 'agentprolog_config/1', '--plugin FILE or trusted project config').
configuration_entry(local_swi_pack, 'prolog/agentprolog_plugin.pl', '--package DIR').
skill_representation(native, 'agentprolog_skills([prompt_unit{...}])', inert_data).
skill_compiler('rlm_prompt_compiler', upstream).
permission_invariant(named_agent, narrows_parent_capabilities_and_budget).
permission_invariant(native_skill, no_capability_or_authority_grant).
configuration_runtime_state(project_scoped, fresh_sidecar_process).
projection_limitation(native_skill_or_system_prompt, non_streaming_model_callback).
