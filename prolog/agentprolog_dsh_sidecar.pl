:- module(agentprolog_dsh_sidecar, [main/1]).

:- use_module(library(http/json)).
:- use_module(library(readutil)).
:- use_module(library(rlm_chain), []).
:- use_module(library(rlm_completion), []).
:- use_module(library(rlm_conversation), []).
:- use_module(library(rlm_conversation_runtime), []).

:- dynamic sidecar_store/1.
:- dynamic sidecar_session/2.
:- dynamic sidecar_turn/3.
:- dynamic sidecar_cancelled/2.

:- initialization(main, main).

protocol_version(1).

main(_) :-
    setup_call_cleanup(
        open_runtime,
        request_loop,
        close_runtime).

open_runtime :-
    rlm_conversation:conversation_store_open(memory, Outcome),
    require_ok(store_open, Outcome, Store),
    assertz(sidecar_store(Store)).

close_runtime :-
    cancel_all_turns,
    (   retract(sidecar_store(Store))
    ->  rlm_conversation:conversation_store_close(Store, _)
    ;   true
    ),
    retractall(sidecar_session(_, _)),
    retractall(sidecar_turn(_, _, _)),
    retractall(sidecar_cancelled(_, _)).

request_loop :-
    read_line_to_string(user_input, Line),
    (   Line == end_of_file
    ->  true
    ;   Line == ""
    ->  request_loop
    ;   handle_line(Line),
        request_loop
    ).

handle_line(Line) :-
    catch(( atom_string(Atom, Line),
            atom_json_dict(Atom, Frame, []),
            dispatch(Frame)
          ),
          Error,
          write_uncorrelated_error(Error)).

dispatch(Frame) :-
    require_request_frame(Frame),
    Operation = Frame.operation,
    dispatch_operation(Operation, Frame).

dispatch_operation("runtime.describe", Frame) :- !,
    protocol_version(Version),
    reply_ok(Frame,
             _{protocol_version:Version,
               runtime:"prolog-rlm",
               transport:"ndjson-stdio",
               canonical_turn:"rlm_conversation_runtime:conversation_turn/4",
               capabilities:_{conversation:true,
                              cancellation:true,
                              agent_factory:true,
                              evolution:false}}).
dispatch_operation("session.start", Frame) :- !,
    session_start(Frame).
dispatch_operation("session.turn", Frame) :- !,
    session_turn(Frame).
dispatch_operation("session.cancel", Frame) :- !,
    session_cancel(Frame).
dispatch_operation("session.inspect", Frame) :- !,
    session_inspect(Frame).
dispatch_operation(Operation, Frame) :-
    reply_error(Frame, "unknown_operation",
                _{message:"operation is not implemented by the AgentProlog core sidecar",
                  operation:Operation}).

session_start(Frame) :-
    SessionId = Frame.session_id,
    (   sidecar_session(SessionId, _)
    ->  reply_ok(Frame, _{started:false, already_started:true})
    ;   sidecar_store(Store),
        rlm_conversation:conversation_create(Store, [id(SessionId)], Outcome),
        (   Outcome = ok(Conversation)
        ->  assertz(sidecar_session(SessionId, Conversation)),
            reply_ok(Frame, _{started:true, already_started:false})
        ;   reply_runtime_outcome(Frame, session_start, Outcome)
        )
    ).

session_turn(Frame) :-
    SessionId = Frame.session_id,
    (   sidecar_session(SessionId, Conversation)
    ->  true
    ;   reply_error(Frame, "session_not_found",
                    _{message:"session.start must succeed before session.turn"}),
        !,
        fail
    ),
    (   sidecar_turn(SessionId, _, _)
    ->  reply_error(Frame, "session_busy",
                    _{message:"only one canonical turn may execute per session"})
    ;   rlm_completion:rlm_cancellation_token(Token),
        RequestId = Frame.request_id,
        assertz(sidecar_turn(SessionId, RequestId, Token)),
        catch(thread_create(run_turn(Frame, Conversation, Token), _, [detached(true)]),
              Error,
              ( retractall(sidecar_turn(SessionId, RequestId, Token)),
                reply_exception(Frame, turn_start, Error) ))
    ).

