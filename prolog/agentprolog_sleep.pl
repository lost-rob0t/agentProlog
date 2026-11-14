:- module(agentprolog_sleep,[sleep_preview/4]).
/** Native, read-only consolidation preview using canonical warm derivation.
    Generated fields are attributed model suggestions, never admitted KB facts. */
:- use_module(library(rlm_conversation)).
:- use_module(library(rlm_conversation_warm)).
:- use_module(library(rlm_tool)).
:- use_module(library(crypto)).
:- use_module(library(option)).
:- use_module('./agentprolog_history').
:- use_module('./agentprolog_prompt').

sleep_preview(Config,History,Token,Outcome) :-
    history_messages(Config,History,Messages),
    (Messages==[] -> Outcome=error(_{kind:invalid_request,phase:runtime})
    ; \+sleep_model_granted(Config) -> Outcome=error(_{kind:capability_error,phase:runtime})
    ; setup_call_cleanup(conversation_store_open(memory,ok(Store)),
       preview_in_store(Store,Config,Messages,Token,Outcome),conversation_store_close(Store,_))).
preview_in_store(Store,Config,Messages,Token,Outcome) :-
    conversation_create(Store,[],ok(Conversation)),
    forall(member(M,Messages),conversation_append(Conversation,message(M.role,M.content),ok(_))),
    length(Messages,Count),term_string(Messages,Source,[quoted(true),ignore_ops(true)]),
    crypto_data_hash(Source,Hash,[algorithm(sha256)]),
    include(sleep_capability,Config.capabilities,Caps),
    Calls is min(3,Config.budget.max_model_calls),
    put_dict(_{max_model_calls:Calls,max_tool_calls:0,max_recursion_depth:0,max_concurrent_subcalls:1},Config.budget,Budget),
    put_dict(_{history:[],tools:[],capabilities:Caps},Config,Narrow),
    setup_call_cleanup(tool_registry_create(Registry),
      (prepare_runtime_options(Narrow,Registry,"Derive a non-authoritative consolidation preview",Prepared),
       append([budget(Budget),capabilities(Caps),tool_registry(Registry),cancel_token(Token)],Prepared,Options),
       conversation_warm_derive(Conversation,range(1,Count),[completion_options(Options)],Result)),
      tool_registry_destroy(Registry)),
    (Result=ok(Warm) ->
      findall(Size,(member(V,Warm.variants),Size=_{kind:V.kind,tokens:V.tokens,token_count:V.token_count}),Sizes),
      Report=_{kind:consolidation_preview,status:unverified,coverage:bounded_public_history_projection,
        source_digest:Hash,source_messages:Messages,
        source_refs:Warm.source_refs,suggestions:Warm.generated,variants:Sizes,
        publication:not_published,limitations:[no_kb_promotion,no_source_deletion,no_automatic_context_replacement]},
      term_string(Report,Text,[quoted(true)]),string_bytes(Text,Bytes,utf8),length(Bytes,N),
      (N=<Config.budget.max_output_bytes -> Outcome=ok(_{value:Text,usage:Warm.generation.usage})
       ; Outcome=error(_{kind:budget_exceeded,phase:runtime,usage:Warm.generation.usage}))
    ; Result=error(Error),
      (get_dict(generation,Error,G),get_dict(usage,G,Usage)
       -> Outcome=error(_{kind:invalid_request,phase:runtime,usage:Usage})
       ; Outcome=error(_{kind:invalid_request,phase:runtime}))).
sleep_capability(model(_)).
sleep_capability(context(peek)).

sleep_model_granted(Config) :-
    option(provider(Provider),Config.runtime_options,provider(openrouter,[])),
    Provider=provider(Default,_),option(provider_name(Name),Config.runtime_options,Default),
    memberchk(model(Name),Config.capabilities).
