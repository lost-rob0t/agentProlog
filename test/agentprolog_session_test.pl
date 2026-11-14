:- begin_tests(agentprolog_session).
:- use_module('../prolog/agentprolog_session').
:- use_module(library(filesex)).

model(_, ok(Response)) :-
    Response = model_response{provider:fake,requested_model:fake,selected_model:fake,
      response_id:"fixture",assistant:message{role:assistant,content:"Synthetic hello",tool_calls:[],reasoning:"",reasoning_details:[]},
      text:"Synthetic hello",tool_calls:[],reasoning:"",reasoning_details:[],finish_reason:stop,
      usage:usage{present:true,prompt_tokens:2,completion_tokens:1,total_tokens:3,cost:0.0},
      metadata:provider_metadata{provider:fake,http_status:200,response_received:true}}.
config(C) :- C=_{profile:"generic-test",tools:[],capabilities:[],hooks:_{},
    budget:_{max_model_calls:2,max_tool_calls:0,max_iterations:2,time_limit:3},
    runtime_options:[provider(provider(openai_compatible,[])),provider_name(openai_compatible),model_handler(plunit_agentprolog_session:model)]}.

test(native_model_io_without_tools) :-
    config(C), agentprolog_session:native_execute(C,"hello","test",Outcome),
    assertion(Outcome=ok(_)), Outcome=ok(Result), assertion(Result.value=="Synthetic hello").

test(checkpoint_restores_identity_and_interrupted_truth) :-
    tmp_file(agentprolog_session,Directory),
    setup_call_cleanup(make_directory(Directory),
      (config(C), agentprolog_session:initialize(Directory,C),
       agentprolog_session:checkpoint(S),
       agentprolog_session:update(_{phase:"running",run_id:"test"}),
       agentprolog_session:initialize(Directory,C),
       agentprolog_session:checkpoint(After),
       assertion(After.session_id==S.session_id),
       assertion(After.view.run.outcome.status=="interrupted")),
      delete_directory_and_contents(Directory)).

test(binding_ignores_anonymous_dict_tag_sharing) :-
    A=Tag{value:1}, B=Tag{value:2},
    agentprolog_session:config_binding(_{a:A,b:B},First),
    agentprolog_session:config_binding(_{a:_{value:1},b:_{value:2}},Second),
    assertion(First==Second).

test(configuration_change_rejected) :-
    tmp_file(agentprolog_binding,Directory),
    setup_call_cleanup(make_directory(Directory),
      (config(C),agentprolog_session:initialize(Directory,C),
       put_dict(profile,C,"different",Other),
       catch(agentprolog_session:initialize(Directory,Other),Error,true),
       assertion(Error=error(session_configuration_mismatch,_))),
      delete_directory_and_contents(Directory)).

bad_hook(_, _) :- fail.
test(failing_artifact_hook_finishes_failed) :-
    tmp_file(agentprolog_hook,Directory),
    setup_call_cleanup(make_directory(Directory),
      (config(C0),put_dict(hooks,C0,_{validate_artifact:plunit_agentprolog_session:bad_hook},C),
       agentprolog_session:initialize(Directory,C),
       agentprolog_session:update(_{phase:"running",run_id:"hook-test"}),
       agentprolog_session:work("hook-test","hello",done),
       agentprolog_session:checkpoint(S), assertion(S.phase=="failed")),
      delete_directory_and_contents(Directory)).

rlm_model(Request, ok(Response)) :-
    model(Request,ok(Base)), Text="{\"mode\":\"direct\",\"answer\":\"RLM orchestration hello\"}",
    put_dict(_{text:Text,assistant:message{role:assistant,content:Text,tool_calls:[],reasoning:"",reasoning_details:[]}},Base,Response).
test(rlm_mode_uses_canonical_completion) :-
    config(Base), put_dict(_{mode:rlm,capabilities:[model(openai_compatible)],runtime_options:[provider(provider(openai_compatible,[])),provider_name(openai_compatible),planner_handler(plunit_agentprolog_session:rlm_model)]},Base,C),
    agentprolog_session:native_execute(C,"hello","rlm-test",Outcome),
    assertion(Outcome=ok(_)), Outcome=ok(Result),
    assertion(Result.value=="RLM orchestration hello"), assertion(is_dict(Result,completion_result)).

test(safe_error_projection_drops_raw_details) :-
    agentprolog_session:safe_failure(error(_{kind:transport_error,phase:provider,detail:"SECRET",message:"SECRET"}),Failure),
    assertion(Failure.code=="transport_error"), assertion(Failure.stage=="provider"),
    term_string(Failure,Text), assertion(\+sub_string(Text,_,_,_,"SECRET")).
test(model_argv_is_explicit_capability) :-
    agentprolog_session:cli_options(['--allow-model',openrouter],Options),
    assertion(Options==[allow_cap(model(openrouter))]).

model_with_system(Request,Outcome) :-
    findall(Text,(member(M,Request.messages),M.role==system,Text=M.content),Texts),
    atomics_to_string(Texts," ",All),assertion(sub_string(All,_,_,_,"CONFIGURED_SYSTEM_MARKER")),
    model(Request,Outcome).
test(configured_instructions_reach_actual_canonical_model_callback) :-
    config(C0),agentprolog_config:default_configuration(Defaults),
    put_dict(C0.budget,Defaults.budget,Budget),
    put_dict(_{budget:Budget,runtime_options:[provider(provider(openai_compatible,[])),
      provider_name(openai_compatible),model_handler(plunit_agentprolog_session:model_with_system),
      system_prompt("CONFIGURED_SYSTEM_MARKER")]},C0,C),
    agentprolog_session:native_execute(C,"hello","configured-system",ok(_)).

