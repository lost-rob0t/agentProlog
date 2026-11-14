:- module(agentprolog_session,
          [main/1, serve/2, session_event/2]).

/** One durable product session; canonical runtime owns execution and UI reduction.
    Host executor injection is an API for trusted tests, never a wire option. */
:- use_module(library(http/json)).
:- use_module(library(readutil)).
:- use_module(library(filesex)).
:- use_module(library(uuid)).
:- use_module(library(crypto)).
:- use_module(library(process)).
:- use_module(library(time)).

:- use_module(library(lists)).
:- use_module(library(rlm_async)).
:- use_module(library(prolog_agent_ui_v1)).
:- use_module(library(prolog_agent_ui_facade)).
:- use_module(library(rlm_direct)).
:- use_module(library(rlm_completion), [rlm_completion/4, rlm_cancellation_token/1, rlm_cancel/1]).
:- use_module(library(rlm_tool)).
:- use_module(library(rlm_effect), [rlm_effect_store_open/1, rlm_effect_store_close/0, rlm_effect_normalize/2]).
:- use_module('./agentprolog_config').
:- use_module('./agentprolog_prompt').
:- use_module('./agentprolog_history').
:- use_module('./agentprolog_images').
:- use_module('./agentprolog_experts').
:- use_module('./agentprolog_commands').
:- use_module('./agentprolog_army').
:- use_module('./agentprolog_rsi').
:- use_module('./agentprolog_sleep').
:- use_module('./agentprolog_context_experiment').
:- use_module('./agentprolog_learning').


:- dynamic run_images/2.
:- dynamic worker_state/2, run_token/2, pending_native/4, memory_run_live/1.
:- use_module(library(rlm_authority), [rlm_approve/2, rlm_deny/3, rlm_pending_resolution_async/2]).
:- dynamic checkpoint/1, state_directory/1, executor/1, active/2, negotiated/0.
:- initialization(cli_main, main).
cli_main :- current_prolog_flag(argv, Args), main(Args).

main(Args) :-
    ( Args = [Directory, Project|Rest], cli_options(Rest, Options)
    -> findall(Cap,(member(allow_cap(Cap),Options)),Caps),
       exclude(is_allow_tool,Options,LoadOptions),
       (Caps==[] -> Effective=LoadOptions ; Effective=[allowed_capabilities(Caps)|LoadOptions]),
       load_configuration(Project, Effective, Config), serve(Directory, Config)
    ; format(user_error, 'Usage: agentprolog-session STATE_DIRECTORY PROJECT [--trust-project] [--plugin FILE]~n', []), halt(2) ).
is_allow_tool(allow_cap(_)).
cli_options([], []).
cli_options(['--allow-model',Name|R], [allow_cap(model(Name))|O]) :- cli_options(R,O).
cli_options(['--allow-context',Name|R], [allow_cap(context(Name))|O]) :- cli_options(R,O).
cli_options(['--allow-tool',Name|R], [allow_cap(tool(Name))|O]) :- cli_options(R,O).
cli_options(['--trust-project'|R], [trusted_project(true)|O]) :- cli_options(R,O).
cli_options(['--plugin',Path|R], [plugin(Path)|O]) :- cli_options(R,O).
cli_options(['--package',Path|R], [package(Path)|O]) :- cli_options(R,O).
cli_options(['--agent',Name|R], [agent(Name)|O]) :- cli_options(R,O).
cli_options(['--config',Path|R], [config_file(Path)|O]) :- cli_options(R,O).

serve(Directory, Config) :-
    make_directory_path(Directory),
    directory_file_path(Directory, 'owner.lock', Lock),
    directory_file_path(Directory, 'effects.db', Effects),
    setup_call_cleanup(open(Lock, write, LockStream, [lock(write), wait(false)]),
        setup_call_cleanup(rlm_effect_store_open(Effects),
            setup_call_cleanup(initialize(Directory, Config), loop, shutdown),
            rlm_effect_store_close),
        close(LockStream)).

initialize(Directory, Config) :-
    retractall(worker_state(_,_)), retractall(run_token(_,_)),
    retractall(checkpoint(_)), retractall(state_directory(_)),
    retractall(run_images(_,_)),retractall(executor(_)), retractall(active(_, _)), retractall(negotiated),
    assertz(state_directory(Directory)), assertz(executor(Config)),
    config_binding(Config, Binding), state_path(Path),
    ( exists_file(Path)
    -> setup_call_cleanup(open(Path, read, S), json_read_dict(S, State), close(S)),
       State.version = 1,
       (get_dict(config_binding,State,Binding) -> true ; throw(error(session_configuration_mismatch,_))),
       (get_dict(history,State,History) -> history_validate(Config,History) ; true),
       assertz(checkpoint(State)),
       snapshot(_),
       ( (memberchk(State.phase,["running","cancelling"]);get_dict(native_pending,State,true))
       -> (get_dict(native_pending,State,true) -> event(agent_event(approval_resolved,State.approval_id,"deny")) ; true),
          finish(_{status:"interrupted", reason:"host_restart"})
       ; true )
    ; uuid_string(Session), uuid_string(Workspace),
      ui_v1_initial_view(Session, View),
      State = state{version:1, config_binding:Binding, session_id:Session, workspace_id:Workspace,
                    view:View, phase:"idle", objective:"", run_id:"", candidate:"",
                    approval_id:"", evidence:[], document:null, receipts:[]},
      assertz(checkpoint(State)), persist
    ).

