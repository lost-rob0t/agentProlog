:- module(agentprolog_workflow,
    [ workflow_initialize/3, workflow_tools/3, workflow_verify/5,
      workflow_bind/3, workflow_refresh/2,
      project_memory_read/3, preflight/6, execute/4 ]).

/** Native project memory + private TODO journal. No OpenCode integration.
    StateRoot is an explicitly selected private directory outside tracked source.
    Registration grants no permission; journal mutations use canonical write
    mediation and workspace compare-and-swap. Existing .prolog files are read as
    text only, never consulted. Specs/verification are trusted host APIs only.
*/
:- use_module(library(rlm_task_workflow)).
:- use_module(library(filesex)).
:- use_module('./agentprolog_workspace_tools',[]).

workflow_initialize(Project, Revision, StateRoot) :-
    absolute_file_name(Project,Root,[file_type(directory),access(read)]),
    task_workflow_create(Root,Revision,ok(State)),
    serialize(State,Text),
    agentprolog_workspace_tools:preflight(StateRoot,create,
      _{path:"task-workflow.pl",content:Text},N,_),
    agentprolog_workspace_tools:execute(StateRoot,create,N,_).

workflow_tools(Project, StateRoot, Tools) :-
    findall(tool(S,tool_handler(agentprolog_workflow:preflight(Project,StateRoot,Op),
                                agentprolog_workflow:execute(StateRoot,Op))),
      (member(Op,[next,handoff,snapshot,add,transition]),schema(Op,S)),Tools).
schema(Op,S) :- memberchk(Op,[next,handoff]),!,
    read_operation(Op,Name),
    S=tool_schema{name:Name,description:"Read private workflow readiness or handoff; never starts or completes tasks",
      capability:tool(Name),effect:read,
      arguments:_{type:object,required:[],properties:_{},additional_properties:false},
      result:_{type:object,required:[report,sha256],properties:_{report:_{type:string},sha256:_{type:string}},additional_properties:false},
      limits:_{time_limit:3.0,max_output_bytes:100000}}.
schema(Op, S) :-
    operation(Op,Name,Effect,Required,Properties),
    S=tool_schema{name:Name,description:"Native private task journal; completion requires trusted evidence verification",
      capability:tool(Name),effect:Effect,
      arguments:_{type:object,required:Required,additional_properties:false,properties:Properties},
      result:_{type:object,required:[journal,sha256],properties:_{journal:_{type:string},sha256:_{type:string}},additional_properties:false},
      limits:_{time_limit:3.0,max_output_bytes:100000}}.
operation(snapshot,workflow_snapshot,read,[],_{}).
operation(add,workflow_add,write,[id,title,dependencies],
    _{id:_{type:string},title:_{type:string},dependencies:_{type:array,items:_{type:string}}}).
operation(transition,workflow_transition,write,[id,status,reason],
    _{id:_{type:string},status:_{type:string,enum:["pending","active","blocked","cancelled"]},reason:_{type:string}}).

read_operation(next,workflow_next).
read_operation(handoff,workflow_handoff).
preflight(Project,StateRoot,Op,_,N,Details) :- memberchk(Op,[next,handoff]),!,
    read_state(StateRoot,State,Read),
    absolute_file_name(Project,Root,[file_type(directory),access(read)]),
    (State.project==Root -> true ; throw(error(workflow_project_mismatch,_))),
    task_workflow_ready(State,ReadyResult),require_ok(ReadyResult,Ready),
    workflow_report(Op,State,Ready,Report),serialize(Report,Text),
    N=_{write:Read,report:Text},
    Details=_{project_root:Root,target:Read.absolute,operation:Op,before:Read.before}.
preflight(Project,StateRoot,Op,Args,N,Details) :-
    read_state(StateRoot,State,Read),
    absolute_file_name(Project,Root,[file_type(directory),access(read)]),
    (State.project==Root -> true ; throw(error(workflow_project_mismatch,_))),
    change(Op,State,Args,Next),serialize(Next,Text),
    (Op==snapshot -> Write=Read
    ; agentprolog_workspace_tools:preflight(StateRoot,write,
        _{path:"task-workflow.pl",content:Text,expected_sha256:Read.before},Write,_)),
    N=_{write:Write,journal:Text},
    Details=_{project_root:Root,target:Write.absolute,operation:Op,before:Read.before}.
