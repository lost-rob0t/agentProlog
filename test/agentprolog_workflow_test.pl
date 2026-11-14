:- begin_tests(agentprolog_workflow).
:- use_module('../prolog/agentprolog_workflow').
:- use_module(library(filesex)).
:- use_module(library(readutil)).
setup(P,S) :- tmp_file(project,P),make_directory(P),tmp_file(state,S),make_directory(S),workflow_initialize(P,r1,S).
clean(P,S) :- delete_directory_and_contents(P),delete_directory_and_contents(S).
op(P,S,Kind,Args,R) :- preflight(P,S,Kind,Args,N,_),execute(S,Kind,N,R).
test(journal_roundtrip,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
    op(P,S,add,_{id:"a",title:"Implement",dependencies:[]},_),
    op(P,S,transition,_{id:"a",status:"active",reason:"coding"},_),
    op(P,S,snapshot,_{},R),assertion(sub_string(R.journal,_,_,_,"active")),
    directory_files(P,Files),sort(Files,['.','..']).
test(cannot_mark_done,[setup(setup(P,S)),cleanup(clean(P,S)),throws(error(workflow_rejected(_),_))]) :-
    op(P,S,add,_{id:"a",title:"Implement",dependencies:[]},_),
    op(P,S,transition,_{id:"a",status:"done",reason:"trust me"},_).
test(other_project_rejected,[setup(setup(P,S)),cleanup(clean(P,S)),throws(error(workflow_project_mismatch,_))]) :-
    op(S,S,snapshot,_{},_).
test(stale_preflight_rejected,[setup(setup(P,S)),cleanup(clean(P,S)),throws(error(workspace_error(stale_content),_))]) :-
    preflight(P,S,add,_{id:"a",title:"a",dependencies:[]},N,_),
    op(P,S,add,_{id:"b",title:"b",dependencies:[]},_),execute(S,add,N,_).
test(existing_prolog_text_is_inert,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
    directory_file_path(P,'.prolog/kb',KB),make_directory_path(KB),
    directory_file_path(KB,'test.pl',File),
    setup_call_cleanup(open(File,write,F),write(F,':- throw(should_not_run).\n'),close(F)),
    project_memory_read(P,".prolog/kb/test.pl",R),assertion(sub_string(R.content,_,_,_,"should_not_run")),
    assertion(\+project_memory_read(P,"README.org",_)).

:- use_module(library(rlm_tool)).
:- use_module(library(rlm_effect)).
:- use_module(library(rlm_authority)).
:- use_module(library(rlm_async)).
register(P,S,R) :- tool_registry_create(R),workflow_tools(P,S,Tools),
    forall(member(tool(Schema,Handler),Tools),tool_register(R,Schema,Handler,ok(_))).
test(missing_capability_denied,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
    setup_call_cleanup(register(P,S,R),
      (tool_invoke(R,[],workflow_snapshot,_{},[],error(E),_),
       assertion(E.kind==capability_denied)),tool_registry_destroy(R)).
test(journal_mutation_needs_approval,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
    directory_file_path(S,'effects.db',Store),
    setup_call_cleanup(rlm_effect_store_open(Store),
      setup_call_cleanup(register(P,S,R),
        (tool_invoke(R,[tool(workflow_add)],workflow_add,
          _{id:"x",title:"x",dependencies:[]},[],approval_required(Pending),_),
         op(P,S,snapshot,_{},Before),assertion(\+sub_string(Before.journal,_,_,_,"title:")),
         rlm_pending_resolution_async(Pending.id,F),rlm_approve(Pending.id,ok(_)),
         rlm_future_await(F,5.0,Resolution),get_dict(outcome,Resolution,ok(_)),
         rlm_future_destroy(F),op(P,S,snapshot,_{},After),
         assertion(sub_string(After.journal,_,_,_,"title:"))),tool_registry_destroy(R)),
      rlm_effect_store_close).
test(checkpoint_directive_is_not_executed,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
    directory_file_path(S,'task-workflow.pl',Path),
    setup_call_cleanup(open(Path,write,F),write(F,':- throw(executed).'),close(F)),
    catch(op(P,S,snapshot,_{},_),error(workflow_rejected(_),_),Rejected=true),
    assertion(Rejected==true).

:- use_module(library(process)).
test(fresh_process_reads_checkpoint,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
    op(P,S,add,_{id:"restart",title:"durable",dependencies:[]},_),
    current_prolog_flag(executable,Exe),
    module_property(agentprolog_workflow,file(Adapter)),
    module_property(rlm_task_workflow,file(Runtime)),file_directory_name(Runtime,Lib),
    format(atom(Library),'library=~w',[Lib]),
    format(atom(Goal),'agentprolog_workflow:preflight(~q,~q,snapshot,_{},N,_),agentprolog_workflow:execute(~q,snapshot,N,R),write(R.journal),halt',[P,S,S]),
    setup_call_cleanup(process_create(Exe,['-q','-p',Library,'-s',Adapter,'-g',Goal],
      [stdout(pipe(Out)),process(Pid)]),
      (read_string(Out,_,Text),process_wait(Pid,exit(0)),
       assertion(sub_string(Text,_,_,_,"durable"))),close(Out)).

:- use_module('../prolog/agentprolog_session').
:- use_module('../prolog/agentprolog_config').
command_config(P,S,C) :- workflow_tools(P,S,Tools),default_configuration(D),
    put_dict(_{tools:Tools,capabilities:[tool(workflow_next),tool(workflow_handoff)]},D,C).
seed_tasks(P,S) :-
    op(P,S,add,_{id:"first",title:"First task",dependencies:[]},_),
    op(P,S,add,_{id:"second",title:"Dependent task",dependencies:["first"]},_).
test(next_selects_only_ready_without_starting,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
    seed_tasks(P,S),op(P,S,snapshot,_{},Before),command_config(P,S,C),
    agentprolog_session:native_execute(C,"/next",test,ok(R)),
    assertion(sub_string(R.value,_,_,_,"First task")),
    assertion(\+sub_string(R.value,_,_,_,"Dependent task")),
    op(P,S,snapshot,_{},After),assertion(Before.sha256==After.sha256),
    assertion(R.usage.model_calls=:=0).
test(handoff_includes_blocks_without_writing,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
    seed_tasks(P,S),op(P,S,transition,_{id:"first",status:"blocked",reason:"Need review"},_),
    op(P,S,snapshot,_{},Before),command_config(P,S,C),
    agentprolog_session:native_execute(C,"/handoff",test,ok(R)),
    assertion(sub_string(R.value,_,_,_,"Need review")),
    assertion(sub_string(R.value,_,_,_,"Dependent task")),
    op(P,S,snapshot,_{},After),assertion(Before.sha256==After.sha256).
test(readiness_preflight_is_stale_after_edit,[setup(setup(P,S)),cleanup(clean(P,S)),throws(error(workspace_error(stale_content),_))]) :-
    preflight(P,S,next,_{},N,_),seed_tasks(P,S),execute(S,next,N,_).
test(next_requires_grant,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
    command_config(P,S,Base),put_dict(capabilities,Base,[],C),
    agentprolog_session:native_execute(C,"/next",test,error(_)).
test(read_commands_reject_operands_without_model,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
    command_config(P,S,C),
    agentprolog_session:native_execute(C,"/next extra",test,error(E)),assertion(E.kind==invalid_workflow_command),
    agentprolog_session:native_execute(C,"/handoff\u00a0extra",test,error(F)),assertion(F.kind==invalid_workflow_command).
test(read_commands_require_configured_workflow) :-
    default_configuration(C),agentprolog_session:native_execute(C,"/handoff",test,error(E)),
    assertion(E.kind==workflow_not_configured).
test(read_commands_preserve_project_isolation,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
    command_config(S,S,C),agentprolog_session:native_execute(C,"/next",test,error(_)).
:- end_tests(agentprolog_workflow).