shutdown :-
    with_mutex(agentprolog_session,
      (retractall(negotiated), checkpoint(S),
       (memberchk(S.phase,["running","awaiting_approval"]) -> request_stop(S.run_id) ; true))),
    forall(retract(active(_, Future)), catch(rlm_future_destroy(Future), _, true)).

reap_futures :-
    forall((active(Run,Future),rlm_future_status(Future,Status),memberchk(Status.state,[completed,cancelled])),
      (retract(active(Run,Future)),rlm_future_destroy(Future))).

config_binding(Config, Hash) :-
    rlm_effect_normalize(Config,Copy), term_string(Copy,Text,[quoted(true),ignore_ops(true)]),
    (get_dict(sources,Config,Sources) -> maplist(source_hash,Sources,Hashes) ; Hashes=[]),
    term_string(binding(Text,Hashes),Binding), crypto_data_hash(Binding,HashAtom,[algorithm(sha256)]), atom_string(HashAtom,Hash).
source_hash(Path, Hash) :- crypto_file_hash(Path,Hash,[algorithm(sha256)]).

loop :-
    read_line_to_string(user_input, Line),
    ( Line == end_of_file -> true
    ; catch((handle_line(Line) -> true ; error_frame("invalid_request", "Request rejected", none)),
            _, error_frame("invalid_request", "Request rejected", none)),
      reap_futures, loop ).

handle_line(Line) :-
    % Base64 for one 256 KiB image plus bounded objective/envelope. Ordinary
    % requests retain the smaller limit. Image validation below still applies.
    string_length(Line, Size), Size =< 524288,
    atom_json_dict(Line, Frame, []),
    (Size =< 65536 -> true
    ; Frame.kind == "command", Frame.command == "session.turn",
      executor(ImageConfig), image_enabled(ImageConfig),
      get_dict(images,Frame.payload,[_])),
    ui_v1_validate_frame(Frame, ok(_)),
    with_mutex(agentprolog_session, dispatch(Frame)).

dispatch(F) :- F.kind == "negotiate", !,
    P = F.payload,
    memberchk("prolog_agent_ui_v1", P.protocol_versions),
    BaseSupported = ["streaming_text","generic_tools","approvals","questions","verification","usage","traces"],
    executor(ImageConfig),(image_enabled(ImageConfig)->Supported=["image_input"|BaseSupported];Supported=BaseSupported),
    ( get_dict(required_capabilities, P, Required) -> true ; Required = [] ),
    ( forall(member(C, Required), memberchk(C, Supported))
    -> (negotiated -> true ; assertz(negotiated)),
       executor(Config), Profile = Config.profile,
       result(F.request_id, _{capabilities:Supported, profile:Profile}),
       snapshot(Snapshot), write_frame(Snapshot)
    ; error_frame("unsupported_capability", "Required capability unavailable", F.request_id)
    ).
dispatch(F) :- F.kind == "command", !,
    ( negotiated -> command_frame(F)
    ; error_frame("not_negotiated", "Negotiate first", F.request_id) ).
dispatch(_) :- error_frame("unsupported_frame", "Expected negotiate or command", none).

command_frame(F) :-
    checkpoint(S),
    ( F.session_id \== S.session_id
    -> error_frame("session_mismatch", "Unknown session", F.request_id)
    ; member(Receipt, S.receipts), Receipt.request_id == F.request_id
    -> ( Receipt.command == F.command, same_payload(Receipt,F.payload)
       -> write_frame(Receipt.result)
       ; error_frame("request_conflict", "Request ID reused with different payload", F.request_id) )
    ; admit_request(F),
      catch((execute_command(F, Payload) -> commit_receipt(F, Payload) ; reject("invalid_arguments")),
            Error, command_error(F, Error))
    ).

execute_command(F, Payload) :-
    memberchk(F.command, ["session.create", "session.select"]), !,
    checkpoint(S), Payload = _{workspace_id:S.workspace_id},
    snapshot(Snapshot), write_frame(Snapshot).
execute_command(F, _{accepted:true}) :- F.command == "session.turn", !,
    (get_dict(objective, F.payload, Objective), string(Objective) -> true ; reject("invalid_objective")),
    string_length(Objective, Len), (Len =< 16000 -> true ; reject("objective_too_large")),
    executor(ImageConfig),(get_dict(images,F.payload,ImageInputs)->true;ImageInputs=[]),
    image_request(ImageConfig,ImageInputs,Images,Refs),
    ( Images\=[],
      ( command_head(Objective,Head,_), sub_string(Head,0,1,_,"/")
      ; \+ command_head(Objective,_,_) )
    -> reject("image_requires_plain_objective")
    ; true ),
    ensure_inactive,
    ( normalize_space(string(""), Objective)
    -> uuid_string(Id),
       event(agent_event(question_required, Id, "What would you like the agent to do?", [])),
       update(_{phase:"awaiting_question"})
    ; start(Objective,Images,Refs)
    ).
execute_command(F, _{accepted:true}) :- F.command == "session.resume", !,
    ensure_inactive, checkpoint(S),
    (get_dict(image_refs,S,Refs),Refs\=[] -> reject("reattach_image_before_resume") ; true),
    (S.objective \== "" -> start(S.objective) ; reject("missing_objective")).
