:- module(agentprolog_example_local_compatible,[agentprolog_config/1]).

:- use_module(library(rlm_chain),[openai_compatible_provider/4]).

agentprolog_config(_{runtime_options:[provider(Provider),provider_name(openai_compatible)]}) :-
    (getenv('AGENTPROLOG_EXAMPLE_LOCAL_MODEL', Model), Model \== '' -> true
     ; throw(error(existence_error(environment_variable,'AGENTPROLOG_EXAMPLE_LOCAL_MODEL'),_))),
    openai_compatible_provider('http://127.0.0.1:1234/v1/chat/completions',
        none, Model, Provider).