workflow_report(next,State,Ready,_{project:State.project,state_ref:State.state_ref,
    ready:Tasks,starts_tasks:false}) :-
    findall(task{id:Id,title:Title},
      (member(T,State.tasks),memberchk(T.id,Ready),Id=T.id,Title=T.title),Tasks).
workflow_report(handoff,State,Ready,_{project:State.project,state_ref:State.state_ref,
    revision:State.revision,tasks:Tasks,ready:Ready,changes_made:false}) :-
    findall(task{id:Id,title:Title,status:Status,dependencies:Deps,reason:Reason,
                 spec_bound:Bound,verification_present:Verified},
      (member(T,State.tasks),Id=T.id,Title=T.title,Status=T.status,Deps=T.dependencies,Reason=T.reason,
       (T.spec==none -> Bound=false ; Bound=true),
       (T.verification==none -> Verified=false ; Verified=true)),Tasks).

execute(StateRoot,Op,N,Result) :- memberchk(Op,[next,handoff]),!,
    agentprolog_workspace_tools:execute(StateRoot,read,N.write,Receipt),
    Result=_{report:N.report,sha256:Receipt.sha256}.
execute(StateRoot,Op,N,Result) :-
    (Op==snapshot -> Action=read ; Action=write),
    agentprolog_workspace_tools:execute(StateRoot,Action,N.write,Receipt),
    Result=_{journal:N.journal,sha256:Receipt.sha256}.
change(snapshot,S,_,S).
change(add,S,A,N) :- task_workflow_add(S,task{id:A.id,title:A.title,dependencies:A.dependencies},O),require_ok(O,N).
change(transition,S,A,N) :- atom_string(Status,A.status),
    task_workflow_transition(S,A.id,Status,A.reason,O),require_ok(O,N).
require_ok(ok(S),S) :- !.
require_ok(E,_) :- throw(error(workflow_rejected(E),_)).

% Explicit host-only changes retain compare-and-swap on the private checkpoint.
workflow_bind(StateRoot,Id,Frozen) :-
    read_state(StateRoot,S,Read),task_workflow_bind(S,Id,Frozen,O),
    persist_outcome(StateRoot,Read,O).
workflow_refresh(StateRoot,Revision) :-
    read_state(StateRoot,S,Read),task_workflow_refresh(S,Revision,O),
    persist_outcome(StateRoot,Read,O).
persist_outcome(StateRoot,Read,O) :-
    require_ok(O,Next),serialize(Next,Text),
    agentprolog_workspace_tools:preflight(StateRoot,write,
      _{path:"task-workflow.pl",content:Text,expected_sha256:Read.before},N,_),
    agentprolog_workspace_tools:execute(StateRoot,write,N,_).

% Host API: observations and registry may not come from model arguments.
workflow_verify(StateRoot,Id,Observations,Registry,Verification) :-
    read_state(StateRoot,State,Read),
    task_workflow_verify(State,Id,Observations,Registry,Outcome,Verification),
    require_ok(Outcome,Next),serialize(Next,Text),
    agentprolog_workspace_tools:preflight(StateRoot,write,
      _{path:"task-workflow.pl",content:Text,expected_sha256:Read.before},N,_),
    agentprolog_workspace_tools:execute(StateRoot,write,N,_).

project_memory_read(Project,Relative,Snapshot) :-
    string(Relative),
    (sub_string(Relative,0,11,_,".prolog/kb/")
     ;memberchk(Relative,[".prolog/handoff.pl",".prolog/facts.kb"])),!,
    agentprolog_workspace_tools:preflight(Project,read,_{path:Relative},N,_),
    agentprolog_workspace_tools:execute(Project,read,N,Snapshot).
read_state(Root,State,Read) :-
    agentprolog_workspace_tools:preflight(Root,read,_{path:"task-workflow.pl"},Read,_),
    setup_call_cleanup(open_string(Read.content,S),
      (read_term(S,State,[syntax_errors(error)]),read_term(S,end_of_file,[])),close(S)),
    task_workflow_validate(State,O),require_ok(O,_).
serialize(State,Text) :- with_output_to(string(Text),write_term(State,[quoted(true),fullstop(true),nl(true)])).