execute_command(F, _{accepted:true}) :- F.command == "session.cancel", !,
    checkpoint(S),
    ( S.phase == "running"
    -> request_stop(S.run_id)
    ; S.phase == "awaiting_approval", pending_native(S.run_id,_,_,_)
    -> request_stop(S.run_id)
    ; S.phase == "awaiting_approval"
    -> event(agent_event(approval_resolved, S.approval_id, "deny")), finish(_{status:"cancelled"})
    ; S.phase == "awaiting_question" -> finish(_{status:"cancelled"})
    ; true ).
execute_command(F, _{accepted:true}) :- F.command == "approval.decide",
    checkpoint(S), pending_native(S.run_id,Id,_,Queue), !,
    P=F.payload,
    (S.phase == "awaiting_approval", P.approval_id == Id, memberchk(P.decision,["allow_once","deny"])
     -> event(agent_event(approval_resolved,Id,P.decision)),
        update(_{phase:"running",native_pending:false}), thread_send_message(Queue,decision(P.decision))
     ; reject("invalid_approval")).
execute_command(F, _{accepted:true, published:false}) :- F.command == "approval.decide", !,
    checkpoint(S), P = F.payload,
    ( S.phase == "awaiting_approval", P.approval_id == S.approval_id,
      memberchk(P.decision, ["allow_once", "deny"])
    -> event(agent_event(approval_resolved, S.approval_id, P.decision)),
       ( P.decision == "allow_once"
       -> event(agent_event(trace, _{kind:"artifact", run_id:S.run_id, artifact:S.candidate, published:false})),
          finish(_{status:"complete", artifact:"accepted", published:false})
       ; finish(_{status:"rejected", published:false}) )
    ; reject("invalid_approval") ).
execute_command(F, _{accepted:true}) :- F.command == "question.answer", !,
    checkpoint(S), P = F.payload,
    ( S.phase == "awaiting_question", member(Q, S.view.questions),
      Q.id == P.question_id, Q.status == "pending", string(P.answer),
      string_length(P.answer, Len), Len > 0, Len =< 16000
    -> event(agent_event(question_answered, Q.id, P.answer)), start(P.answer)
    ; reject("invalid_answer") ).
execute_command(_, _) :- reject("unsupported_command").

reject(Code) :- throw(error(command(Code), _)).
ensure_inactive :- checkpoint(S),
    ( memberchk(S.phase, ["running", "cancelling", "awaiting_approval", "awaiting_question"])
    -> reject("session_busy") ; true ).

start(Objective) :- start(Objective,[],[]).
start(Objective,Images,Refs) :-
    uuid_string(Run), checkpoint(S), executor(Config), Profile = Config.profile,
    Budget = Config.budget,
    ui_v1_initial_view(S.session_id, Empty), put_dict(at_seq, Empty, S.view.at_seq, View),
    update(_{view:View}), snapshot(NewSnapshot), write_frame(NewSnapshot),
    update(_{image_refs:Refs,phase:"running", run_id:Run, objective:Objective, candidate:"", approval_id:"", evidence:[], document:null}),
    event(agent_event(run_started, _{run_id:Run, workspace_id:S.workspace_id,
          objective:Objective, profile:Profile, budget:Budget})),
    (Refs==[] -> true ; event(agent_event(trace,_{kind:"image_attachment",references:Refs,durable_bytes_retained:false}))),
    rlm_cancellation_token(Token), assertz(run_token(Run,Token)),
    assertz(run_images(Run,Images)),
    assertz(worker_state(Run,pending)),
    rlm_async_submit(agentprolog_session:work(Run, Objective), Future),
    assertz(active(Run, Future)).

work(Run, Objective, done) :-
    setup_call_cleanup(begin_work(Run),work_body(Run,Objective),end_work(Run)).
begin_work(Run) :-
    with_mutex(agentprolog_session,
      (checkpoint(S), S.run_id == Run, S.phase == "running",
       retractall(worker_state(Run,_)),assertz(worker_state(Run,running)))).
end_work(Run) :-
    with_mutex(agentprolog_session,
      (retractall(run_images(Run,_)),retractall(worker_state(Run,_)),assertz(worker_state(Run,finished)),
       checkpoint(S),
       (S.run_id == Run, S.phase == "cancelling"
        -> finish(_{status:"cancelled",cleanup_confirmed:true}) ; true))).
request_stop(Run) :-
    retractall(run_images(Run,_)),
    update(_{phase:"cancelling"}),
    event(agent_event(verification,"cancellation",_{status:"requested",cleanup_confirmed:false})),
    (pending_native(Run,Id,_,Queue)
     -> event(agent_event(approval_resolved,Id,"deny")), thread_send_message(Queue,decision(cancel)) ; true),
    (run_token(Run,Token) -> rlm_cancel(Token) ; true),
    (active(Run,Future) -> rlm_future_cancel(Future,_) ; true),
    (worker_state(Run,running) -> true
     ; finish(_{status:"cancelled",cleanup_confirmed:true})).
work_body(Run,Objective) :-
    executor(Base), checkpoint(State),
    (get_dict(history,State,History) -> true ; History=[]),
    (run_images(Run,Images)->true;Images=[]),
    put_dict(_{history:History,images:Images},Base,Config),
    catch((native_execute(Config, Objective, Run, Outcome) -> true ; Outcome=error(failed)), _, Outcome=error(exception)),
    with_mutex(agentprolog_session,
      catch((complete(Run, Outcome) -> true ; fail_run(Run)), _, fail_run(Run))).