run_turn(Frame, Conversation, Token) :-
    SessionId = Frame.session_id,
    RequestId = Frame.request_id,
    setup_call_cleanup(
        true,
        run_turn_guarded(Frame, Conversation, Token),
        ( retractall(sidecar_turn(SessionId, RequestId, Token)),
          retractall(sidecar_cancelled(SessionId, RequestId)) )).

run_turn_guarded(Frame, Conversation, Token) :-
    catch(run_turn_call(Frame, Conversation, Token, Outcome),
          Error,
          Outcome = exception(Error)),
    (   sidecar_cancelled(Frame.session_id, Frame.request_id)
    ->  reply_status(Frame, "cancelled", _{},
                     _{code:"cancelled", message:"canonical Prolog-RLM turn cancelled"})
    ;   Outcome = ok(Turn)
    ->  turn_payload(Frame, Turn, Payload),
        reply_ok(Frame, Payload)
    ;   Outcome = error(Error)
    ->  safe_term_string(Error, Text),
        reply_error(Frame, "turn_failed", _{message:Text})
    ;   Outcome = exception(Error)
    ->  reply_exception(Frame, turn, Error)
    ;   safe_term_string(Outcome, Text),
        reply_error(Frame, "invalid_turn_outcome", _{message:Text})
    ).

run_turn_call(Frame, Conversation, Token, Outcome) :-
    payload_dict(Frame, Payload),
    require_payload_text(Payload, text, Text),
    turn_provider(Payload, Provider, Model),
    CompletionOptions = [ provider(Provider),
                          provider_name(openrouter),
                          cancel_token(Token),
                          session_id(Frame.session_id)
                        ],
    rlm_conversation_runtime:conversation_turn(
        Conversation,
        message(user, Text),
        [completion_options(CompletionOptions)],
        Outcome),
    nb_setval(agentprolog_dsh_last_model, Model).

turn_provider(Payload, Provider, Model) :-
    (   get_dict(provider, Payload, RequestedProvider),
        RequestedProvider \== null,
        RequestedProvider \== "openrouter"
    ->  throw(error(unsupported_provider(RequestedProvider), _))
    ;   true
    ),
    (   get_dict(model, Payload, Model0),
        string(Model0),
        Model0 \== ""
    ->  atom_string(Model, Model0)
    ;   rlm_chain:default_openrouter_model(Model)
    ),
    rlm_chain:openrouter_provider(Model, Provider).

turn_payload(_Frame, Turn, Payload) :-
    AssistantText = Turn.assistant.content,
    (   nb_current(agentprolog_dsh_last_model, Model)
    ->  atom_string(Model, ModelText)
    ;   ModelText = "unknown"
    ),
    (   get_dict(completion, Turn, Completion),
        is_dict(Completion),
        get_dict(usage, Completion, Usage),
        is_dict(Usage)
    ->  UsageField = _{usage:Usage}
    ;   UsageField = _{}
    ),
    put_dict(UsageField,
             _{text:AssistantText, provider:"openrouter", model:ModelText},
             Payload).

session_cancel(Frame) :-
    SessionId = Frame.session_id,
    findall(RequestId-Token,
            sidecar_turn(SessionId, RequestId, Token),
            Active),
    cancel_turns(SessionId, Active),
    length(Active, Count),
    reply_ok(Frame, _{accepted:Count > 0, active_turns:Count}).

cancel_turns(_, []).
cancel_turns(SessionId, [RequestId-Token|Rest]) :-
    (   sidecar_cancelled(SessionId, RequestId)
    ->  true
    ;   assertz(sidecar_cancelled(SessionId, RequestId))
    ),
    rlm_completion:rlm_cancel(Token),
    cancel_turns(SessionId, Rest).

cancel_all_turns :-
    findall(SessionId-RequestId-Token,
            sidecar_turn(SessionId, RequestId, Token),
            Turns),
    cancel_all_turns_(Turns).

