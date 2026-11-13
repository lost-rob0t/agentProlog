:- module(agentprolog_example_openrouter,[agentprolog_config/1]).

:- use_module(library(rlm_chain),[openrouter_provider/2]).

agentprolog_config(_{runtime_options:[provider(Provider),provider_name(openrouter)]}) :-
    openrouter_provider('openrouter/free', Provider).
