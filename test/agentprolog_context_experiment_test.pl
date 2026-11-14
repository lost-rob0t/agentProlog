:- begin_tests(agentprolog_context_experiment).
:- use_module('../prolog/agentprolog_context_experiment').
:- use_module('../prolog/agentprolog_config').
:- use_module(library(filesex)).
:- use_module(library(rlm_tool)).
setup(P,C) :- tmp_file(context_project,P),make_directory(P),
 forall(member(N,[a,b]),(directory_file_path(P,N,F),setup_call_cleanup(open(F,write,S),write(S,'12345678'),close(S)))),
 Spec=spec{id:demo,token_budget:3,files:[file{id:a,path:"a",mandatory:false,utility:1},file{id:b,path:"b",mandatory:false,utility:10}]},
 context_experiment_tool(P,Spec,Tool),default_configuration(D),
 put_dict(_{project:P,tools:[Tool],capabilities:[tool(context_experiment_demo)]},D,C).
run(C,R) :- context_experiment_execute(C,test,demo,ok(Out)),term_string(R,Out.value).
test(real_optimizer_improves_configured_utility_only,[setup(setup(P,C)),cleanup(delete_directory_and_contents(P))]) :-
 run(C,R),assertion(R.baseline.selected==[a]),assertion(R.candidate.selected==[b]),assertion(R.delta=:=9),
 assertion(R.decision==hold),assertion(R.score==configured_utility_not_accuracy),length(R.source_evidence,2).
test(mandatory_source_cannot_be_dropped,[setup(setup(P,C)),cleanup(delete_directory_and_contents(P))]) :-
 C.tools=[tool(_,agentprolog_context_experiment:native_only(_,S))],S.files=[A,B],put_dict(mandatory,A,true,Required),
 put_dict(files,S,[Required,B],Spec),context_experiment_tool(P,Spec,Tool),put_dict(tools,C,[Tool],Config),
 run(Config,R),assertion(R.candidate.selected==[a]),assertion(R.delta=:=0).
test(ordinary_tool_fails_closed,[setup(setup(P,C)),cleanup(delete_directory_and_contents(P))]) :-
 setup_call_cleanup(tool_registry_create(R),
 (register_config_tools(C,R),tool_invoke_execute(R,C.capabilities,context_experiment_demo,_{},[],Result),assertion(Result.outcome=error(_))),tool_registry_destroy(R)).
test(scope_mismatch_rejected,[setup(setup(P,C)),cleanup(delete_directory_and_contents(P))]) :-
 put_dict(project,C,other,X),context_experiment_execute(X,test,demo,error(_)).
test(native_budget_rejected,[setup(setup(P,C)),cleanup(delete_directory_and_contents(P))]) :-
 put_dict(max_native_calls_per_batch,C.budget,1,B),put_dict(budget,C,B,X),context_experiment_execute(X,test,demo,error(E)),assertion(E.kind==budget_exceeded).
test(changed_source_detected,[setup(setup(P,_)),cleanup(delete_directory_and_contents(P)),throws(error(stale_context_source,_))]) :-
 agentprolog_context_experiment:read_source(P,file{id:a,path:"a",mandatory:false,utility:1},S),
 directory_file_path(P,a,F),setup_call_cleanup(open(F,write,O),write(O,changed),close(O)),
 agentprolog_context_experiment:revalidate(P,S).
test(path_escape_rejected,[setup(setup(P,C)),cleanup(delete_directory_and_contents(P))]) :-
 C.tools=[tool(_,agentprolog_context_experiment:native_only(_,S))],S.files=[A,B],put_dict(path,A,"../outside",Bad),
 put_dict(files,S,[Bad,B],Spec),context_experiment_tool(P,Spec,T),put_dict(tools,C,[T],X),
 context_experiment_execute(X,test,demo,error(_)).
test(aliases_cannot_double_count_same_source,[setup(setup(P,C)),cleanup(delete_directory_and_contents(P))]) :-
 C.tools=[tool(_,agentprolog_context_experiment:native_only(_,S))],S.files=[A,B],put_dict(path,B,"a",Alias),
 put_dict(files,S,[A,Alias],Spec),context_experiment_tool(P,Spec,T),put_dict(tools,C,[T],X),
 context_experiment_execute(X,test,demo,error(_)).
test(missing_capability_rejected,[setup(setup(P,C)),cleanup(delete_directory_and_contents(P))]) :-
 put_dict(capabilities,C,[],X),context_experiment_execute(X,test,demo,error(_)).
test(infeasible_mandatory_set_fails,[setup(setup(P,C)),cleanup(delete_directory_and_contents(P))]) :-
 C.tools=[tool(_,agentprolog_context_experiment:native_only(_,S))],S.files=[A,B],
 put_dict(mandatory,A,true,RA),put_dict(mandatory,B,true,RB),put_dict(files,S,[RA,RB],Spec),
 context_experiment_tool(P,Spec,T),put_dict(tools,C,[T],X),context_experiment_execute(X,test,demo,error(_)).
:- end_tests(agentprolog_context_experiment).
