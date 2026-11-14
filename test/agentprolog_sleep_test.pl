:- begin_tests(agentprolog_sleep).
:- use_module('../prolog/agentprolog_sleep').
:- use_module('../prolog/agentprolog_config').
:- use_module('../prolog/agentprolog_history').
:- use_module(library(rlm_completion)).
:- dynamic called/1.
planner(Request,ok(planner_output{plan:plan([final(literal(Data))]),usage:_{prompt_tokens:2,completion_tokens:2,total_tokens:4,cost:0.0}})) :-
 assertz(called(Request)),Data=_{summary:"A suggested summary",decisions:[],facts:[],unresolved:["Check evidence"],entities:[],topics:[],files:[],symbols:[]}.
config(C) :- default_configuration(D),put_dict(_{capabilities:[model(openai_compatible),context(peek)],
 runtime_options:[history_depth(4),provider(provider(openai_compatible,[])),provider_name(openai_compatible),planner_handler(plunit_agentprolog_sleep:planner)]},D,C).
preview(C,H,O) :- rlm_cancellation_token(T),sleep_preview(C,H,T,O).
test(canonical_derivation_is_unverified_and_preserves_sources) :-
 config(C),H=[turn{user:"Evidence input",assistant:"Attributed response"}],preview(C,H,ok(R)),term_string(D,R.value),
 assertion(D.status==unverified),assertion(D.publication==not_published),length(D.source_messages,2),
 length(D.source_refs,2),assertion(D.suggestions.summary=="A suggested summary"),assertion(R.usage.model_calls=:=1).
test(empty_history_no_model) :- retractall(called(_)),config(C),preview(C,[],error(_)),assertion(\+called(_)).
test(private_history_no_model) :- retractall(called(_)),config(C),
 preview(C,[turn{user:"/remember",assistant:"PRIVATE"},turn{user:"/rsi name",assistant:"TEST RESULTS"}],error(_)),assertion(\+called(_)).
test(sleep_output_not_future_context) :- config(C),
 history_record(C,_{objective:"/sleep",history:[]},"SUGGESTED FACT",H),assertion(H==[]).
test(pre_cancelled_no_model) :- retractall(called(_)),config(C),rlm_cancellation_token(T),rlm_cancel(T),
 sleep_preview(C,[turn{user:"test",assistant:"reply"}],T,error(_)),assertion(\+called(_)).
test(output_overflow_preserves_usage) :- config(B),put_dict(max_output_bytes,B.budget,256,Budget),put_dict(budget,B,Budget,C),
 preview(C,[turn{user:"test",assistant:"reply"}],error(E)),assertion(E.usage.model_calls=:=1).
bad_planner(_,ok(planner_output{plan:plan([final(literal("not JSON"))]),usage:_{prompt_tokens:1,completion_tokens:1,total_tokens:2,cost:0.0}})).
test(invalid_suggestion_fails_with_usage) :- config(B),
 select(planner_handler(_),B.runtime_options,planner_handler(plunit_agentprolog_sleep:bad_planner),Options),
 put_dict(runtime_options,B,Options,C),preview(C,[turn{user:"input",assistant:"reply"}],error(E)),
 assertion(E.usage.model_calls=:=1).
test(no_effectful_or_recursive_capabilities) :-
 include(agentprolog_sleep:sleep_capability,[model(openai_compatible),context(peek),tool(write),rlm,parallel,context(delete)],Caps),
 assertion(Caps==[model(openai_compatible),context(peek)]).
test(missing_model_grant_no_provider_call) :- retractall(called(_)),config(B),put_dict(capabilities,B,[],C),
 preview(C,[turn{user:"input",assistant:"reply"}],error(E)),assertion(E.kind==capability_error),assertion(\+called(_)).
test(wrong_model_grant_no_provider_call) :- retractall(called(_)),config(B),put_dict(capabilities,B,[model(other)],C),
 preview(C,[turn{user:"input",assistant:"reply"}],error(E)),assertion(E.kind==capability_error),assertion(\+called(_)).
:- end_tests(agentprolog_sleep).
