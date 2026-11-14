:- begin_tests(agentprolog_army).
:- use_module('../prolog/agentprolog_army').
:- use_module('../prolog/agentprolog_config').
:- use_module('../prolog/agentprolog_session').
:- dynamic planner_called/1.
planner(Request,ok(Output)) :-
 assertz(planner_called(Request)),
 Output=planner_output{plan:plan([final(literal("child answer"))]),
 usage:_{prompt_tokens:1,completion_tokens:1,total_tokens:2,cost:0.0}}.
config(C) :- default_configuration(D),
 put_dict(_{capabilities:[model(openai_compatible)],runtime_options:[subagents(true),
  provider(provider(openai_compatible,[])),provider_name(openai_compatible),
  planner_handler(plunit_agentprolog_army:planner)],
  agents:_{reader:_{mode:rlm},reviewer:_{mode:rlm}}},D,C).
run(C,Names,O) :- rlm_completion:rlm_cancellation_token(T),
 setup_call_cleanup(assertz(agentprolog_session:run_token(test,T)),
 army_execute(C,test,Names,"compare",O),retractall(agentprolog_session:run_token(test,_))).
test(two_real_supervised_children) :-
 retractall(planner_called(_)),config(C),run(C,[reader,reviewer],ok(R)),
 assertion(R.usage.model_calls=:=2),assertion(R.usage.total_tokens=:=4),
 findall(X,planner_called(X),Calls),length(Calls,2),
 assertion(sub_string(R.value,_,_,_,"child answer")).
test(disabled_fails_before_provider) :-
 retractall(planner_called(_)),config(B),put_dict(runtime_options,B,[],C),run(C,[reader],error(_)),
 assertion(\+planner_called(_)).
test(unknown_profile_fails_before_provider) :-
 retractall(planner_called(_)),config(C),run(C,[missing],error(_)),assertion(\+planner_called(_)).
test(oversized_count_rejected) :-
 findall(S,(between(1,33,N),format(string(S),'p~d',[N])),Ps),atomics_to_string(Ps,",",Names),
 string_concat(Names," query",Args),assertion(\+army_request(Args,_,_)).
test(duplicate_profiles_rejected) :- assertion(\+army_request("reader,reader query",_,_)).
test(question_preserves_literals) :- army_request("reader   x  y\n z",[reader],"  x  y\n z").
test(exhausted_share_fails_before_provider) :-
 retractall(planner_called(_)),config(B),put_dict(max_model_calls,B.budget,1,Budget),put_dict(budget,B,Budget,C),
 run(C,[reader,reviewer],error(_)),assertion(\+planner_called(_)).
test(swarm_is_explicit_stub) :- swarm_notice(N),assertion(sub_string(N,_,_,_,"not a swarm")),
 assertion(sub_string(N,_,_,_,"/issues/568")).
test(profile_cannot_expand_capabilities) :-
 retractall(planner_called(_)),config(B),
 put_dict(agents,B,_{reader:_{mode:rlm,capabilities:[model(secret_provider)]}},C),
 run(C,[reader],error(_)),assertion(\+planner_called(_)).
test(write_tools_rejected_before_provider) :-
 retractall(planner_called(_)),config(B),
 Schema=_{name:danger,description:"test",capability:tool(danger),effect:write,
 arguments:_{type:object},result:_{type:object}},
 put_dict(_{tools:[tool(Schema,plunit_agentprolog_army:never)],capabilities:[model(openai_compatible),tool(danger)]},B,C),
 run(C,[reader],error(_)),assertion(\+planner_called(_)).
never(_,_) :- throw(error(should_not_execute,_)).
test(child_quotas_sum_within_parent) :-
 config(C),agentprolog_army:child_config(C,2,reader,Child),
 assertion(Child.budget.max_model_calls*2=<C.budget.max_model_calls),
 assertion(Child.budget.max_total_tokens*2=<C.budget.max_total_tokens),
 assertion(Child.budget.max_cost_usd*2=<C.budget.max_cost_usd),
 assertion(Child.budget.time_limit*2=<C.budget.time_limit),
 assertion(Child.budget.max_recursion_depth=:=0).
bad_planner(_,error(_{kind:fixture_failure})) :- assertz(planner_called(failed)).
test(failed_child_stops_remaining_profiles) :-
 retractall(planner_called(_)),config(B),
 put_dict(agents,B,_{reader:_{mode:rlm,runtime_options:[planner_handler(plunit_agentprolog_army:bad_planner)]},
                    reviewer:_{mode:rlm}},C),
 run(C,[reader,reviewer],error(E)),assertion(E.kind==subagent_failed),
 findall(X,planner_called(X),Calls),assertion(Calls==[failed]).