test(failed_run_retains_actual_usage) :-
    tmp_file(agentprolog_failed_usage,Directory),
    setup_call_cleanup(make_directory(Directory),
      (config(C),agentprolog_session:initialize(Directory,C),
       agentprolog_session:update(_{phase:"running",run_id:"failed-usage"}),
       agentprolog_session:complete("failed-usage",error(_{kind:budget_exceeded,phase:budget,
         usage:_{model_calls:2,total_tokens:20,cost_usd:0.01,cost_known:true}})),
       agentprolog_session:checkpoint(S),assertion(S.phase=="failed"),
       assertion(S.view.usage.cost_usd=:=0.01),assertion(S.view.usage.total_tokens==20)),
      delete_directory_and_contents(Directory)).

history_model(Request, Outcome) :-
    (member(M,Request.messages),M.role==user,M.content=="follow up"
    -> assertion((member(U,Request.messages),U.role==user,U.content=="FIRST_TURN_MARKER")),
       assertion((member(A,Request.messages),A.role==assistant,A.content=="Synthetic hello"))
    ; true), model(Request,Outcome).

history_config(C) :-
    agentprolog_config:default_configuration(D), config(Base),
    put_dict(Base,D,C0),
    put_dict(_{budget:D.budget,runtime_options:[history_depth(2),provider(provider(openai_compatible,[])),
      provider_name(openai_compatible),model_handler(plunit_agentprolog_session:history_model)]},C0,C).

test(two_native_turns_project_history_after_checkpoint_restart) :-
    tmp_file(agentprolog_history,Directory),
    setup_call_cleanup(make_directory(Directory),
      (history_config(C),agentprolog_session:initialize(Directory,C),
       agentprolog_session:update(_{phase:"running",run_id:"first",objective:"FIRST_TURN_MARKER"}),
       agentprolog_session:work("first","FIRST_TURN_MARKER",done),
       agentprolog_session:checkpoint(First),assertion(First.phase=="complete"),
       assertion(First.history==[turn{user:"FIRST_TURN_MARKER",assistant:"Synthetic hello"}]),
       agentprolog_session:initialize(Directory,C),
       agentprolog_session:update(_{phase:"running",run_id:"second",objective:"follow up"}),
       agentprolog_session:work("second","follow up",done),
       agentprolog_session:checkpoint(Second),assertion(Second.phase=="complete"),
       assertion(length(Second.history,2))),
      delete_directory_and_contents(Directory)).

test(private_memory_excluded_from_record_and_legacy_projection) :-
 history_config(C),Old=[turn{user:"/remember PRIVATE_WRITE",assistant:"saved"},
 turn{user:"/remember\u00a0",assistant:"PRIVATE_READ"}],
 agentprolog_history:history_record(C,_{objective:"/remember NEW_PRIVATE",history:Old},"saved",H),assertion(H==[]),
 agentprolog_history:history_messages(C,Old,Messages),assertion(Messages==[]),
 agentprolog_history:history_record(C,_{objective:"public",history:Old},"public answer",Public),
 assertion(Public==[turn{user:"public",assistant:"public answer"}]).

test(history_disabled_by_default) :-
    config(C),agentprolog_history:history_messages(C,[turn{user:"SECRET",assistant:"answer"}],M),
    assertion(M==[]),agentprolog_history:history_record(C,_{objective:"user"},"answer",H),assertion(H==[]).

test(history_depth_bounds_and_binding) :-
    history_config(C),agentprolog_session:config_binding(C,B1),
    select(history_depth(2),C.runtime_options,history_depth(1),Opts),
    put_dict(runtime_options,C,Opts,C2),agentprolog_session:config_binding(C2,B2),assertion(B1\==B2),
    agentprolog_history:history_record(C2,_{objective:"new",history:[turn{user:"old",assistant:"answer"}]},"reply",H),
    assertion(H==[turn{user:"new",assistant:"reply"}]),
    assertion(\+agentprolog_config:valid_runtime_options([history_depth(33)])).

test(history_budget_drops_whole_pairs_without_promoting_roles) :-
    history_config(C),put_dict(max_total_tokens,C.budget,4,B),put_dict(budget,C,B,Small),
    agentprolog_history:history_messages(Small,[turn{user:"a longer question",assistant:"a longer answer"}],M),
    assertion(M==[]).

test(failed_run_does_not_enter_completed_history) :-
    tmp_file(agentprolog_history_failed,Directory),
    setup_call_cleanup(make_directory(Directory),
      (history_config(C),agentprolog_session:initialize(Directory,C),
       agentprolog_session:update(_{phase:"running",run_id:"bad",objective:"not evidence"}),
       agentprolog_session:finish(_{status:"failed"}),agentprolog_session:checkpoint(S),
       assertion(\+get_dict(history,S,_))),delete_directory_and_contents(Directory)).

test(restored_history_rejects_injected_fields,[throws(error(invalid_session_history,_))]) :-
    history_config(C),agentprolog_history:history_validate(C,[_{user:"x",assistant:"y",role:system}]).

test(rlm_mode_receives_same_native_history_projection) :-
    history_config(Base),
    put_dict(_{mode:rlm,capabilities:[model(openai_compatible)],
      history:[turn{user:"FIRST_TURN_MARKER",assistant:"Synthetic hello"}],
      runtime_options:[history_depth(2),provider(provider(openai_compatible,[])),
        provider_name(openai_compatible),planner_handler(plunit_agentprolog_session:history_planner)]},Base,C),
    agentprolog_session:native_execute(C,"follow up","history-rlm",ok(_)).
history_planner(Request,Outcome) :-
    assertion(memberchk(message{role:user,content:"FIRST_TURN_MARKER"},Request.messages)),
    rlm_model(Request,Outcome).

:- end_tests(agentprolog_session).
