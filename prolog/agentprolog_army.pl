:- module(agentprolog_army,[army_request/3,army_plan_request/2,army_execute/5,army_tasks_execute/4,swarm_notice/1]).
/** Explicit bounded profile delegation through the canonical supervised runtime.
    Sequential orchestration, not a swarm or a second scheduler. */
:- use_module(library(option)).
:- use_module(library(http/json)).
:- use_module(library(rlm_agent)).
:- use_module(library(rlm_subagent)).
:- use_module(library(rlm_tool)).
:- use_module(library(rlm_completion),[]).
:- use_module('./agentprolog_commands').
:- use_module('./agentprolog_config').
:- use_module('./agentprolog_prompt').
swarm_notice("This is not a swarm. This stub uses ordinary supervised subagents. Tracking: https://github.com/lost-rob0t/prolog-rlm/issues/568").
army_request(Arguments,Names,Question) :-
    command_head(Arguments,ProfileNames,Question),Question\=="",
    string_codes(Question,Codes),\+forall(member(C,Codes),command_space(C)),
    split_string(ProfileNames,",","",Strings),length(Strings,N),between(1,32,N),
    maplist(profile_name,Strings,Names),sort(Names,Unique),length(Unique,N).
profile_name(S,A) :- string_codes(S,C),C\=[],
    forall(member(X,C),(code_type(X,alnum);memberchk(X,[0'_,0'-]))),atom_string(A,S).

army_plan_request(Arguments,Tasks) :-
    command_head(Arguments,"tasks",Json),!,string_length(Json,Size),Size=<65536,
    catch(atom_json_dict(Json,Tasks,[]),_,fail),valid_tasks(Tasks).
army_plan_request(Arguments,Tasks) :- army_request(Arguments,Names,Question),
    maplist(shared_task(Question),Names,Tasks).
shared_task(Question,Name,task{id:Label,profile:Label,question:Question}) :- atom_string(Name,Label).
valid_tasks(Tasks) :- is_list(Tasks),length(Tasks,N),between(1,32,N),
    maplist(valid_task,Tasks),findall(Id,(member(T,Tasks),Id=T.id),Ids),sort(Ids,Unique),length(Unique,N).
valid_task(T) :- dict_pairs(T,_,[id-Id,profile-Profile,question-Question]),
    string(Id),string_length(Id,Length),Length>0,Length=<64,profile_name(Id,_),
    string(Profile),string_length(Profile,PL),PL>0,PL=<64,profile_name(Profile,_),
    string(Question),string_length(Question,QL),QL>0,QL=<4096,
    string_codes(Question,Codes),\+forall(member(C,Codes),command_space(C)).
army_execute(Config,Run,Names,Question,Outcome) :-
    maplist(shared_task(Question),Names,Tasks),army_tasks_execute(Config,Run,Tasks,Outcome).

army_tasks_execute(Config,Run,Tasks,Outcome) :-
    Progress=progress([]),
    catch((army_execute_(Config,Run,Tasks,Progress,Outcome) -> true
           ; failed_batch(Progress,subagent_configuration,Outcome)),E,
      (progress_usage(Progress,Known),put_dict(cost_known,Known,false,Partial),
       agentprolog_session:session_usage(Run,Partial),
       (control_exception(E) -> throw(E)
        ; Outcome=error(_{kind:subagent_configuration,phase:runtime,usage:Partial})))).
control_exception(error(rlm_cancelled(_),_)).
control_exception(time_limit_exceeded).
control_exception(time_limit_exceeded(_)).
progress_usage(Progress,Usage) :- arg(1,Progress,Results),total_usage(Results,Usage).
failed_batch(Progress,Kind,error(_{kind:Kind,phase:runtime,usage:Usage})) :-
    progress_usage(Progress,Usage).
army_execute_(Config,Run,Tasks,Progress,Outcome) :-
    option(subagents(true),Config.runtime_options,false),
    valid_tasks(Tasks),length(Tasks,Count),
    option(army_max_children(MaxChildren),Config.runtime_options,32),Count=<MaxChildren,
    findall(Name,(member(T,Tasks),atom_string(Name,T.profile)),Names),
    maplist(child_config(Config,Count),Names,Children),
    agentprolog_session:run_token(Run,Token),
    MaxAgents is Count+1,
    setup_call_cleanup(agent_runtime_create([root_capabilities(Config.capabilities),max_agents(MaxAgents),worker_count(1),trace_limit(16)],Runtime),
      (agent_spawn(Runtime,none,agent_spec(parent),Config.capabilities,ok(Parent)),
       get_time(Start),Deadline is Start+Config.budget.time_limit,
       children(Children,Tasks,Config,Run,Token,Deadline,Runtime,Parent,Progress,Results),
       term_string(Results,Text,[quoted(true)]),string_bytes(Text,Bytes,utf8),length(Bytes,Size),
       (Size>Config.budget.max_output_bytes -> failed_batch(Progress,budget_exceeded,Outcome)
        ; forall(member(R,Results),R.status==completed)
        -> progress_usage(Progress,Usage),Outcome=ok(_{value:Text,usage:Usage})
        ; failed_batch(Progress,subagent_failed,Outcome))),
      agent_runtime_destroy(Runtime)).
