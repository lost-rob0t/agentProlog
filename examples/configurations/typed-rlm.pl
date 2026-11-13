:- module(agentprolog_example_typed_rlm,[agentprolog_config/1]).

:- use_module(library(rlm_chain),[openrouter_provider/2]).

agentprolog_config(_{profile:typed_rlm,mode:rlm,
    capabilities:[model(openrouter),context(peek),context(search)],
    runtime_options:[provider(Provider),provider_name(openrouter),planner_max_tokens(512)],
    budget:_{max_model_calls:4,max_tool_calls:4,max_iterations:8,
        max_recursion_depth:1,max_concurrent_subcalls:1}
}) :- openrouter_provider('openrouter/free',Provider).
