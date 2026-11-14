:- module(agentprolog_learning,[learning_experiment_tool/3,learn_execute/3,normalizer/4]).
/** Finite-catalog symbolic hypothesis selection, never automatic admission.
    Fixed string primitives only; examples never become executable Prolog. */
:- use_module(library(rlm_expert)).
:- use_module(library(rlm_benchmark)).
:- use_module(library(rlm_tool)).
:- use_module(library(crypto)).
:- use_module('./agentprolog_commands').
primitives([identity,trim,lower,trim_lower]).
learning_experiment_tool(Project,Spec,tool(Schema,agentprolog_learning:native_only(Root,Spec))) :-
 valid_spec(Spec),absolute_file_name(Project,Root,[file_type(directory),access(read)]),
 atom_concat(learn_,Spec.id,Name),
 Schema=tool_schema{name:Name,description:"Native-only finite normalizer hypothesis selection; no promotion",
 capability:tool(Name),effect:read,arguments:_{type:object,additional_properties:false,properties:_{}},
 result:_{type:object,required:[report],additional_properties:false,properties:_{report:_{type:string}}},
 limits:_{time_limit:5.0,max_output_bytes:65536}}.
native_only(_,_,_,_) :- throw(error(native_learning_command_required,_)).
valid_spec(S) :- ground(S),dict_pairs(S,_,[discovery-D,evaluation-E,id-Id]),atom(Id),
 valid_examples(D),valid_examples(E),
 % Distinct labels are not an independence proof; exact overlaps are forbidden.
 forall((member(A,D),member(B,E)),(A.input\==B.input,A.origin\==B.origin)),!.
valid_spec(_) :- throw(error(invalid_learning_experiment,_)).
valid_examples(Examples) :- is_list(Examples),length(Examples,N),between(1,4,N),
 forall(member(E,Examples),(dict_pairs(E,_,[expected-Out,id-Id,input-In,origin-Origin]),atom(Id),atom(Origin),
  string(In),string(Out),string_length(In,L),L>0,L=<4096,string_length(Out,M),M=<4096)),
 findall(Id,(member(E,Examples),Id=E.id),Ids),sort(Ids,U),length(U,N),
 findall(In,(member(E,Examples),In=E.input),Inputs),sort(Inputs,UI),length(UI,N).
learn_execute(Config,Name,Outcome) :-
 atom_concat(learn_,Name,ToolName),
 (member(tool(Schema,agentprolog_learning:native_only(Root,Spec)),Config.tools),Schema.name==ToolName,Root==Config.project
 -> length(Spec.discovery,D),length(Spec.evaluation,E),Calls is 4*D+2*E,
    ((Config.budget.max_tool_calls<1;Calls>Config.budget.max_native_calls_per_batch)
     -> Outcome=error(_{kind:budget_exceeded,phase:tool})
     ; setup_call_cleanup(tool_registry_create(R),
        (tool_register(R,Schema,agentprolog_learning:evaluate(Root,Spec),ok(_)),
         tool_invoke_execute(R,Config.capabilities,ToolName,_{},[],Result)),tool_registry_destroy(R)),
       (Result.outcome=ok(V) -> Text=V.value.report,string_bytes(Text,Bytes,utf8),length(Bytes,N),
        (N=<Config.budget.max_output_bytes -> Outcome=ok(_{value:Text,usage:_{model_calls:0,total_tokens:0,tool_calls:1}})
         ; Outcome=error(_{kind:budget_exceeded,phase:tool})) ; Outcome=Result.outcome))
 ; Outcome=error(_{kind:invalid_request,phase:tool})).
evaluate(Root,Spec,_,_{report:Text}) :-
 setup_call_cleanup(expert_registry_create([],R),
  (primitives(Ps),maplist(register_primitive(R),Ps),
   maplist(score(R,Spec.discovery),Ps,Discovery),
   % Select only from discovery outcomes. Evaluation cannot break a tie.
   findall(P,(member(S,Discovery),S.mean_quality=:=1,P=S.suite),Perfect),
   (Perfect=[Chosen] -> score(R,Spec.evaluation,Chosen,CandidateScore),score(R,Spec.evaluation,identity,Baseline),
     Delta is CandidateScore.mean_quality-Baseline.mean_quality,
     Candidate=_{primitive:Chosen,version:1,lifecycle:Lifecycle},
     Evaluation=_{candidate:CandidateScore,baseline:Baseline,delta:Delta},
     (CandidateScore.mean_quality=:=1 -> Status=evaluated_proposal,Lifecycle=proposed
      ; Status=rejected_on_evaluation,Lifecycle=rejected)
    ; Candidate=none,Evaluation=not_run,
      (Perfect=[] -> Status=no_fitting_candidate ; Status=ambiguous_discovery))),expert_registry_destroy(R)),
 term_string(snapshot(Root,catalog_v1,exact_string_equality_v1,Spec),Bytes,[quoted(true),ignore_ops(true)]),crypto_data_hash(Bytes,Hash,[algorithm(sha256)]),
 Report=_{kind:finite_normalizer_learning,catalog_version:1,scorer:exact_string_equality_v1,project:Root,snapshot:Hash,evidence_manifest:Spec,status:Status,candidate:Candidate,
 discovery:Discovery,evaluation:Evaluation,decision:hold,
 limits:[finite_catalog_only,origin_labels_not_independence_proof,no_statistical_generalization,no_promotion,no_executable_source]},
 term_string(Report,Text,[quoted(true)]).
register_primitive(R,P) :-
 Contract=expert_contract{id:P,version:1,accepts:[ask/1],produces:value,specialties:[normalization],requires:[],
 observations:[],effects:[],fallback:none,child_policy:never,limits:expert_limits{},handler:agentprolog_learning:normalizer(P)},
 expert_register(R,Contract,ok(_)).
score(R,Examples,Primitive,Report) :-
 maplist(example_score(R,Primitive),Examples,Cases),benchmark_report(Primitive,Cases,Report).
example_score(R,P,E,Case) :-
 get_time(Start),expert_invoke(R,P,ask(E.input),_{capabilities:[]},Outcome),
 get_time(End),Millis is round((End-Start)*1000),
 (Outcome.status==succeeded,Outcome.result==E.expected -> Q=1,S=pass ; Q=0,S=fail),
 benchmark_case(E.id,normalization,S,Q,_{model_calls:0,latency_ms:Millis},_{primitive:P,origin:E.origin,status:Outcome.status},Case).
normalizer(P,ask(Input),_,succeeded(Output,[finite_primitive(P,1)])) :-
 string(Input),string_length(Input,L),L=<4096,transform(P,Input,Output).
transform(identity,I,I).
transform(lower,I,O) :- string_lower(I,O).
transform(trim,I,O) :- string_codes(I,C),trim_front(C,A),reverse(A,B),trim_front(B,D),reverse(D,E),string_codes(O,E).
transform(trim_lower,I,O) :- transform(trim,I,T),string_lower(T,O).
trim_front([C|Cs],Out) :- command_space(C),!,trim_front(Cs,Out).
trim_front(Cs,Cs).
