:- module(agentprolog_rsi,[rsi_evaluation_tool/3,rsi_execute/5,native_only/3]).
/** Evaluation-only RSI foothold. Trusted fixed experts, paired exact-answer cases.
    No candidate generation, code editing, admission, generalization or promotion. */
:- use_module(library(rlm_expert)).
:- use_module(library(rlm_benchmark)).
:- use_module(library(rlm_tool)).
:- use_module(library(crypto)).

rsi_evaluation_tool(Project,Spec,tool(Schema,agentprolog_rsi:native_only(Frozen))) :-
    valid_spec(Spec),absolute_file_name(Project,Root,[file_type(directory),access(read)]),
    term_string(snapshot(Root,Spec),Bytes,[quoted(true),ignore_ops(true)]),
    crypto_data_hash(Bytes,Hash,[algorithm(sha256)]),
    Frozen=frozen{project:Root,spec:Spec,digest:Hash},atom_concat(rsi_,Spec.id,Name),
    Schema=tool_schema{name:Name,description:"Evaluate frozen symbolic candidate against baseline; never promote",
      capability:tool(Name),effect:read,arguments:_{type:object,additional_properties:false,properties:_{}},
      result:_{type:object,required:[report],additional_properties:false,properties:_{report:_{type:string}}},
      limits:_{time_limit:10.0,max_output_bytes:65536}}.
valid_spec(S) :-
    ground(S),dict_pairs(S,_,[baseline-B,candidate-C,cases-Cases,id-Id,version-Version]),
    atom(Id),atom_length(Id,L),L>0,L=<64,integer(Version),Version>0,
    B.id\==C.id,B.limits==C.limits,
    forall(member(E,[B,C]),(E.requires==[],E.effects==[],E.fallback==none,E.child_policy==never,E.accepts==[ask/1])),
    is_list(Cases),length(Cases,N),between(1,16,N),maplist(valid_case,Cases),
    findall(I,(member(X,Cases),I=X.id),Ids),sort(Ids,U),length(U,N),
    setup_call_cleanup(expert_registry_create([],R),
      (expert_register(R,B,ok(_)),expert_register(R,C,ok(_))),expert_registry_destroy(R)),!.
valid_spec(_) :- throw(error(invalid_rsi_evaluation,_)).
valid_case(C) :- dict_pairs(C,_,[expected-E,id-I,input-Q,origin-O]),atom(I),atom(O),
    string(Q),string(E),string_length(Q,N),N>0,N=<4096,string_length(E,M),M=<4096.

% A configured schema is not permission to bypass native project/batch guards.
% Ordinary direct/RLM tool calls fail before invoking either expert.
native_only(_,_,_) :- throw(error(native_rsi_command_required,_)).

evaluate(Frozen,_,_{report:Text}) :-
    S=Frozen.spec,
    setup_call_cleanup(expert_registry_create([],Registry),
      (expert_register(Registry,S.baseline,ok(_)),expert_register(Registry,S.candidate,ok(_)),
       maplist(pair(Registry,S),S.cases,Pairs)),expert_registry_destroy(Registry)),
    findall(B,(member(P,Pairs),B=P.baseline),Bs),findall(C,(member(P,Pairs),C=P.candidate),Cs),
    benchmark_report(baseline,Bs,BR),benchmark_report(candidate,Cs,CR),
    Delta is CR.mean_quality-BR.mean_quality,
    findall(I,(member(P,Pairs),P.candidate.quality<P.baseline.quality,I=P.id),Regressions),
    Report=_{kind:symbolic_evaluation_only,project:Frozen.project,snapshot:Frozen.digest,
      version:S.version,score:exact_answer_accuracy,delta:Delta,regressions:Regressions,
      decision:hold,reasons:[evaluation_only,no_independent_generalization_evidence,no_promotion_interface],
      baseline:BR,candidate:CR,pairs:Pairs},
    term_string(Report,Text,[quoted(true)]).
pair(Registry,S,Case,_{id:Case.id,origin:Case.origin,baseline:B,candidate:C}) :-
    measured(Registry,S.baseline.id,Case,B),measured(Registry,S.candidate.id,Case,C).
measured(Registry,Id,Case,Result) :-
    get_time(Start),
    call_with_inference_limit(expert_invoke(Registry,Id,ask(Case.input),_{capabilities:[]},Outcome),1000000,Limit),
    get_time(End),Millis is round((End-Start)*1000),
    (Limit\==inference_limit_exceeded,nonvar(Outcome),Outcome.status==succeeded,
     Outcome.result==Case.expected -> Quality=1,Status=pass ; Quality=0,Status=fail),
    (nonvar(Outcome),get_dict(status,Outcome,ExpertStatus) -> true ; ExpertStatus=resource_limited),
    benchmark_case(Case.id,symbolic_exact,Status,Quality,_{model_calls:0,latency_ms:Millis},
      _{expert:Id,expert_status:ExpertStatus,origin:Case.origin},Result).

rsi_execute(Config,_Registry,Name,Project,Outcome) :-
    atom_concat(rsi_,Name,ToolName),
    (member(tool(Schema,agentprolog_rsi:native_only(Frozen)),Config.tools),Schema.name==ToolName,
     Frozen.project==Project
    -> (length(Frozen.spec.cases,Count),Calls is 2*Count,
        (Config.budget.max_tool_calls<1;Calls>Config.budget.max_native_calls_per_batch) -> Outcome=error(_{kind:budget_exceeded,phase:tool})
        ; setup_call_cleanup(tool_registry_create(NativeRegistry),
          (tool_register(NativeRegistry,Schema,agentprolog_rsi:evaluate(Frozen),ok(_)),
           tool_invoke_execute(NativeRegistry,Config.capabilities,ToolName,_{},[],R)),
          tool_registry_destroy(NativeRegistry)),
          (R.outcome=ok(E) -> string_bytes(E.value.report,Bytes,utf8),length(Bytes,N),
            (N=<Config.budget.max_output_bytes -> Outcome=ok(_{value:E.value.report,usage:_{model_calls:0,tool_calls:1,total_tokens:0}})
             ; Outcome=error(_{kind:budget_exceeded,phase:tool})) ; Outcome=R.outcome))
    ; Outcome=error(_{kind:invalid_request,phase:tool})).
