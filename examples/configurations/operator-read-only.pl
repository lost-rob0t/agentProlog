:- module(agentprolog_example_operator_read_only,[agentprolog_options/1]).

:- use_module('./support').

agentprolog_options([plugin(ReadOnly),plugin(Provider),
    trusted_project(false),allowed_capabilities(Capabilities),
    budget_limits(_{max_model_calls:3,max_tool_calls:6,max_cost_usd:0.05})]) :-
    example_file('read-only-project.pl',ReadOnly),
    example_file('openrouter.pl',Provider),read_only_capabilities(Capabilities).