native_execute(Config,Objective,Run,Outcome) :-
    command_head(Objective,"/learn",Arguments),!,
    (command_head(Arguments,NameString,Tail),string_codes(Tail,Codes),forall(member(C,Codes),command_space(C))
     -> atom_string(Name,NameString),bounded_native_read(Config,Run,learn_execute(Config,Name,Outcome))
     ; Outcome=error(_{kind:invalid_request,phase:runtime})).

native_execute(Config,Objective,Run,Outcome) :-
    command_head(Objective,"/rsi-context",Arguments),!,
    (command_head(Arguments,NameString,Tail),string_codes(Tail,Codes),forall(member(C,Codes),command_space(C))
     -> atom_string(Name,NameString),
        bounded_native_read(Config,Run,context_experiment_execute(Config,Run,Name,Outcome))
     ; Outcome=error(_{kind:invalid_request,phase:runtime})).

native_execute(Config,Objective,Run,Outcome) :-
    command_head(Objective,"/sleep",Arguments),!,string_codes(Arguments,Codes),
    (forall(member(C,Codes),command_space(C))
     -> (get_dict(history,Config,History) -> true ; History=[]),run_token(Run,Token),
        bounded_native_read(Config,Run,sleep_preview(Config,History,Token,Outcome))
     ; Outcome=error(_{kind:invalid_request,phase:runtime})).

native_execute(Config,Objective,Run,Outcome) :-
    command_head(Objective,"/rsi",Arguments),!,
    (command_head(Arguments,NameString,Tail),string_codes(Tail,Codes),NameString\=="",forall(member(C,Codes),command_space(C))
     -> atom_string(Name,NameString),
        setup_call_cleanup(tool_registry_create(Registry),
         (forall(member(tool(S,H),Config.tools),(observed_binding(H,Run,S.name,O),tool_register(Registry,S,O,ok(_)))),
          bounded_native_read(Config,Run,rsi_execute(Config,Registry,Name,Config.project,Outcome))),
         tool_registry_destroy(Registry))
     ; Outcome=error(_{kind:invalid_request,phase:tool})).

native_execute(Config,Objective,Run,Outcome) :-
    command_head(Objective,Command,Arguments),memberchk(Command,["/army","/swarm"]),!,
    (Command=="/swarm" -> swarm_notice(Notice),
      session_event(Run,agent_event(trace,_{kind:"swarm_stub",message:Notice})) ; Notice=""),
    (army_plan_request(Arguments,Tasks)
    -> bounded_native_read(Config,Run,army_tasks_execute(Config,Run,Tasks,Result)),
       (Result=ok(R),Notice\=="" -> string_concat(Notice,"\n",Prefix),string_concat(Prefix,R.value,Text),
         string_bytes(Text,NoticeBytes,utf8),length(NoticeBytes,NoticeSize),
         (NoticeSize=<Config.budget.max_output_bytes -> put_dict(value,R,Text,Prefixed),Outcome=ok(Prefixed)
          ; Outcome=error(_{kind:budget_exceeded,phase:runtime,usage:R.usage}))
        ; Outcome=Result)
    ; Outcome=error(_{kind:subagent_configuration,phase:runtime})).

native_execute(Config,Objective,Run,Outcome) :-
    command_head(Objective,"/remember",Text),!,
    string_codes(Text,Codes),
    (forall(member(C,Codes),command_space(C))
    -> bounded_native_read(Config,Run,memory_read_command(Config,Run,Outcome))
    ; setup_call_cleanup(assertz(memory_run_live(Run)),
         bounded_native_read(Config,Run,memory_command(Config,Run,Text,Outcome)),
         retractall(memory_run_live(Run)))).

native_execute(Config,Objective,Run,Outcome) :-
    command_head(Objective,Command,Arguments),memberchk(Command,["/next","/handoff"]),!,
    string_codes(Arguments,Codes),
    (forall(member(C,Codes),command_space(C))
    -> (Command=="/next" -> Op=next,Name=workflow_next ; Op=handoff,Name=workflow_handoff),
       setup_call_cleanup(tool_registry_create(Registry),
         (forall(member(tool(Schema,Handler),Config.tools),
            (observed_binding(Handler,Run,Schema.name,Observed),tool_register(Registry,Schema,Observed,ok(_)))),
          bounded_native_read(Config,Run,workflow_command(Config,Registry,Op,Name,Outcome))),
         tool_registry_destroy(Registry))
    ; Outcome=error(_{kind:invalid_workflow_command,phase:tool})).

native_execute(Config,Objective,Run,Outcome) :-
    ask_command(Objective), !,
    (ask_request(Objective,Name,Question)
    -> setup_call_cleanup(tool_registry_create(Registry),
         (forall(member(tool(Schema,Handler),Config.tools),
            (observed_binding(Handler,Run,Schema.name,Observed),tool_register(Registry,Schema,Observed,ok(_)))),
          bounded_native_read(Config,Run,ask_execute(Config,Registry,Name,Question,Outcome))),
         tool_registry_destroy(Registry))
    ; Outcome=error(_{kind:invalid_expert_question,phase:tool})).

