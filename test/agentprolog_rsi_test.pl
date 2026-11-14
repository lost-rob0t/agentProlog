:- begin_tests(agentprolog_rsi).
:- use_module('../prolog/agentprolog_rsi').
:- use_module(library(rlm_tool)).
:- use_module('../prolog/agentprolog_config').
contract(Id,H,expert_contract{id:Id,version:1,accepts:[ask/1],produces:value,
 specialties:[fixture],requires:[],observations:[],effects:[],fallback:none,
 child_policy:never,limits:expert_limits{},handler:H}).
:- dynamic expert_ran/0.
baseline(ask(_),_,succeeded("wrong",[])) :- assertz(expert_ran).
candidate(ask(Q),_,succeeded(Q,[])) :- assertz(expert_ran).
spec(S) :- contract(baseline,plunit_agentprolog_rsi:baseline,B),contract(candidate,plunit_agentprolog_rsi:candidate,C),
 S=spec{id:echo,version:1,baseline:B,candidate:C,cases:[case{id:a,input:"yes",expected:"yes",origin:fixture_a},case{id:b,input:"no",expected:"no",origin:fixture_b}]}.
report(S,Text) :- working_directory(P,P),rsi_evaluation_tool(P,S,Tool),default_configuration(D),
 put_dict(_{tools:[Tool],capabilities:[tool(rsi_echo)]},D,C),
 rsi_execute(C,unused,echo,P,ok(R)),Text=R.value.
test(measured_improvement_is_not_promotion) :-
 spec(S),report(S,T),term_string(R,T),assertion(R.delta=:=1),assertion(R.decision==hold),
 assertion(R.baseline.mean_quality=:=0),assertion(R.candidate.mean_quality=:=1),assertion(R.candidate.totals.model_calls=:=0).
test(regression_stays_held) :- spec(S),put_dict(_{baseline:S.candidate,candidate:S.baseline},S,Bad),
 report(Bad,T),term_string(R,T),assertion(R.delta=:= -1),assertion(R.regressions==[a,b]),assertion(R.decision==hold).
test(empty_evidence_rejected,[throws(error(invalid_rsi_evaluation,_))]) :-
 spec(S),put_dict(cases,S,[],E),report(E,_).
test(duplicate_cases_rejected,[throws(error(invalid_rsi_evaluation,_))]) :-
 spec(S),S.cases=[C|_],put_dict(cases,S,[C,C],E),report(E,_).
test(authority_rejected,[throws(error(invalid_rsi_evaluation,_))]) :-
 spec(S),put_dict(requires,S.candidate,[model(secret)],C),put_dict(candidate,S,C,E),report(E,_).
test(asymmetric_limits_rejected,[throws(error(invalid_rsi_evaluation,_))]) :-
 spec(S),put_dict(limits,S.candidate,expert_limits{max_depth:2},C),put_dict(candidate,S,C,E),report(E,_).
test(snapshot_changes_with_evidence) :- spec(S),report(S,T),term_string(A,T),
 put_dict(version,S,2,V),report(V,U),term_string(B,U),assertion(A.snapshot\==B.snapshot).
blocked(ask(_),_,blocked(no_evidence,[])).
test(blocked_candidate_not_scored_as_success) :- spec(S),
 put_dict(handler,S.candidate,plunit_agentprolog_rsi:blocked,C),put_dict(candidate,S,C,Spec),
 report(Spec,T),term_string(R,T),assertion(R.candidate.mean_quality=:=0),assertion(R.decision==hold),
 forall(member(Case,R.candidate.cases),assertion(Case.details.expert_status==blocked)).
loop(ask(_),_,_) :- repeat,fail.
test(inference_exhaustion_never_promotes) :- spec(S),
 put_dict(handler,S.candidate,plunit_agentprolog_rsi:loop,C),put_dict(candidate,S,C,Spec),
 report(Spec,T),term_string(R,T),assertion(R.candidate.mean_quality=:=0),assertion(R.decision==hold).
test(no_capability_no_evaluation) :-
 spec(S),working_directory(P,P),rsi_evaluation_tool(P,S,Tool),default_configuration(D),
 put_dict(_{tools:[Tool],capabilities:[]},D,C),
 setup_call_cleanup(tool_registry_create(R),
  (register_config_tools(C,R),rsi_execute(C,R,echo,P,error(_))),tool_registry_destroy(R)).
test(project_scope_mismatch_rejected) :-
 spec(S),working_directory(P,P),rsi_evaluation_tool(P,S,Tool),default_configuration(D),
 put_dict(_{tools:[Tool],capabilities:[tool(rsi_echo)]},D,C),
 rsi_execute(C,unused,echo,other_project,error(_)).
test(parent_native_budget_checked) :-
 spec(S),working_directory(P,P),rsi_evaluation_tool(P,S,Tool),default_configuration(D),
 put_dict(max_native_calls_per_batch,D.budget,1,B),
 put_dict(_{tools:[Tool],capabilities:[tool(rsi_echo)],budget:B},D,C),
 rsi_execute(C,unused,echo,P,error(E)),assertion(E.kind==budget_exceeded).
test(ordinary_tool_cannot_bypass_native_guards) :-
 retractall(expert_ran),spec(S),working_directory(P,P),rsi_evaluation_tool(P,S,Tool),default_configuration(D),
 put_dict(_{tools:[Tool],capabilities:[tool(rsi_echo)]},D,C),
 setup_call_cleanup(tool_registry_create(R),
  (register_config_tools(C,R),tool_invoke_execute(R,C.capabilities,rsi_echo,_{},[],Result),
   assertion(Result.outcome=error(_)),assertion(\+expert_ran)),tool_registry_destroy(R)).
:- end_tests(agentprolog_rsi).
