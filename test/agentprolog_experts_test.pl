:- begin_tests(agentprolog_experts).
:- use_module('../prolog/agentprolog_experts').
:- use_module('../prolog/agentprolog_session').
:- use_module('../prolog/agentprolog_config').
:- dynamic called/1.
echo(ask(Text),_,succeeded(Text,[synthetic_evidence])) :- assertz(called(Text)).
contract(C) :- C=expert_contract{id:echo,version:1,accepts:[ask/1],produces:value,
 specialties:[test],requires:[],observations:[],effects:[],fallback:none,
 child_policy:never,limits:expert_limits{},handler:plunit_agentprolog_experts:echo}.
config(C) :- contract(E),expert_question_tool(E,T),default_configuration(D),
 put_dict(_{tools:[T],capabilities:[tool(expert_echo)]},D,C).
test(native_question_calls_actual_symbolic_expert) :-
 config(C),agentprolog_session:native_execute(C,"/ask echo hello",test,ok(R)),
 assertion(sub_string(R.value,_,_,_,"synthetic_evidence")),assertion(called("hello")),
 assertion(R.usage.model_calls=:=0).
test(missing_capability_never_invokes) :-
 retractall(called(_)),config(C0),put_dict(capabilities,C0,[],C),
 agentprolog_session:native_execute(C,"/ask echo no",test,error(_)),assertion(\+called(_)).
test(unknown_expert_does_not_fall_back_to_model) :-
 config(C),agentprolog_session:native_execute(C,"/ask missing hello",test,error(E)),
 assertion(E.kind==unknown_expert).
test(question_is_inert_not_prolog) :-
 config(C),agentprolog_session:native_execute(C,"/ask echo halt.",test,ok(_)),assertion(called("halt.")).
test(zero_tool_budget_never_invokes) :-
 retractall(called(_)),config(C0),put_dict(max_tool_calls,C0.budget,0,B),put_dict(budget,C0,B,C),
 agentprolog_session:native_execute(C,"/ask echo no",test,error(_)),assertion(\+called(_)).
test(effectful_expert_rejected,[throws(error(expert_configuration(_),_))]) :-
 contract(C0),put_dict(effects,C0,[write],C),expert_question_tool(C,_).
test(model_fallback_expert_rejected,[throws(error(expert_configuration(_),_))]) :-
 contract(C0),put_dict(fallback,C0,llm,C),expert_question_tool(C,_).
test(text_output_budget_enforced) :-
 config(C0),put_dict(max_output_bytes,C0.budget,1,B),put_dict(budget,C0,B,C),
 agentprolog_session:native_execute(C,"/ask echo hi",test,error(E)),assertion(E.kind==budget_exceeded).
test(malformed_question_never_enters_model) :-
 config(C),agentprolog_session:native_execute(C,"/ask",test,error(E)),assertion(E.kind==invalid_expert_question).
test(cancelled_token_never_invokes,[throws(error(rlm_cancelled(_),_))]) :-
 retractall(called(_)),config(C),rlm_completion:rlm_cancellation_token(Token),
 setup_call_cleanup(assertz(agentprolog_session:run_token(cancel_test,Token)),
   (rlm_completion:rlm_cancel(Token),agentprolog_session:native_execute(C,"/ask echo no",cancel_test,_)),
   (retractall(agentprolog_session:run_token(cancel_test,_)),assertion(\+called(_)))).
test(required_expert_capability_stays_required) :-
 retractall(called(_)),contract(C0),put_dict(requires,C0,[context(search)],E),expert_question_tool(E,T),
 default_configuration(D),put_dict(_{tools:[T],capabilities:[tool(expert_echo)]},D,C),
 agentprolog_session:native_execute(C,"/ask echo no",test,error(_)),assertion(\+called(_)).
outcome(Raw,_,_,Raw).
non_success(failed,failed(no,[evidence])).
non_success(unknown,unknown(no,[evidence])).
non_success(blocked,blocked(no,[evidence])).
non_success(unsupported,unsupported(no)).
non_success(cancelled,cancelled(token)).
non_success(error,error(problem)).

test(non_success_is_not_completion_or_successful_history,[forall(non_success(Status,Raw))]) :-
 contract(Base),put_dict(handler,Base,plunit_agentprolog_experts:outcome(Raw),E),
 expert_question_tool(E,T),default_configuration(D),
 put_dict(_{tools:[T],capabilities:[tool(expert_echo)],runtime_options:[history_depth(2)]},D,C),
 agentprolog_session:native_execute(C,"/ask echo hello",test,error(Error)),
 assertion(Error.expert_status==Status),assertion(string(Error.report)),
 tmp_file(expert_failed,Dir),
 setup_call_cleanup(make_directory(Dir),
   (agentprolog_session:initialize(Dir,C),
    agentprolog_session:update(_{phase:"running",run_id:"failure",objective:"/ask echo hello"}),
    agentprolog_session:work("failure","/ask echo hello",done),
    agentprolog_session:checkpoint(S),assertion(S.phase=="failed"),
    assertion(\+get_dict(history,S,_)),
    assertion((member(Tool,S.view.tools),get_dict(outcome,Tool,O),get_dict(status,O,"failed")))),
   delete_directory_and_contents(Dir)).

test(question_whitespace_and_code_are_preserved) :-
 Text="  x  = \"a  b\".\n  next(X).  ",
 string_concat("/ask echo ",Text,Command),ask_request(Command,echo,Actual),assertion(Actual==Text),
 config(C),agentprolog_session:native_execute(C,Command,test,ok(_)),assertion(called(Text)).

:- use_module(library(filesex)).
spy_provider(_,_) :- assertz(called(provider)),throw(error(unexpected_provider_call,_)).
test(all_expert_whitespace_dispatches_without_provider,[forall(member(Sep,[9,10,11,12,13,32,160,5760,8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202,8232,8233,8239,8287,12288,65279]))]) :-
 retractall(called(_)),config(Base),
 put_dict(runtime_options,Base,[model_handler(plunit_agentprolog_experts:spy_provider)],C),
 string_codes(Separator,[Sep]),atomics_to_string(["/ask",Separator,"echo hello"],Command),
 assertion(ask_command(Command)),
 agentprolog_session:native_execute(C,Command,test,ok(_)),
 assertion(called("hello")),assertion(\+called(provider)),
 atomics_to_string([Separator,"/ask",Separator],Malformed),
 agentprolog_session:native_execute(C,Malformed,test,error(E)),
 assertion(E.kind==invalid_expert_question),assertion(\+called(provider)).
test(ask_prefix_is_not_a_command) :- assertion(\+ask_command("/asking a question")).
:- end_tests(agentprolog_experts).