native_execute(Config, Objective, Run, Outcome) :-
    setup_call_cleanup(tool_registry_create(Registry),
      (forall(member(tool(Schema, Handler), Config.tools),
         (observed_binding(Handler,Run,Schema.name,Observed), tool_register(Registry, Schema, Observed, ok(_)))),
        (memberchk(stream_responses(true),Config.runtime_options)
         -> put_dict(stream_sink,Config,agentprolog_session:session_event(Run),PromptConfig) ; PromptConfig=Config),
        prepare_runtime_options(PromptConfig,Registry,Objective,RuntimeOptions),
        ((memberchk(model_handler(_),RuntimeOptions);memberchk(planner_handler(_),RuntimeOptions)) -> Stream=[]
        ; Stream=[text_delta_handler(prolog_agent_ui_facade:ui_stream_handler(Run,agentprolog_session:session_event(Run)))]),
       (run_token(Run,Token) -> Cancel=[cancel_token(Token)] ; Cancel=[]),
       append(Stream,Cancel,Controls),
        append(Controls,[tool_registry(Registry),capabilities(Config.capabilities),budget(Config.budget)|RuntimeOptions],Options),
       (get_dict(mode,Config,Mode) -> true ; Mode=direct),
       native_mode(Mode,Objective,Options,Initial), native_continuation(Run,Initial,Outcome)),
      tool_registry_destroy(Registry)).

:- meta_predicate bounded_native_read(+,+,0).
bounded_native_read(Config,Run,Goal) :-
    (run_token(Run,T) -> Cancel=[cancel_token(T)] ; Cancel=[]),
    rlm_completion:cancellation_option(Cancel,Token,Own),
    setup_call_cleanup(rlm_completion:register_current_thread(Token),
      (rlm_completion:check_cancelled(Token),call_with_time_limit(Config.budget.time_limit,Goal),
       rlm_completion:check_cancelled(Token)),rlm_completion:cleanup_cancellation(Token,Own)).

workflow_command(Config,_,_,_,error(_{kind:budget_exceeded,phase:tool})) :-
    Config.budget.max_tool_calls<1,!.
workflow_command(Config,Registry,Op,Name,Outcome) :-
    (member(tool(Schema,tool_handler(agentprolog_workflow:preflight(_,_,Op),
                                    agentprolog_workflow:execute(_,Op))),Config.tools),Schema.name==Name
    -> tool_invoke_execute(Registry,Config.capabilities,Name,_{},[],Result),
       (Result.outcome=ok(Envelope)
        -> Text=Envelope.value.report,string_bytes(Text,Bytes,utf8),length(Bytes,N),
           (N=<Config.budget.max_output_bytes
            -> Outcome=ok(_{value:Text,usage:_{model_calls:0,tool_calls:1,total_tokens:0}})
            ; Outcome=error(_{kind:budget_exceeded,phase:tool}))
        ; Outcome=Result.outcome)
    ; Outcome=error(_{kind:workflow_not_configured,phase:tool})).

memory_read_command(Config,Run,Outcome) :-
 (Config.budget.max_tool_calls<1 -> Outcome=error(_{kind:budget_exceeded,phase:tool})
 ; setup_call_cleanup(tool_registry_create(Registry),
   (forall(member(tool(S,H),Config.tools),(observed_binding(H,Run,S.name,O),tool_register(Registry,S,O,ok(_)))),
    tool_invoke_execute(Registry,Config.capabilities,memory_recall,_{},[],Result),
    (Result.outcome=ok(E) -> Text=E.value.report,string_bytes(Text,Bytes,utf8),length(Bytes,N),
      (N=<Config.budget.max_output_bytes -> Outcome=ok(_{value:Text,usage:_{model_calls:0,tool_calls:1,total_tokens:0}})
       ; Outcome=error(_{kind:budget_exceeded,phase:tool}))
     ; Outcome=Result.outcome)),tool_registry_destroy(Registry))).

memory_command(Config,_,_,error(_{kind:budget_exceeded,phase:tool})) :-
    (Config.budget.max_tool_calls<1 ; Config.budget.max_output_bytes<256),!.
memory_command(Config,Run,Text,Outcome) :-
    (member(tool(Schema,tool_handler(agentprolog_memory:preflight(_,_),
                                   agentprolog_memory:execute(_))),Config.tools),Schema.name==memory_remember
    -> setup_call_cleanup(tool_registry_create(Registry),
         (forall(member(tool(S,H),Config.tools),
            (observed_binding(H,Run,S.name,O),tool_register(Registry,S,O,ok(_)))),
          run_token(Run,Token),get_time(Now),Deadline is Now+Config.budget.time_limit,
          tool_invoke_execute(Registry,Config.capabilities,memory_remember,_{text:Text},
            [pending_execution_guard(agentprolog_session:memory_guard(Run,Token,Deadline))],Result),
          memory_resolution(Run,Deadline,Result.outcome,Resolved),
          (Resolved=ok(E) -> Outcome=ok(_{value:E.value.report,usage:_{model_calls:0,tool_calls:1,total_tokens:0}})
           ; Outcome=Resolved)),tool_registry_destroy(Registry))
    ; Outcome=error(_{kind:workflow_not_configured,phase:tool})).

