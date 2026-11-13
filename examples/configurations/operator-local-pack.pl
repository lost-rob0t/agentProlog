:- module(agentprolog_example_operator_local_pack,[agentprolog_options/1]).

:- use_module('./support').

agentprolog_options([package(Pack),plugin(Coding),plugin(Provider),
    agent(builder),trusted_project(false),allowed_capabilities(Capabilities),
    budget_limits(_{max_model_calls:6,max_tool_calls:12,max_cost_usd:0.10})]) :-
    example_file('../packs/coding/pack.pl',Manifest),file_directory_name(Manifest,Pack),
    example_file('coding-workspace.pl',Coding),
    example_file('openrouter.pl',Provider),coding_capabilities(Capabilities).
