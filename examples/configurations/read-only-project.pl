:- module(agentprolog_example_read_only_project,[agentprolog_config/1]).

:- use_module('./support').

agentprolog_config(_{profile:read_only_project,tools:Tools,capabilities:Capabilities}) :-
    read_only_tools(Tools), read_only_capabilities(Capabilities).
