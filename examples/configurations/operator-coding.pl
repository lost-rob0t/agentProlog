:- module(agentprolog_example_operator_coding,[agentprolog_options/1]).

:- use_module('./support').

agentprolog_options([plugin(Coding),plugin(Provider),plugin(Skills),
    plugin(Policy),trusted_project(false),allowed_capabilities(Capabilities),
    budget_limits(_{max_model_calls:6,max_tool_calls:12,max_cost_usd:0.10})]) :-
    example_file('coding-workspace.pl',Coding),example_file('openrouter.pl',Provider),
    example_file('native-skills.pl',Skills),example_file('artifact-hook.pl',Policy),
    coding_capabilities(Capabilities).
