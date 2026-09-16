:- use_module('agentprolog_dsh_sidecar.pl', []).
:- use_module(library(plunit)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_server)).
:- use_module(library(http/json)).

:- dynamic fixture_sse_body/1.

:- http_handler(root(sse), fixture_sse_handler, [method(post)]).

fixture_sse_handler(_) :-
    fixture_sse_body(Body),
    format('Content-type: text/event-stream\n\n~s', [Body]).

with_fixture_server(Body, Goal) :-
    setup_call_cleanup(
        assertz(fixture_sse_body(Body)),
        setup_call_cleanup(http_server(http_dispatch, [port(Port)]),
                           call(Goal, Port),
                           http_stop_server(Port, [])),
        retractall(fixture_sse_body(_))).

direct_planner_fixture_body(Body) :-
    Chunk = _{id:"stream-1", model:"fixture",
              choices:[_{index:0,
                         delta:_{role:assistant,
                                 content:"{\"mode\":\"direct\",\"answer\":\"Hello\"}"},
                         finish_reason:stop}]},
    with_output_to(string(Json), json_write_dict(current_output, Chunk, [width(0)])),
    format(string(Body), 'data: ~s~ndata: [DONE]~n', [Json]).

fixture_conversation_turn(Output, Outcome, Port) :-
    format(atom(Endpoint), 'http://127.0.0.1:~d/sse', [Port]),
    Provider = provider(openai_compatible,
                        [endpoint(Endpoint), credential(none), model(fixture)]),
    Frame = _{session_id:"session-direct", request_id:"turn-direct"},
    agentprolog_dsh_sidecar:base_completion_options(token_direct, Frame, Provider, Base),
    agentprolog_dsh_sidecar:mode_options("direct", Base, Options),
    rlm_conversation:conversation_store_open(memory, ok(Store)),
    setup_call_cleanup(
        rlm_conversation:conversation_create(Store, [id("session-direct")], ok(Conversation)),
        with_output_to(string(Output),
                       ( rlm_conversation_runtime:conversation_turn(
                             Conversation, message(user, "hello"),
                             [completion_options(Options)], Outcome),
                         (   Outcome = ok(Turn)
                         ->  agentprolog_dsh_sidecar:reply_ok(
                                 Frame, _{text:Turn.assistant.content})
                         ;   agentprolog_dsh_sidecar:reply_error(
                                 Frame, "turn_failed", _{message:"failed"})
                         ) )),
        rlm_conversation:conversation_store_close(Store, _)).

frame_lines(Output, Frames) :-
    split_string(Output, "\n", "\n", Lines),
    maplist(frame_json, Lines, Frames).

frame_json(Line, Frame) :-
    atom_string(Atom, Line),
    atom_json_dict(Atom, Frame, []).

:- begin_tests(sidecar_mode_options).

test(recursive_mode_retains_provider_session_and_cancellation) :-
    Base = [provider(provider_sentinel),
            provider_name(openrouter),
            cancel_token(token_sentinel),
            session_id(session_sentinel)],
    agentprolog_dsh_sidecar:mode_options("symbolic-recursive", Base, Options),
    forall(member(Option, Base), memberchk(Option, Options)),
    memberchk(child_capabilities(ChildCapabilities), Options),
    memberchk(rlm, ChildCapabilities),
    memberchk(budget(Budget), Options),
    Budget.max_recursion_depth =:= 2.

test(keyless_conversation_emits_planner_delta_before_distinct_final_answer) :-
    direct_planner_fixture_body(Body),
    with_fixture_server(Body, fixture_conversation_turn(Output, Outcome)),
    Outcome = ok(Turn),
    assertion(Turn.assistant.content == "Hello"),
    frame_lines(Output, Frames),
    Frames = [Started, Delta, Completed, Reply],
    assertion(Started.event == "message_started"),
    assertion(Started.sequence =:= 0),
    assertion(Delta.event == "text_delta"),
    assertion(Delta.sequence =:= 1),
    assertion(Delta.data.operation == "planner"),
    assertion(Delta.data.delta == "{\"mode\":\"direct\",\"answer\":\"Hello\"}"),
    assertion(Completed.event == "message_completed"),
    assertion(Completed.sequence =:= 2),
    assertion(Started.data.message_id == Delta.data.message_id),
    assertion(Delta.data.message_id == Completed.data.message_id),
    assertion(Reply.status == "ok"),
    assertion(Reply.payload.text == "Hello").


:- end_tests(sidecar_mode_options).
