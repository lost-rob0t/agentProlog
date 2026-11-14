:- begin_tests(agentprolog_learning).
:- use_module('../prolog/agentprolog_learning').
:- use_module('../prolog/agentprolog_config').
:- use_module(library(rlm_tool)).
spec(spec{id:demo,discovery:[example{id:train,input:"  HELLO  ",expected:"hello",origin:training}],
 evaluation:[example{id:test,input:" WORLD ",expected:"world",origin:heldout}]}).
config(S,C) :- working_directory(P,P),learning_experiment_tool(P,S,T),default_configuration(D),
 put_dict(_{project:P,tools:[T],capabilities:[tool(learn_demo)]},D,C).
report(S,R) :- config(S,C),learn_execute(C,demo,ok(O)),term_string(R,O.value).
test(unique_discovery_candidate_is_evaluated_not_promoted) :- spec(S),report(S,R),
 assertion(R.candidate.primitive==trim_lower),assertion(R.status==evaluated_proposal),
 assertion(R.evaluation.delta=:=1),assertion(R.decision==hold).
test(heldout_counterexample_rejects_candidate) :- spec(S),
 put_dict(evaluation,S,[example{id:counter,input:" WORLD ",expected:"different",origin:heldout}],Bad),report(Bad,R),
 assertion(R.candidate.primitive==trim_lower),assertion(R.status==rejected_on_evaluation),assertion(R.candidate.lifecycle==rejected),assertion(R.decision==hold).
test(evaluation_cannot_resolve_discovery_tie) :- spec(S),
 put_dict(discovery,S,[example{id:train,input:"plain",expected:"plain",origin:training}],Tie),report(Tie,R),
 assertion(R.status==ambiguous_discovery),assertion(R.candidate==none),assertion(R.evaluation==not_run).
test(overlapping_origin_rejected,[throws(error(invalid_learning_experiment,_))]) :- spec(S),
 put_dict(evaluation,S,[example{id:test,input:"OTHER",expected:"other",origin:training}],Bad),config(Bad,_).
test(overlapping_input_rejected,[throws(error(invalid_learning_experiment,_))]) :- spec(S),
 put_dict(evaluation,S,[example{id:test,input:"  HELLO  ",expected:"hello",origin:heldout}],Bad),config(Bad,_).
test(empty_evaluation_rejected,[throws(error(invalid_learning_experiment,_))]) :- spec(S),put_dict(evaluation,S,[],Bad),config(Bad,_).
test(no_capability_no_learning) :- spec(S),config(S,C),put_dict(capabilities,C,[],X),learn_execute(X,demo,error(_)).
test(native_budget_checked) :- spec(S),config(S,C),put_dict(max_native_calls_per_batch,C.budget,1,B),put_dict(budget,C,B,X),
 learn_execute(X,demo,error(E)),assertion(E.kind==budget_exceeded).
test(ordinary_tool_cannot_bypass_guards) :- spec(S),config(S,C),
 setup_call_cleanup(tool_registry_create(R),
 (register_config_tools(C,R),tool_invoke_execute(R,C.capabilities,learn_demo,_{},[],O),assertion(O.outcome=error(_))),tool_registry_destroy(R)).
test(primitive_keeps_internal_whitespace_and_never_executes_text) :-
 normalizer(trim_lower,ask("  A  B :- HALT.  "),_,succeeded("a  b :- halt.",_)).
test(proposed_recipe_can_be_applied_without_code_generation) :- spec(S),report(S,R),
 normalizer(R.candidate.primitive,ask(" NEXT INPUT "),_,succeeded("next input",_)),assertion(R.candidate.lifecycle==proposed).
test(project_scope_checked) :- spec(S),config(S,C),put_dict(project,C,wrong,X),learn_execute(X,demo,error(_)).
:- end_tests(agentprolog_learning).