memory_guard(Run,Token,Deadline,Continuation,Resolution) :-
    (memory_run_live(Run) -> true ; throw(error(rlm_cancelled(Token),closed_run))),
    setup_call_cleanup(rlm_completion:register_current_thread(Token),
      (rlm_completion:check_cancelled(Token),get_time(Now),Remaining is Deadline-Now,
       (Remaining>0 -> true ; throw(time_limit_exceeded)),
       call_with_time_limit(Remaining,call(Continuation,Resolution))),
      rlm_completion:cleanup_cancellation(Token,false)).

memory_resolution(Run,Deadline,approval_required(Pending),Outcome) :- !,
    atom_string(Pending.id,Id),Owner=memory(Run),
    setup_call_cleanup(rlm_authority:rlm_pending_resolution_retain(Pending.id,Owner,Future),
      setup_call_cleanup(message_queue_create(Queue),
        setup_call_cleanup(
          with_mutex(agentprolog_session,
            (assertz(pending_native(Run,Id,memory(Pending.id),Queue)),
             update(_{phase:"awaiting_approval",native_pending:true,approval_id:Id}),
             event(agent_event(approval_required,Id,Run,Pending,["allow_once","deny"])))),
          (get_time(WaitStart),Wait is max(0,Deadline-WaitStart),
           (thread_get_message(Queue,decision(Decision),[timeout(Wait)]) -> true
            ; throw(error(memory_approval_expired,_))),
           (Decision=="allow_once"
            -> rlm_approve(Pending.id,ok(_)),rlm_future_await(Future,Resolution),
               (Resolution.outcome=ok(Value) -> Outcome=ok(_{value:Value}) ; Outcome=Resolution.outcome)
            ; rlm_deny(Pending.id,operator_denied,_),Outcome=error(_{kind:cancelled,phase:tool}))),
          close_memory_pending(Run,Id,Pending.id)),
        message_queue_destroy(Queue)),
      rlm_authority:rlm_pending_resolution_release(Pending.id,Owner)).
memory_resolution(_,_,Outcome,Outcome).
close_memory_pending(Run,Id,Pending) :-
    catch(rlm_deny(Pending,run_closed,_),_,true),
    with_mutex(agentprolog_session,
      (retractall(pending_native(Run,Id,_,_)),
       (checkpoint(S),member(A,S.view.approvals),A.id==Id,A.status=="pending"
        -> event(agent_event(approval_resolved,Id,"deny")) ; true),
       (checkpoint(Current),Current.run_id==Run,Current.phase=="awaiting_approval"
        -> update(_{phase:"running",native_pending:false}) ; true))).


native_mode(direct,Objective,Options,Outcome) :- !,
    rlm_direct_execute(Objective,text(Objective),[suspend_on_approval(true)|Options],Outcome).
native_mode(rlm,Objective,Options,Outcome) :- !,
    rlm_completion(Objective,text(Objective),Options,Outcome).
native_mode(Mode,_,_,error(unsupported_mode(Mode))).

% The native cursor retains execution state. The worker waits for the UI decision;
% only the canonical authority resolves it, and native resume continues execution.
native_continuation(Run,approval_required(Public),Outcome) :- !,
    atom_string(Public.approval.id,ApprovalId),
    setup_call_cleanup(message_queue_create(Queue),
      setup_call_cleanup(
        with_mutex(agentprolog_session,
          (checkpoint(S), S.run_id == Run, S.phase == "running",
           assertz(pending_native(Run,ApprovalId,Public.cursor,Queue)),
           update(_{phase:"awaiting_approval",native_pending:true,approval_id:ApprovalId}),
           event(agent_event(approval_required,ApprovalId,Run,Public.approval,["allow_once","deny"])))),
        (thread_get_message(Queue,decision(Decision)),
         (Decision == "allow_once"
          -> setup_call_cleanup(rlm_pending_resolution_async(Public.approval.id,Resolution),
                (rlm_approve(Public.approval.id,ok(_)),rlm_future_await(Resolution,_),
                 rlm_direct_resume_execute(Public.cursor,Next)),rlm_future_destroy(Resolution))
          ; Decision == "deny" -> rlm_deny(Public.approval.id,operator_denied,ok(_)), Next=rejected
          ; Next=rejected)),
        (retractall(pending_native(Run,_,_,_)),rlm_direct_cancel(Public.cursor,_))),
      message_queue_destroy(Queue)),
    native_continuation(Run,Next,Outcome).
native_continuation(_,Outcome,Outcome).

observed_binding(tool_handler(Preflight,Execute),Run,Name,
                 tool_handler(agentprolog_session:observed_preflight(Preflight,Run,Name),
                              agentprolog_session:observed_execute(Execute,Run,Name))) :- !.
observed_binding(Handler,Run,Name,agentprolog_session:observed_execute(Handler,Run,Name)).
observed_preflight(Handler,Run,Name,Args,Normalized,Details) :-
    catch(call(Handler,Args,Normalized,Details),Error,
      (preflight_failure(Error,Code),
       session_event(Run,agent_event(verification,Name,_{status:"failed",phase:"preflight",code:Code})),
       throw(Error))).
preflight_failure(error(workspace_error(Code),_),Code) :-
    memberchk(Code,[stale_content,non_unique_match,missing_file,already_exists,invalid_path,
      symlink_denied,file_too_large,empty_match,missing_parent,not_regular_file]), !.
