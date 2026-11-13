:- module(agentprolog_example_operator_budget,[agentprolog_options/1]).

:- use_module('./support').

agentprolog_options([plugin(Bounded),agent(brief),trusted_project(false),
    allowed_capabilities([]),budget_ceiling(_{max_model_calls:16,max_total_tokens:65536}),
    budget_limits(_{max_cost_usd:0.05})]) :-
    example_file('bounded-budget.pl',Bounded).
