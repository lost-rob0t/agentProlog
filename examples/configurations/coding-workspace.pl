:- module(agentprolog_example_coding_workspace,[agentprolog_config/1]).

:- use_module('./support').

agentprolog_config(_{profile:coding_workspace,tools:Tools,capabilities:Capabilities}) :-
    coding_tools(Tools), coding_capabilities(Capabilities).
