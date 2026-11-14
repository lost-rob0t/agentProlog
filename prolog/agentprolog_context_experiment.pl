:- module(agentprolog_context_experiment,[context_experiment_tool/3,context_experiment_execute/4,native_only/4]).
/** Compare a fixed first-fit baseline with canonical context packing.
    Utility is host-labelled relevance, not independently measured intelligence. */
:- use_module(library(rlm_context_budget)).
:- use_module(library(rlm_tool)).
:- use_module('./agentprolog_workspace_tools',[]).
context_experiment_tool(Project,Spec,tool(Schema,agentprolog_context_experiment:native_only(Root,Spec))) :-
 valid_spec(Spec),absolute_file_name(Project,Root,[file_type(directory),access(read)]),
 atom_concat(context_experiment_,Spec.id,Name),
 Schema=tool_schema{name:Name,description:"Native-only bounded context packing comparison; never adopt",
 capability:tool(Name),effect:read,arguments:_{type:object,additional_properties:false,properties:_{}},
 result:_{type:object,required:[report],additional_properties:false,properties:_{report:_{type:string}}},
 limits:_{time_limit:5.0,max_output_bytes:65536}}.
% No ordinary model tool invocation can bypass project/budget checks.
native_only(_,_,_,_) :- throw(error(native_context_experiment_required,_)).
valid_spec(S) :- ground(S),dict_pairs(S,_,[files-Files,id-Id,token_budget-B]),
 atom(Id),integer(B),between(1,4096,B),is_list(Files),length(Files,N),between(1,8,N),
 maplist(valid_file,Files),findall(I,(member(F,Files),I=F.id),Ids),sort(Ids,U),length(U,N),!.
valid_spec(_) :- throw(error(invalid_context_experiment,_)).
valid_file(F) :- dict_pairs(F,_,[id-I,mandatory-M,path-P,utility-U]),atom(I),
 string(P),string_length(P,L),L>0,L=<1024,memberchk(M,[true,false]),integer(U),between(0,100,U).
context_experiment_execute(Config,_Run,Name,Outcome) :-
 atom_concat(context_experiment_,Name,ToolName),
 (member(tool(Schema,agentprolog_context_experiment:native_only(Root,Spec)),Config.tools),
  Schema.name==ToolName,Root==Config.project
  -> length(Spec.files,N),Reads is 2*N,
     ((Config.budget.max_tool_calls<1;Config.budget.max_context_ops<1;Reads>Config.budget.max_native_calls_per_batch)
      -> Outcome=error(_{kind:budget_exceeded,phase:tool})
      ; Cap is min(Spec.token_budget,Config.budget.max_total_tokens),
        setup_call_cleanup(tool_registry_create(R),
         (tool_register(R,Schema,agentprolog_context_experiment:evaluate(Root,Spec,Cap),ok(_)),
          tool_invoke_execute(R,Config.capabilities,ToolName,_{},[],Result)),tool_registry_destroy(R)),
        (Result.outcome=ok(E) -> Text=E.value.report,string_bytes(Text,Bytes,utf8),length(Bytes,Size),
         (Size=<Config.budget.max_output_bytes -> Outcome=ok(_{value:Text,usage:_{model_calls:0,total_tokens:0,tool_calls:1}})
          ; Outcome=error(_{kind:budget_exceeded,phase:tool})) ; Outcome=Result.outcome))
 ; Outcome=error(_{kind:invalid_request,phase:tool})).

evaluate(Root,Spec,Cap,_,_{report:Text}) :-
 maplist(read_source(Root),Spec.files,Sources),
 findall(P,(member(S,Sources),P=S.absolute),Paths),sort(Paths,UniquePaths),
 length(Paths,SourceCount),length(UniquePaths,SourceCount),
 findall(B,(member(S,Sources),B=S.bytes),Sizes),sum_list(Sizes,Bytes),Bytes=<131072,
 maplist(unit,Sources,Units),
 Policy=_{max_context_tokens:Cap,provider_context_tokens:Cap,reserve_output_tokens:0,
 safety_margin_tokens:0,min_recent_turns:0,overflow:deny},
 context_pack(Units,[],Policy,ok(Pack)),
 baseline(Sources,Cap,Baseline),
 findall(Id,(member(Sel,Pack.selected),Id=Sel.id),Selected),
 findall(Id,(member(S,Sources),Id=S.id,\+memberchk(Id,Selected)),Omitted),
 Delta is Pack.utility-Baseline.utility,
 % A changed source invalidates this comparison, never silently reuses its score.
 maplist(revalidate(Root),Sources),
 Report=_{kind:context_packing_experiment,project:Root,decision:hold,
 score:configured_utility_not_accuracy,cap:Cap,source_evidence:Sources,
 baseline:Baseline,candidate:_{selected:Selected,omitted:Omitted,utility:Pack.utility,tokens:Pack.ledger.total_tokens},
 delta:Delta,limits:[heuristic_token_count,no_independent_task_evaluation,no_policy_adoption,no_content_injection]},
 term_string(Report,Text,[quoted(true)]).
read_source(Root,F,S) :-
 agentprolog_workspace_tools:preflight(Root,read,_{path:F.path},Prepared,_),
 agentprolog_workspace_tools:execute(Root,read,Prepared,R),
 token_count_text(R.content,[],ok(T)),
 S=source{id:F.id,path:F.path,absolute:Prepared.absolute,mandatory:F.mandatory,utility:F.utility,
 sha256:R.sha256,bytes:R.bytes,tokens:T.tokens,token_count:T}.
revalidate(Root,S) :-
 agentprolog_workspace_tools:preflight(Root,read,_{path:S.path},P,_),
 agentprolog_workspace_tools:execute(Root,read,P,R),
 (R.sha256==S.sha256 -> true ; throw(error(stale_context_source,_))).
unit(S,context_unit{id:S.id,section:project,mandatory:S.mandatory,
 variants:[context_variant{kind:full,tokens:S.tokens,utility:S.utility,value:S.id}]}).
baseline(Sources,Cap,_{selected:Selected,tokens:Used,utility:Utility}) :-
 include(mandatory,Sources,Required),exclude(mandatory,Sources,Optional),
 source_totals(Required,RequiredTokens,_),RequiredTokens=<Cap,Left is Cap-RequiredTokens,
 first_fit(Optional,Left,Chosen),append(Required,Chosen,All),source_totals(All,Used,Utility),
 findall(Id,(member(S,All),Id=S.id),Selected).
mandatory(S) :- S.mandatory==true.
first_fit([],_,[]).
first_fit([S|Ss],Left,Chosen) :-
 (S.tokens=<Left -> Next is Left-S.tokens,Chosen=[S|Tail] ; Next=Left,Chosen=Tail),
 first_fit(Ss,Next,Tail).
source_totals(Sources,Tokens,Utility) :-
 findall(T,(member(S,Sources),T=S.tokens),Ts),sum_list(Ts,Tokens),
 findall(U,(member(S,Sources),U=S.utility),Us),sum_list(Us,Utility).