preflight_failure(_,confinement_denied).
observed_execute(Handler,Run,Name,Args,Value) :-
    uuid_string(Id), atom_string(Name,ToolName),
    session_event(Run,agent_event(tool_started,Id,ToolName,Args)),
    catch((call(Handler,Args,Value) -> true ; throw(error(tool_handler_failed,_))),Error,
      (session_event(Run,agent_event(tool_finished,Id,_{status:"failed"})),throw(Error))),
    session_event(Run,agent_event(tool_output,Id,Value)),
    (is_dict(Value),get_dict(expert_status,Value,ExpertStatus),ExpertStatus\==succeeded
     -> Finished="failed" ; Finished="ok"),
    session_event(Run,agent_event(tool_finished,Id,_{status:Finished})).

session_event(Run, Event) :-
    with_mutex(agentprolog_session,
        ( (checkpoint(S) -> true ; S=_{run_id:"",phase:"idle"}), (S.run_id == Run, S.phase == "running"
         -> bounded_event(Event, Bounded), event(Bounded) ; true))).

% Cumulative usage snapshots survive cancellation and later child failures.
session_usage(Run,Usage) :-
    with_mutex(agentprolog_session,
      (checkpoint(S),S.run_id==Run,memberchk(S.phase,["running","cancelling"])
       -> event(agent_event(usage,Usage)) ; true)).

complete(Run, Outcome) :-
    checkpoint(S),
    (S.run_id == Run, S.phase == "running"
    -> (Outcome == rejected -> finish(_{status:"rejected"})
       ; Outcome = ok(Result), get_dict(value, Result, Text), string(Text)
       -> (member(M,S.view.messages), M.role == "assistant", M.text == Text -> true
          ; event(agent_event(message_started,Run,"assistant")),
          bounded_event(agent_event(model_delta,Run,Text), Delta), event(Delta),
          event(agent_event(message_completed,Run))),
          (get_dict(usage,Result,Usage) -> event(agent_event(usage,Usage)) ; true),
          provider_route(Result),
          executor(Config),
          (get_dict(validate_artifact,Config.hooks,Hook) -> call(Hook,Result,Decision) ; Decision=complete(_{text:Text})),
          complete_decision(Run, Decision)
        ; failed_usage(Outcome),safe_failure(Outcome,Failure), finish(Failure))
    ; true).

provider_route(Result) :-
    (get_dict(response,Result,Response), is_dict(Response)
     -> findall(Key-Text,(member(Key,[provider,requested_model,selected_model]),
          get_dict(Key,Response,Value), route_text(Value,Text)),Pairs),
        (Pairs == [] -> true
         ; dict_pairs(Route,_,Pairs), put_dict(kind,Route,"provider_route",Trace),event(agent_event(trace,Trace)))
     ; true).

failed_usage(error(Error)) :- is_dict(Error),get_dict(usage,Error,Usage),is_dict(Usage), !,
    event(agent_event(usage,Usage)).
failed_usage(_).
route_text(Value,Text) :-
    (atom(Value) -> atom_string(Value,Text) ; string(Value),Text=Value),
    string_length(Text,N), N=<200,
    string_codes(Text,Codes), forall(member(C,Codes),(C>=32,C=<126)).

% Only known categorical fields cross the boundary. Native exception terms,
% provider payloads and URLs may contain credentials and are never rendered.
safe_failure(error(Error), Failure) :- is_dict(Error), !,
    safe_category(Error,kind,Kind), safe_category(Error,phase,Phase),
    Failure=_{status:"failed",reason:"native_execution_failed",code:Kind,stage:Phase}.
safe_failure(_, _{status:"failed",reason:"native_execution_failed",code:"runtime_error",stage:"runtime"}).
safe_category(Dict,Key,Text) :-
    get_dict(Key,Dict,Value),
    memberchk(Value,[completion_fault,transport_error,provider_error,budget_exceeded,
      cancelled,timeout,capability_error,invalid_request,unknown_expert,invalid_expert_question,expert_not_succeeded,invalid_workflow_command,workflow_not_configured,subagent_configuration,subagent_failed,
      effect_store_required,approval_required,runtime,completion,provider,
      budget,tool,context,plan,validation,authority,native_result]), !,
    atom_string(Value,Text).
safe_category(_,_,"unknown").

complete_decision(Run, approval(Artifact)) :- !,
    is_dict(Artifact), uuid_string(Approval),
    update(_{candidate:Artifact, approval_id:Approval, phase:"awaiting_approval"}),
    event(agent_event(approval_required, Approval, Run, Artifact, ["allow_once","deny"])).
complete_decision(Run, complete(Artifact)) :-
    is_dict(Artifact),
    event(agent_event(trace, _{kind:"artifact",run_id:Run,artifact:Artifact,published:false})),
    finish(_{status:"complete",published:false}).

finish(Outcome) :-
    checkpoint(S), executor(Config),
    (Outcome.status=="complete", S.phase\=="complete",
     member(M,S.view.messages),M.role=="assistant"
    -> findall(T,(member(A,S.view.messages),A.role=="assistant",T=A.text),Texts),
       last(Texts,Text),history_record(Config,S,Text,History),
       Patch=_{history:History,phase:Outcome.status,native_pending:false}
    ; Patch=_{phase:Outcome.status,native_pending:false}),
    update(Patch), event(agent_event(run_finished, Outcome)).