test(child_can_drop_inherited_write_capability) :-
 config(B),Schema=_{name:danger,description:"test",capability:tool(danger),effect:write,
 arguments:_{type:object},result:_{type:object}},
 put_dict(_{tools:[tool(Schema,plunit_agentprolog_army:never)],
  capabilities:[model(openai_compatible),tool(danger)],
  agents:_{reader:_{mode:rlm,capabilities:[model(openai_compatible)]}}},B,C),
 run(C,[reader],ok(_)).
test(later_failure_retains_paid_usage) :-
 config(B),put_dict(agents,B,_{reader:_{mode:rlm},
 reviewer:_{mode:rlm,runtime_options:[planner_handler(plunit_agentprolog_army:bad_planner)]}},C),
 run(C,[reader,reviewer],error(E)),assertion(E.kind==subagent_failed),
 assertion(E.usage.model_calls>=1),assertion(E.usage.total_tokens>=2).
test(output_overflow_retains_usage) :-
 config(B),put_dict(max_output_bytes,B.budget,300,Budget),put_dict(budget,B,Budget,C),
 run(C,[reader,reviewer],error(E)),assertion(E.kind==budget_exceeded),
 assertion(E.usage.model_calls=:=2),assertion(E.usage.total_tokens=:=4).
test(missing_tool_accounting_is_not_zero) :-
 config(C),run(C,[reader],ok(R)),assertion(\+get_dict(tool_calls,R.usage,_)).
test(progress_survives_exception_unwinding) :-
 P=progress([]),catch((nb_setarg(1,P,[_{usage:_{model_calls:2,total_tokens:4,cost_usd:0.5,cost_known:true}}]),throw(interrupted)),interrupted,true),
 agentprolog_army:progress_usage(P,U),assertion(U.model_calls=:=2),assertion(U.cost_usd=:=0.5).
tasks(Count,Tasks) :- findall(task{id:Id,profile:"reader",question:Q},
 (between(1,Count,N),format(string(Id),'task~d',[N]),format(string(Q),'question-~d',[N])),Tasks).
run_tasks(C,Tasks,O) :- rlm_completion:rlm_cancellation_token(T),
 setup_call_cleanup(assertz(agentprolog_session:run_token(test,T)),
 army_tasks_execute(C,test,Tasks,O),retractall(agentprolog_session:run_token(test,_))).
test(five_distinct_tasks_reuse_one_specialist_with_actual_children) :-
 retractall(planner_called(_)),config(C),tasks(5,Tasks),run_tasks(C,Tasks,ok(R)),
 assertion(R.usage.model_calls=:=5),assertion(R.usage.total_tokens=:=10),
 findall(Request,planner_called(Request),Requests),length(Requests,5),
 forall(member(Task,Tasks),(member(Request,Requests),term_string(Request,Text),sub_string(Text,_,_,_,Task.question))).
test(configured_child_cap_fails_before_provider) :-
 retractall(planner_called(_)),config(B),put_dict(runtime_options,B,[army_max_children(4)|B.runtime_options],C),
 tasks(5,Tasks),run_tasks(C,Tasks,error(_)),assertion(\+planner_called(_)).
test(tasks_json_preserves_literal_question) :-
 army_plan_request("tasks [{\"id\":\"first\",\"profile\":\"reader\",\"question\":\"  code  \"}]",[T]),
 assertion(T.question=="  code  ").
test(duplicate_task_ids_rejected_before_provider) :-
 retractall(planner_called(_)),config(C),tasks(1,[T]),run_tasks(C,[T,T],error(_)),assertion(\+planner_called(_)).
test(task_unknown_fields_rejected) :- tasks(1,[T]),put_dict(capabilities,T,[model(secret)],Bad),
 config(C),run_tasks(C,[Bad],error(_)).
test(larger_batch_still_requires_budget_for_every_child) :-
 retractall(planner_called(_)),config(C),tasks(9,Tasks),run_tasks(C,Tasks,error(_)),assertion(\+planner_called(_)).
test(child_cap_configuration_rejects_zero,[fail]) :- agentprolog_config:runtime_option_key(army_max_children(0),_).
test(child_cap_configuration_rejects_unbounded,[fail]) :- agentprolog_config:runtime_option_key(army_max_children(33),_).
test(compact_report_keeps_answer_provenance_not_nested_traces) :-
 E=_{status:completed,value:"answer",evidence:[receipt],usage:_{model_calls:1},correlation:_{child:child1},trace:[nested],completion:_{huge:true}},
 agentprolog_army:compact_envelope(E,R),assertion(R.value=="answer"),assertion(R.evidence==[receipt]),
 assertion(\+get_dict(trace,R,_)),assertion(\+get_dict(completion,R,_)).
:- end_tests(agentprolog_army).