child_config(Base,Count,Name,Child) :-
    named_agent_configuration(Base,Name,Selected),Selected.mode==rlm,
    include(granted_tool(Selected.capabilities),Selected.tools,Tools),
    forall(member(tool(S,_),Tools),S.effect==read),
    \+memberchk(tool(rlm_subagent),Selected.capabilities),
    \+memberchk(rlm,Selected.capabilities),\+memberchk(parallel,Selected.capabilities),
    dict_pairs(Selected.budget,_,Pairs),maplist(share(Base.budget,Count),Pairs,Shared),
    dict_pairs(Budget,budget,Shared),put_dict(_{budget:Budget,tools:Tools},Selected,Child).
granted_tool(Caps,tool(S,_)) :-
    (get_dict(capability,S,Cap) -> true ; Cap=tool(S.name)),capability_allowed(Caps,Cap).
share(_,_,max_recursion_depth-_,max_recursion_depth-0) :- !.
share(_,_,max_concurrent_subcalls-_,max_concurrent_subcalls-1) :- !.
share(Parent,N,K-V,K-S) :-
    get_dict(K,Parent,Limit),
    (memberchk(K,[time_limit,max_cost_usd]) -> S is min(V,Limit/N)
     ; S is min(V,Limit//N)),
    (memberchk(K,[max_tool_calls,max_cost_usd]) -> S>=0 ; S>0).
children([],[],_,_,_,_,_,_,_,[]).
children([C|Cs],[Task|Tasks],Base,Run,Token,Deadline,Runtime,Parent,Progress,[Report|Rest]) :-
    rlm_completion:check_cancelled(Token),get_time(Now),Remaining is Deadline-Now,Remaining>0,
    Time is min(C.budget.time_limit,Remaining),put_dict(time_limit,C.budget,Time,Budget),
    Label=Task.id,Profile=Task.profile,Q=Task.question,
    agentprolog_session:session_event(Run,agent_event(subagent_started,Label,_{profile:Profile})),
    setup_call_cleanup(tool_registry_create(Registry),
      (register_config_tools(C,Registry),prepare_runtime_options(C,Registry,Q,Prepared),
       append([budget(Budget),cancel_token(Token),tool_registry(Registry),
         capabilities(C.capabilities),child_capabilities(C.capabilities)],Prepared,Options),
       rlm_subagent_handler(Runtime,Parent,C.capabilities,text(Q),Options,_{query:Q},Envelope)),
      tool_registry_destroy(Registry)),
    compact_envelope(Envelope,Compact),term_string(Compact,Text,[quoted(true)]),
    Report=_{task_id:Label,profile:Profile,status:Envelope.status,report:Text,usage:Envelope.usage},
    arg(1,Progress,Prior),nb_setarg(1,Progress,[Report|Prior]),
    progress_usage(Progress,Usage),agentprolog_session:session_usage(Run,Usage),
    agentprolog_session:session_event(Run,agent_event(subagent_finished,Label,_{status:Envelope.status,report:Text})),
    (Envelope.status==completed -> children(Cs,Tasks,Base,Run,Token,Deadline,Runtime,Parent,Progress,Rest) ; Rest=[]).
total_usage(Results,Usage) :-
    sum_usage(Results,model_calls,Models),sum_usage(Results,total_tokens,Tokens),sum_usage(Results,cost_usd,Cost),
    (forall(member(R,Results),get_dict(cost_known,R.usage,true)) -> Known=true ; Known=false),
    Base=_{model_calls:Models,total_tokens:Tokens,cost_usd:Cost,cost_known:Known},
    (forall(member(R,Results),get_dict(tool_calls,R.usage,_))
     -> sum_usage(Results,tool_calls,Tools),put_dict(tool_calls,Base,Tools,Usage)
     ; Usage=Base).
sum_usage(Rs,K,Sum) :- findall(V,(member(R,Rs),(get_dict(K,R.usage,V)->true;V=0)),Vs),sum_list(Vs,Sum).

% Do not recursively print the supervisor's growing trace/completion snapshots
% once per child. Retain the actual bounded answer and canonical provenance.
compact_envelope(E,Compact) :-
    findall(K-V,(member(K,[status,value,evidence,usage,correlation,delegation,timeout]),get_dict(K,E,V)),Pairs),
    dict_pairs(Compact,subagent_report,Pairs).