event(Canonical) :-
    checkpoint(S), Seq is S.view.at_seq + 1,
    ui_facade_event(S.session_id, Seq, Canonical, Frame),
    ui_v1_apply_event(S.view, Frame, ok(View)),
    ui_facade_snapshot(S.session_id, "bounds_check", View, Bounded),
    ui_v1_validate_frame(Bounded, ok(_)),
    update(_{view:View}), (negotiated -> write_frame(Frame) ; true).

snapshot(Frame) :-
    checkpoint(S), format(string(Id), 'snapshot_~d', [S.view.at_seq]),
    ui_facade_snapshot(S.session_id, Id, S.view, Frame),
    ui_v1_validate_frame(Frame, ok(_)).

commit_receipt(F, Payload) :-
    checkpoint(S), ui_v1_result_frame(S.session_id, F.request_id, "ok", Payload, Result),
    request_receipt(F,Result,Receipt),
    exclude(same_request(F.request_id), S.receipts, OldReceipts),
    append(OldReceipts, [Receipt], Receipts),
    update(_{receipts:Receipts}), write_frame(Result).
result(Request, Payload) :-
    checkpoint(S), ui_v1_result_frame(S.session_id, Request, "ok", Payload, Frame), write_frame(Frame).
error_frame(Code, Message, Request) :-
    checkpoint(S), ui_v1_error_frame(S.session_id, Request, Code, Message, Frame), write_frame(Frame).
write_frame(Frame) :-
    ui_v1_encode_frame(Frame, ok(Line)),
    with_mutex(agentprolog_stdout, (format(user_output, '~s~n', [Line]), flush_output(user_output))).

update(Patch) :-
    checkpoint(Old), put_dict(Patch, Old, New),
    state_path(Path), atom_concat(Path, '.tmp', Temp),
    setup_call_cleanup(open(Temp,write,Stream),json_write_dict(Stream,New,[width(0)]),close(Stream)),
    rename_file(Temp,Path),
    retractall(checkpoint(_)), assertz(checkpoint(New)).
state_path(Path) :- state_directory(D), directory_file_path(D, 'session.json', Path).
persist :-
    checkpoint(S), state_path(Path), atom_concat(Path, '.tmp', Temp),
    setup_call_cleanup(open(Temp, write, Stream), json_write_dict(Stream, S, [width(0)]), close(Stream)),
    rename_file(Temp, Path).
uuid_string(Id) :- uuid(U), atom_string(U, Id).

% Admit identity durably before any async dispatch. After a crash an admitted
% request returns an indeterminate receipt, never implicitly resubmits work.
admit_request(F) :-
    checkpoint(S), length(S.receipts, N),
    (N < 1024 -> true ; reject("receipt_limit")),
    ui_v1_result_frame(S.session_id, F.request_id, "ok",
                      _{accepted:true, recovery:"inspect_snapshot_before_retry"}, Result),
    request_receipt(F,Result,Receipt),
    append(S.receipts, [Receipt], Receipts), update(_{receipts:Receipts}).
same_request(Id, Receipt) :- Receipt.request_id == Id.
reject_receipt(F, Code) :-
    checkpoint(S), ui_v1_error_frame(S.session_id, F.request_id, Code, "Command rejected", Result),
    request_receipt(F,Result,Receipt),
    exclude(same_request(F.request_id), S.receipts, Old),
    append(Old, [Receipt], Receipts), update(_{receipts:Receipts}), write_frame(Result).

% Keep each native observation useful without allowing a remote page/tool to
% exhaust the canonical snapshot. Full report is bounded independently.
bounded_event(agent_event(tool_output, Id, Value), agent_event(tool_output, Id, Preview)) :- !,
    atom_json_dict(Text, _{value:Value}, [width(0)]), atom_length(Text, N),
    (N =< 8192 -> Preview=Value
    ; sub_atom(Text, 0, 8192, _, Prefix), atom_string(Prefix, String),
      Preview=_{preview:String, truncated:true}).
bounded_event(agent_event(model_delta, Id, Text), agent_event(model_delta, Id, Bounded)) :- !,
    checkpoint(S),
    (member(M, S.view.messages), M.id == Id -> string_length(M.text, Used) ; Used=0),
    Available is max(0, 16384-Used), string_length(Text, N), Keep is min(N, Available),
    sub_string(Text, 0, Keep, _, Bounded).
bounded_event(Event, Event).

command_error(F, error(command(Code), _)) :- !, reject_receipt(F, Code).
command_error(F, _) :- reject_receipt(F, "invalid_arguments").
fail_run(Run) :- checkpoint(S),
    (S.run_id == Run, S.phase == "running"
    -> finish(_{status:"failed", reason:"artifact_validation_failed"}) ; true).

% Image bytes never enter durable request receipts. Preserve old receipt format
% for ordinary commands and compare hashes separately from user-supplied keys.
request_receipt(F,Result,Receipt) :-
 (get_dict(images,F.payload,_) -> payload_digest(F.payload,D),Receipt=_{request_id:F.request_id,command:F.command,payload_digest:D,result:Result}
 ; Receipt=_{request_id:F.request_id,command:F.command,payload:F.payload,result:Result}).
payload_digest(P,D) :- atom_json_dict(JSON,P,[width(0)]),crypto_data_hash(JSON,H,[algorithm(sha256),encoding(utf8)]),atom_string(H,D).
same_payload(Receipt,Payload) :-
 (get_dict(payload_digest,Receipt,D) -> payload_digest(Payload,D) ; Receipt.payload =@= Payload).
