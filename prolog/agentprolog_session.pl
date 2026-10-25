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


:- dynamic worker_state/2, run_token/2, pending_native/4.
:- use_module(library(rlm_authority), [rlm_approve/2, rlm_deny/3, rlm_pending_resolution_async/2]).
:- dynamic checkpoint/1, state_directory/1, executor/1, active/2, negotiated/0.
:- initialization(cli_main, main).
cli_main :- current_prolog_flag(argv, Args), main(Args).

main(Args) :-
    ( Args = [Directory, Project|Rest], cli_options(Rest, Options)
    -> findall(Cap,(member(allow_cap(Cap),Options)),Caps),
       exclude(is_allow_tool,Options,LoadOptions),
       load_configuration(Project, [allowed_capabilities(Caps)|LoadOptions], Config), serve(Directory, Config)
    ; format(user_error, 'Usage: agentprolog-session STATE_DIRECTORY PROJECT [--trust-project] [--plugin FILE]~n', []), halt(2) ).
is_allow_tool(allow_cap(_)).
cli_options([], []).
cli_options(['--allow-model',Name|R], [allow_cap(model(Name))|O]) :- cli_options(R,O).
cli_options(['--allow-context',Name|R], [allow_cap(context(Name))|O]) :- cli_options(R,O).
cli_options(['--allow-tool',Name|R], [allow_cap(tool(Name))|O]) :- cli_options(R,O).
cli_options(['--trust-project'|R], [trusted_project(true)|O]) :- cli_options(R,O).
cli_options(['--plugin',Path|R], [plugin(Path)|O]) :- cli_options(R,O).

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
    retractall(executor(_)), retractall(active(_, _)), retractall(negotiated),
    assertz(state_directory(Directory)), assertz(executor(Config)),
    config_binding(Config, Binding), state_path(Path),
    ( exists_file(Path)
    -> setup_call_cleanup(open(Path, read, S), json_read_dict(S, State), close(S)),
       State.version = 1,
       (get_dict(config_binding,State,Binding) -> true ; throw(error(session_configuration_mismatch,_))),
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
    string_length(Line, Size), Size =< 65536,
    atom_json_dict(Line, Frame, []),
    ui_v1_validate_frame(Frame, ok(_)),
    with_mutex(agentprolog_session, dispatch(Frame)).

dispatch(F) :- F.kind == "negotiate", !,
    P = F.payload,
    memberchk("prolog_agent_ui_v1", P.protocol_versions),
    Supported = ["streaming_text","generic_tools","approvals","questions","verification","usage","traces"],
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
    -> ( Receipt.command == F.command, Receipt.payload =@= F.payload
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
    ensure_inactive,
    ( normalize_space(string(""), Objective)
    -> uuid_string(Id),
       event(agent_event(question_required, Id, "What would you like the agent to do?", [])),
       update(_{phase:"awaiting_question"})
    ; start(Objective)
    ).
execute_command(F, _{accepted:true}) :- F.command == "session.resume", !,
    ensure_inactive, checkpoint(S),
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

start(Objective) :-
    uuid_string(Run), checkpoint(S), executor(Config), Profile = Config.profile,
    Budget = Config.budget,
    ui_v1_initial_view(S.session_id, Empty), put_dict(at_seq, Empty, S.view.at_seq, View),
    update(_{view:View}), snapshot(NewSnapshot), write_frame(NewSnapshot),
    update(_{phase:"running", run_id:Run, objective:Objective, candidate:"", approval_id:"", evidence:[], document:null}),
    event(agent_event(run_started, _{run_id:Run, workspace_id:S.workspace_id,
          objective:Objective, profile:Profile, budget:Budget})),
    rlm_cancellation_token(Token), assertz(run_token(Run,Token)),
    assertz(worker_state(Run,pending)),
    rlm_async_submit(agentprolog_session:work(Run, Objective), Future),
    assertz(active(Run, Future)).

work(Run, Objective, done) :-
    setup_call_cleanup(true,
      (begin_work(Run) -> work_body(Run,Objective) ; true),
      end_work(Run)).
begin_work(Run) :-
    with_mutex(agentprolog_session,
      (checkpoint(S), S.run_id == Run, S.phase == "running",
       retractall(worker_state(Run,_)),assertz(worker_state(Run,running)))).
end_work(Run) :-
    with_mutex(agentprolog_session,
      (release_run_state(Run),
       checkpoint(S),
       (S.run_id == Run, S.phase == "cancelling"
        -> finish(_{status:"cancelled",cleanup_confirmed:true}) ; true))).
release_run_state(Run) :-
    retractall(worker_state(Run,_)), retractall(run_token(Run,_)).
request_stop(Run) :-
    update(_{phase:"cancelling"}),
    event(agent_event(verification,"cancellation",_{status:"requested",cleanup_confirmed:false})),
    (pending_native(Run,Id,_,Queue)
     -> event(agent_event(approval_resolved,Id,"deny")), thread_send_message(Queue,decision(cancel)) ; true),
    (run_token(Run,Token) -> rlm_cancel(Token) ; true),
    (active(Run,Future) -> rlm_future_cancel(Future,_) ; true),
    (worker_state(Run,running) -> true
     ; finish(_{status:"cancelled",cleanup_confirmed:true}), release_run_state(Run)).
work_body(Run,Objective) :-
    executor(Config),
    catch((native_execute(Config, Objective, Run, Outcome) -> true ; Outcome=error(failed)), _, Outcome=error(exception)),
    with_mutex(agentprolog_session,
      catch((complete(Run, Outcome) -> true ; fail_run(Run)), _, fail_run(Run))).

native_execute(Config, Objective, Run, Outcome) :-
    setup_call_cleanup(tool_registry_create(Registry),
      (forall(member(tool(Schema, Handler), Config.tools),
         (observed_binding(Handler,Run,Schema.name,Observed), tool_register(Registry, Schema, Observed, ok(_)))),
       ((memberchk(model_handler(_),Config.runtime_options);memberchk(planner_handler(_),Config.runtime_options)) -> Stream=[]
        ; Stream=[text_delta_handler(prolog_agent_ui_facade:ui_stream_handler(Run,agentprolog_session:session_event(Run)))]),
       (run_token(Run,Token) -> Cancel=[cancel_token(Token)] ; Cancel=[]),
       append(Stream,Cancel,Controls),
       append(Controls,[tool_registry(Registry),capabilities(Config.capabilities),budget(Config.budget)|Config.runtime_options],Options),
       (get_dict(mode,Config,Mode) -> true ; Mode=direct),
       native_mode(Mode,Objective,Options,Initial), native_continuation(Run,Initial,Outcome)),
      tool_registry_destroy(Registry)).

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
                 tool_handler(Preflight,agentprolog_session:observed_execute(Execute,Run,Name))) :- !.
observed_binding(Handler,Run,Name,agentprolog_session:observed_execute(Handler,Run,Name)).
observed_execute(Handler,Run,Name,Args,Value) :-
    uuid_string(Id), atom_string(Name,ToolName),
    session_event(Run,agent_event(tool_started,Id,ToolName,Args)),
    catch((call(Handler,Args,Value) -> true ; throw(error(tool_handler_failed,_))),Error,
      (session_event(Run,agent_event(tool_finished,Id,_{status:"failed"})),throw(Error))),
    session_event(Run,agent_event(tool_output,Id,Value)),
    session_event(Run,agent_event(tool_finished,Id,_{status:"ok"})).

session_event(Run, Event) :-
    with_mutex(agentprolog_session,
        ( (checkpoint(S) -> true ; S=_{run_id:"",phase:"idle"}), (S.run_id == Run, S.phase == "running"
         -> bounded_event(Event, Bounded), event(Bounded) ; true))).

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
       ; safe_failure(Outcome,Failure), finish(Failure))
    ; true).

provider_route(Result) :-
    (get_dict(response,Result,Response), is_dict(Response)
     -> findall(Key-Text,(member(Key,[provider,requested_model,selected_model]),
          get_dict(Key,Response,Value), route_text(Value,Text)),Pairs),
        (Pairs == [] -> true
         ; dict_pairs(Route,_,Pairs), put_dict(kind,Route,"provider_route",Trace),event(agent_event(trace,Trace)))
     ; true).
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
      cancelled,timeout,capability_error,invalid_request,effect_store_required,approval_required,runtime,completion,provider,
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
    update(_{phase:Outcome.status,native_pending:false}), event(agent_event(run_finished, Outcome)).

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
    Receipt = _{request_id:F.request_id, command:F.command, payload:F.payload, result:Result},
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
    Receipt = _{request_id:F.request_id, command:F.command, payload:F.payload, result:Result},
    append(S.receipts, [Receipt], Receipts), update(_{receipts:Receipts}).
same_request(Id, Receipt) :- Receipt.request_id == Id.
reject_receipt(F, Code) :-
    checkpoint(S), ui_v1_error_frame(S.session_id, F.request_id, Code, "Command rejected", Result),
    Receipt = _{request_id:F.request_id, command:F.command, payload:F.payload, result:Result},
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