cancel_all_turns_([]).
cancel_all_turns_([SessionId-RequestId-Token|Rest]) :-
    ( sidecar_cancelled(SessionId, RequestId) -> true
    ; assertz(sidecar_cancelled(SessionId, RequestId)) ),
    catch(rlm_completion:rlm_cancel(Token), _, true),
    cancel_all_turns_(Rest).

session_inspect(Frame) :-
    SessionId = Frame.session_id,
    (   sidecar_session(SessionId, Conversation)
    ->  rlm_conversation:conversation_stats(Conversation, Outcome),
        (   Outcome = ok(Stats)
        ->  ( sidecar_turn(SessionId, _, _) -> Busy = true ; Busy = false ),
            reply_ok(Frame, _{session_id:SessionId, busy:Busy, stats:Stats})
        ;   reply_runtime_outcome(Frame, inspect, Outcome)
        )
    ;   reply_error(Frame, "session_not_found", _{message:"unknown session"})
    ).

require_request_frame(Frame) :-
    ( is_dict(Frame) -> true ; throw(error(expected_object, _)) ),
    protocol_version(Version),
    require_exact(Frame, version, Version),
    require_string(Frame, request_id, _),
    require_string(Frame, session_id, _),
    require_string(Frame, operation, _),
    payload_dict(Frame, _).

payload_dict(Frame, Payload) :-
    (   get_dict(payload, Frame, Payload0)
    ->  ( is_dict(Payload0) -> Payload = Payload0 ; throw(error(invalid_payload, _)) )
    ;   Payload = _{}
    ).

require_payload_text(Payload, Key, Value) :-
    (   get_dict(Key, Payload, Value), string(Value), Value \== ""
    ->  true
    ;   throw(error(invalid_payload_field(Key), _))
    ).

require_exact(Dict, Key, Expected) :-
    ( get_dict(Key, Dict, Actual), Actual == Expected -> true
    ; throw(error(invalid_field(Key), _)) ).

require_string(Dict, Key, Value) :-
    ( get_dict(Key, Dict, Value), string(Value), Value \== "" -> true
    ; throw(error(invalid_string_field(Key), _)) ).

reply_runtime_outcome(Frame, _, ok(Value)) :- !,
    reply_ok(Frame, _{value:Value}).
reply_runtime_outcome(Frame, Stage, error(Error)) :- !,
    safe_term_string(Error, Text),
    atom_string(Stage, StageText),
    reply_error(Frame, "runtime_error", _{stage:StageText, message:Text}).
reply_runtime_outcome(Frame, Stage, Outcome) :-
    safe_term_string(Outcome, Text),
    atom_string(Stage, StageText),
    reply_error(Frame, "runtime_error", _{stage:StageText, message:Text}).

reply_ok(Frame, Payload) :-
    reply_status(Frame, "ok", Payload, _{}).

reply_error(Frame, Code, Error0) :-
    put_dict(code, Error0, Code, Error),
    reply_status(Frame, "error", _{}, Error).

reply_exception(Frame, Stage, Exception) :-
    safe_term_string(Exception, Text),
    atom_string(Stage, StageText),
    reply_error(Frame, "runtime_exception", _{stage:StageText, message:Text}).

reply_status(Frame, Status, Payload, Error) :-
    protocol_version(Version),
    Base = _{version:Version,
             request_id:Frame.request_id,
             session_id:Frame.session_id,
             status:Status,
             payload:Payload},
    ( Status == "ok" -> Response = Base ; put_dict(error, Base, Error, Response) ),
    write_frame(Response).

write_uncorrelated_error(Error) :-
    safe_term_string(Error, Text),
    format(user_error, 'AgentProlog sidecar rejected frame: ~s~n', [Text]),
    flush_output(user_error).

write_frame(Frame) :-
    with_mutex(agentprolog_dsh_stdout,
               ( json_write_dict(current_output, Frame, [width(0)]),
                 nl,
                 flush_output )).

safe_term_string(Term, Text) :-
    term_string(Term, Text, [quoted(true), numbervars(true), max_depth(8)]).

require_ok(_, ok(Value), Value) :- !.
require_ok(Stage, Outcome, _) :-
    throw(error(agentprolog_sidecar_stage_failed(Stage, Outcome), _)).
