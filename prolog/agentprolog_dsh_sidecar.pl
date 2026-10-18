:- module(agentprolog_dsh_sidecar, [main/1]).

/** <module> AgentProlog DeepSeek Harness sidecar

Persistent Prolog runtime behind the AgentProlog DSH plugin. One canonical
Prolog-RLM trajectory per `session.turn`, resolved through the session's
reasoning mode. Modes are canonical state transitions, not prompt text:

  * `direct`      — bounded non-symbolic conversation: no `rlm` capability,
                    recursion depth capped at 0;
  * `symbolic`    — the root direct-or-plan supervisor with typed plans and a
                    single recursion level (runtime defaults);
  * `symbolic-recursive` — child plans may select symbolic work themselves,
                    bounded by an explicit `max_recursion_depth` budget and
                    prolog-rlm's own iteration ceilings.

All execution uses public prolog-rlm APIs (`rlm_conversation`,
`rlm_conversation_runtime`, `rlm_completion`, `rlm_chain`). Crash,
cancellation, and malformed frames fail closed; nothing silently restarts.
*/

:- use_module(library(http/json)).
:- use_module(library(readutil)).
:- use_module(library(lists)).
:- use_module(library(rlm_chain), []).
:- use_module(library(rlm_artifact), []).
:- use_module(library(rlm_conversation_warm), []).
:- use_module(library(rlm_completion), []).
:- use_module(library(rlm_conversation), []).
:- use_module(library(rlm_conversation_runtime), []).
:- use_module(library(rlm_skill), []).
:- use_module(library(rlm_tool), []).

:- dynamic sidecar_store/1.
:- dynamic sidecar_warm_store/1.
:- dynamic sidecar_compaction_status/2.
:- dynamic sidecar_session/2.
:- dynamic sidecar_mode/2.
:- dynamic sidecar_turn/3.
:- dynamic sidecar_cancelled/2.
:- dynamic sidecar_event_seq/3.
:- dynamic sidecar_skill_catalog/1.
:- dynamic sidecar_tool_registry/2.

:- initialization(main, main).

protocol_version(1).

valid_mode("direct").
valid_mode("direct-rlm").
valid_mode("symbolic").
valid_mode("symbolic-recursive").

main(_) :-
    setup_call_cleanup(open_runtime, request_loop, close_runtime).

open_runtime :-
    conversation_store_spec(StoreSpec),
    rlm_conversation:conversation_store_open(StoreSpec, Outcome),
    require_ok(store_open, Outcome, Store),
    assertz(sidecar_store(Store)),
    warm_store_spec(WarmSpec),
    rlm_artifact:artifact_store_open(WarmSpec, ArtifactOutcome),
    require_ok(warm_store_open, ArtifactOutcome, WarmStore),
    assertz(sidecar_warm_store(WarmStore)),
    % The catalog starts from the runtime default (prolog-rlm's core
    % operating skills when shipped with the pack); loaded project roots
    % merge on top instead of replacing the core skills.
    rlm_skill:skill_default_catalog(DefaultOutcome),
    require_skill_outcome(DefaultOutcome, DefaultCatalog),
    assertz(sidecar_skill_catalog(DefaultCatalog)).

conversation_store_spec(persist(File)) :-
    getenv('AGENTPROLOG_CONVERSATION_STORE', File),
    File \== "",
    !.
conversation_store_spec(memory).

warm_store_spec(persist(WarmFile)) :-
    getenv('AGENTPROLOG_CONVERSATION_STORE', File),
    File \== "", !,
    ( string(File) -> FileText = File ; atom_string(File, FileText) ),
    string_concat(FileText, ".warm.db", WarmFile).
warm_store_spec(memory).

close_runtime :-
    cancel_all_turns,
    (   retract(sidecar_warm_store(WarmStore))
    ->  rlm_artifact:artifact_store_close(WarmStore, _)
    ;   true
    ),
    (   retract(sidecar_store(Store))
    ->  rlm_conversation:conversation_store_close(Store, _)
    ;   true
    ),
    retractall(sidecar_session(_, _)),
    retractall(sidecar_compaction_status(_, _)),
    retractall(sidecar_mode(_, _)),
    retractall(sidecar_turn(_, _, _)),
    retractall(sidecar_cancelled(_, _)),
    retractall(sidecar_event_seq(_, _, _)),
    retractall(sidecar_skill_catalog(_)),
    forall(retract(sidecar_tool_registry(_, Registry)),
           rlm_tool:tool_registry_destroy(Registry)).

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
            (   dispatch(Frame)
            ->  true
            ;   write_uncorrelated_error(error(unanswered_dispatch, context(agentprolog_dsh_sidecar, Line)))
            )
          ),
          Error,
          write_uncorrelated_error(Error)).

dispatch(Frame) :-
    require_request_frame(Frame),
    dispatch_operation(Frame.operation, Frame).

dispatch_operation("runtime.describe", Frame) :- !,
    protocol_version(Version),
    reply_ok(Frame,
             _{protocol_version:Version,
               runtime:"prolog-rlm",
               transport:"ndjson-stdio",
               canonical_turn:"rlm_conversation_runtime:conversation_turn/4",
               modes:["direct", "direct-rlm", "symbolic", "symbolic-recursive"],
               capabilities:_{conversation:true,
                              cancellation:true,
                              agent_factory:true,
                              evolution:false,
                              modes:true,
                              skills:true,
                              tools:true,
                              context_kb:true}}).
dispatch_operation("session.start", Frame) :- !,
    session_start(Frame).
dispatch_operation("session.mode", Frame) :- !,
    session_mode(Frame).
dispatch_operation("session.turn", Frame) :- !,
    session_turn(Frame).
dispatch_operation("session.cancel", Frame) :- !,
    session_cancel(Frame).
dispatch_operation("session.inspect", Frame) :- !,
    session_inspect(Frame).
dispatch_operation("session.kb", Frame) :- !,
    session_kb(Frame).
dispatch_operation("skill.load", Frame) :- !,
    skill_load(Frame).
dispatch_operation("skill.list", Frame) :- !,
    skill_list(Frame).
dispatch_operation("skill.reset", Frame) :- !,
    skill_reset(Frame).
dispatch_operation("tool.list", Frame) :- !,
    tool_list(Frame).
dispatch_operation(Operation, Frame) :-
    reply_error(Frame, "unknown_operation",
                _{message:"operation is not implemented by the AgentProlog core sidecar",
                  operation:Operation}).

session_start(Frame) :-
    catch(session_start_(Frame), Error, reply_exception(Frame, session_start, Error)).

session_start_(Frame) :-
    SessionId = Frame.session_id,
    (   sidecar_session(SessionId, _)
    ->  sidecar_mode(SessionId, Mode),
        reply_ok(Frame, _{started:false, already_started:true, resumed:false, mode:Mode})
    ;   sidecar_store(Store),
        session_project_root(Frame, Root),
        session_conversation(Store, SessionId, Root, Conversation, Resumed),
        session_tool_registry(Root, Registry),
        (   nonvar(Conversation)
        ->  assertz(sidecar_tool_registry(SessionId, Registry)),
            assertz(sidecar_session(SessionId, Conversation)),
            assertz(sidecar_mode(SessionId, "symbolic")),
            reply_ok(Frame, _{started:true, already_started:false, resumed:Resumed, mode:"symbolic"})
        )
    ).

session_conversation(Store, SessionId, Root, Conversation, Resumed) :-
    rlm_conversation:conversation_open(Store, SessionId, OpenOutcome),
    (   OpenOutcome = ok(Existing)
    ->  (   get_dict(metadata, Existing, Metadata),
            get_dict(project_root, Metadata, Root)
        ->  Conversation = Existing,
            Resumed = true
        ;   throw(error(session_project_root_mismatch(SessionId), _))
        )
    ;   OpenOutcome = error(Error),
        get_dict(detail, Error, not_found(_))
    ->  rlm_conversation:conversation_create(
            Store,
            [id(SessionId), metadata(_{project_root:Root})],
            CreateOutcome),
        require_ok(session_create, CreateOutcome, Conversation),
        Resumed = false
    ;   require_ok(session_open, OpenOutcome, Conversation),
        Resumed = true
    ).

session_project_root(Frame, Root) :-
    payload_dict(Frame, Payload),
    (   get_dict(cwd, Payload, Cwd), Cwd \== null
    ->  ( string(Cwd), Cwd \== "" -> true
        ; throw(error(invalid_project_root(Cwd), _)) )
    ;   Cwd = '.'
    ),
    absolute_file_name(Cwd, Root,
                       [file_type(directory), access(read), file_errors(error)]).

session_tool_registry(Root, Registry) :-
    rlm_tool:tool_registry_create(Registry),
    (   rlm_tool:register_project_read_tool(Registry, Root,
                                            [max_file_bytes(8192)], ok(_))
    ->  true
    ;   rlm_tool:tool_registry_destroy(Registry),
        throw(error(project_read_registration_failed(Root), _))
    ).

%% session.mode: canonical reasoning-mode transition for one session.
session_mode(Frame) :-
    catch(session_mode_(Frame),
          Error,
          reply_exception(Frame, session_mode, Error)).

session_mode_(Frame) :-
    SessionId = Frame.session_id,
    payload_dict(Frame, Payload),
    require_payload_text(Payload, mode, Mode),
    (   valid_mode(Mode)
    ->  true
    ;   throw(error(invalid_mode(Mode), _))
    ),
    (   sidecar_session(SessionId, _)
    ->  (   sidecar_mode(SessionId, Previous)
        ->  true
        ;   Previous = "symbolic"
        ),
        retractall(sidecar_mode(SessionId, _)),
        assertz(sidecar_mode(SessionId, Mode)),
        reply_ok(Frame, _{mode:Mode, previous:Previous})
    ;   reply_error(Frame, "session_not_found",
                    _{message:"session.start must succeed before session.mode"})
    ).

session_turn(Frame) :-
    SessionId = Frame.session_id,
    (   \+ sidecar_session(SessionId, _)
    ->  reply_error(Frame, "session_not_found",
                    _{message:"session.start must succeed before session.turn"})
    ;   sidecar_turn(SessionId, _, _)
    ->  reply_error(Frame, "session_busy",
                    _{message:"only one canonical turn may execute per session"})
    ;   sidecar_session(SessionId, Conversation),
        catch(( turn_mode(Frame, Mode),
                start_turn_worker(Frame, Conversation, Mode) ),
              Error,
              reply_exception(Frame, turn_start, Error))
    ).

%% Turn mode resolution order: explicit payload override, session state,
%% else symbolic. Unknown modes are rejected before any provider call.
turn_mode(Frame, Mode) :-
    payload_dict(Frame, Payload),
    (   get_dict(mode, Payload, Requested),
        Requested \== null
    ->  (   valid_mode(Requested)
        ->  Mode = Requested
        ;   throw(error(invalid_mode(Requested), _))
        )
    ;   sidecar_mode(Frame.session_id, Mode)
    ->  true
    ;   Mode = "symbolic"
    ).

start_turn_worker(Frame, Conversation, Mode) :-
    rlm_completion:rlm_cancellation_token(Token),
    SessionId = Frame.session_id,
    RequestId = Frame.request_id,
    assertz(sidecar_turn(SessionId, RequestId, Token)),
    catch(thread_create(run_turn(Frame, Conversation, Token, Mode), _, [detached(true)]),
          Error,
          ( retractall(sidecar_turn(SessionId, RequestId, Token)),
            reply_exception(Frame, turn_start, Error) )).

run_turn(Frame, Conversation, Token, Mode) :-
    SessionId = Frame.session_id,
    RequestId = Frame.request_id,
    emit_event(SessionId, RequestId, "turn_started", _{mode:Mode}),
    setup_call_cleanup(
        true,
        run_turn_guarded(Frame, Conversation, Token, Mode),
        ( retractall(sidecar_turn(SessionId, RequestId, Token)),
          retractall(sidecar_cancelled(SessionId, RequestId)),
          retractall(sidecar_event_seq(SessionId, RequestId, _)) )).

run_turn_guarded(Frame, Conversation, Token, Mode) :-
    catch(run_turn_call(Frame, Conversation, Token, Mode, Outcome, Model, Compaction),
          Error,
          Outcome = exception(Error)),
    (   sidecar_cancelled(Frame.session_id, Frame.request_id)
    ->  reply_status(Frame, "cancelled", _{},
                     _{code:"cancelled", message:"canonical Prolog-RLM turn cancelled"})
    ;   Outcome = ok(Turn)
    ->  turn_payload(Turn, Model, Mode, Compaction, Payload),
        emit_event(Frame.session_id, Frame.request_id, "turn_finished", _{status:"ok", mode:Mode}),
        reply_ok(Frame, Payload)
    ;   Outcome = error(Error)
    ->  turn_error_details(Error, Code, Details),
        emit_event(Frame.session_id, Frame.request_id, "turn_finished", _{status:"error", mode:Mode, code:Code}),
        reply_error(Frame, Code, Details)
    ;   Outcome = exception(Error)
    ->  safe_term_string(Error, Text),
        emit_event(Frame.session_id, Frame.request_id, "turn_finished", _{status:"error", mode:Mode, code:"runtime_exception"}),
        reply_exception(Frame, turn, Error)
    ;   safe_term_string(Outcome, Text),
        reply_error(Frame, "invalid_turn_outcome", _{message:Text})
    ).

run_turn_call(Frame, Conversation, Token, Mode, Outcome, Model, Compaction) :-
    payload_dict(Frame, Payload),
    require_payload_text(Payload, text, Text),
    turn_provider(Payload, _, Model),
    completion_options(Mode, Payload, Token, Frame, CompletionOptions),
    sidecar_warm_store(WarmStore),
    auto_warm_options(CompletionOptions, AutoWarm),
    mode_strategy(Mode, Strategy),
    rlm_conversation_runtime:conversation_turn(
        Conversation, message(user, Text),
        [strategy(Strategy),
         context_options([warm_store(WarmStore), auto_warm(AutoWarm)]),
         completion_options(CompletionOptions)], Outcome),
    compaction_status(Outcome, Compaction),
    retractall(sidecar_compaction_status(Frame.session_id, _)),
    assertz(sidecar_compaction_status(Frame.session_id, Compaction)).

mode_strategy("direct", native) :- !.
mode_strategy("direct-rlm", native) :- !.
mode_strategy(_, symbolic).

auto_warm_options(_, disabled) :-
    getenv('AGENTPROLOG_AUTO_WARM', Flag),
    memberchk(Flag, ['0', false, off]), !.
auto_warm_options(Active, [min_batch_messages(1), max_batch_messages(48),
                           keep_recent_messages(12), completion_options(Safe)]) :-
    compaction_completion_options(Active, Safe).

compaction_status(ok(Turn), Status) :- !,
    Warm = Turn.context.auto_warm,
    ( get_dict(published, Warm, true)
    -> Warm.source_range = range(Start, End),
       ( get_dict(usage, Warm.generation, Usage) -> true ; Usage = _{} ),
       Status = _{state:"published", start:Start, end:End, usage:Usage}
    ; atom_string(Warm.reason, Reason), Status = _{state:Reason}
    ).
compaction_status(error(_), _{state:"turn_failed"}).

%% Warm generation only reads the opaque conversation context. It must not
%% inherit the active coding-agent tool registry, skills, child recursion, or
%% external effects. Keep the user's cancellation token.
compaction_completion_options(Active, Safe) :-
    memberchk(provider(Provider), Active),
    memberchk(cancel_token(Token), Active),
    Safe = [provider(Provider),
            provider_name(openrouter),
            cancel_token(Token),
            capabilities([model(openrouter),
                          context(peek), context(slice), context(search)]),
            child_capabilities([model(openrouter)]),
            budget(_{max_total_tokens:8192,
                     max_model_calls:4,
                     max_recursion_depth:0})].

%% Read-only project KB projection. Warm summaries are untrusted observations,
%% never asserted as executable Prolog clauses or promoted to runtime skills.
session_kb(Frame) :-
    SessionId = Frame.session_id,
    ( sidecar_session(SessionId, Conversation)
    -> sidecar_warm_store(WarmStore),
       rlm_conversation_warm:conversation_warm_list(
           Conversation, WarmStore, [history(false)], Outcome),
       ( Outcome = ok(Artifacts)
       -> Root = Conversation.metadata.project_root,
          findall(Observation,
                  ( member(Artifact, Artifacts),
                    warm_project_observation(Root, Artifact, Observation)
                  ),
                  All),
          length(All, Count),
          ( length(Prefix, 100), append(Prefix, _, All)
          -> Rows = Prefix, Truncated = true
          ;  Rows = All, Truncated = false
          ),
          reply_ok(Frame, _{observations:Rows, count:Count,
                            truncated:Truncated, provenance:"model_claim"})
       ;  reply_runtime_outcome(Frame, kb_list, Outcome)
       )
    ; reply_error(Frame, "session_not_found", _{message:"unknown session"})
    ).

warm_project_observation(Root, Artifact, Observation) :-
    Warm = Artifact.value,
    Generated = Warm.generated,
    Warm.source_range = range(Start, End),
    member(Kind, [facts, decisions, unresolved, entities, topics, files, symbols]),
    get_dict(Kind, Generated, Values),
    member(Text, Values),
    string(Text),
    Observation = _{project_root:Root, kind:Kind, text:Text,
                    start:Start, end:End, artifact_key:Artifact.key,
                    source_class:"model_claim"}.

%% Base completion options shared by every mode.
base_completion_options(Token, Frame, Provider, [provider(Provider),
                                                 provider_name(openrouter),
                                                 cancel_token(Token),
                                                 session_id(Frame.session_id),
                                                 tool_registry(Registry)]) :-
    sidecar_tool_registry(Frame.session_id, Registry).

%% Mode-specific capabilities, child capabilities, and budgets. These are the
%% explicit termination controls: recursion depth 0 and no `rlm` capability
%% make symbolic recursion structurally impossible in direct mode; the
%% recursive mode widens child capabilities and raises the depth ceiling.
completion_options(Mode, Payload, Token, Frame, Options) :-
    turn_provider(Payload, Provider, _),
    base_completion_options(Token, Frame, Provider, Base),
    mode_options(Mode, Base, Options0),
    apply_budget_updates_or_keep(Options0, Payload, Options1),
    enforce_mode_recursion(Mode, Options1, Options2),
    skill_options(Payload, Options2, Options).

apply_budget_updates_or_keep(Options0, Payload, Options) :-
    payload_budget_updates(Payload, Updates),
    (   Updates == none
    ->  Options = Options0
    ;   apply_budget_updates(Options0, Updates, Options)
    ).

%% Skill controls forwarded to the completion supervisor. A non-empty
%% sidecar catalog replaces the default catalog; empty leaves the runtime
%% default (core skills) in place.
skill_options(Payload, Options0, Options) :-
    skill_catalog_option(CatalogOption),
    skill_mode_option(Payload, ModeOption),
    skill_names_option(explicit_skills, Payload, ExplicitOption),
    skill_names_option(disabled_skills, Payload, DisabledOption),
    append([CatalogOption, ModeOption, ExplicitOption, DisabledOption, Options0], Options).

skill_catalog_option([skill_catalog(Catalog)]) :-
    sidecar_skill_catalog(Catalog),
    rlm_skill:skill_catalog_skills(Catalog, [_|_]),
    !.
skill_catalog_option([]).

skill_mode_option(Payload, [skill_mode(Mode)]) :-
    get_dict(skill_mode, Payload, Raw),
    Raw \== null,
    !,
    (   member(Raw, ["on", "off"])
    ->  atom_string(Mode, Raw)
    ;   throw(error(invalid_skill_mode(Raw), _))
    ).
skill_mode_option(_, []).

skill_names_option(Key, Payload, [Option]) :-
    get_dict(Key, Payload, Raw),
    Raw \== null,
    !,
    (   is_list(Raw),
        maplist(skill_name_string, Raw, Names)
    ->  Option =.. [Key, Names]
    ;   throw(error(invalid_skill_names(Key, Raw), _))
    ).
skill_names_option(_, _, []).

skill_name_string(Name, Name) :- string(Name), Name \== "", !.
skill_name_string(Name, _) :- throw(error(invalid_skill_name(Name), _)).

mode_options("direct", Base, Options) :- !,
    append(Base,
           [capabilities([model(openrouter), tool(project_read),
                          context(peek), context(slice), context(search)]),
            child_capabilities([model(openrouter), tool(project_read)]),
            budget(_{max_recursion_depth:0})],
           Options).
mode_options("direct-rlm", Base, Options) :- !,
    % Preserve canonical completion message projection with bounded RLM children.
    append(Base,
           [capabilities([rlm, model(openrouter), tool(project_read),
                          context(peek), context(slice), context(search)]),
            child_capabilities([rlm, model(openrouter), tool(project_read),
                                context(peek), context(slice), context(search)]),
            budget(_{max_recursion_depth:2})],
           Options).
mode_options("symbolic", Base, Options) :- !,
    append(Base,
           [capabilities([rlm, model(openrouter), tool(project_read),
                          context(peek), context(slice), context(search)]),
            child_capabilities([model(openrouter), tool(project_read)]),
            budget(_{max_recursion_depth:1})], Options).
mode_options("symbolic-recursive", Base, Options) :- !,
    mode_options("direct-rlm", Base, Options).

%% Explicit budget updates forwarded from the plugin payload. Absent keys are
%% skipped; present but non-conforming values are rejected before any
%% provider call.
payload_budget_updates(Payload, Updates) :-
    findall(Name-Value,
            (   member(Name, [max_iterations, max_recursion_depth,
                              max_model_calls, max_tool_calls, max_total_tokens]),
                get_dict(Name, Payload, Raw),
                Raw \== null,
                budget_value(Name, Raw, Value)
            ),
            Pairs),
    (   Pairs == []
    ->  Updates = none
    ;   dict_create(Updates, budget_updates, Pairs)
    ).

budget_value(max_recursion_depth, Raw, Value) :-
    (   integer(Raw), Raw >= 0
    ->  Value = Raw
    ;   throw(error(invalid_budget_field(max_recursion_depth, Raw), _))
    ).
budget_value(Name, Raw, Value) :-
    (   integer(Raw), Raw > 0
    ->  Value = Raw
    ;   throw(error(invalid_budget_field(Name, Raw), _))
    ).

apply_budget_updates(Options0, Updates, Options) :-
    rlm_completion:default_completion_budget(Default),
    (   member(budget(Partial), Options0)
    ->  exclude(is_budget_option, Options0, Rest),
        put_dict(Partial, Default, Budget0)
    ;   Budget0 = Default,
        Options0 = Rest
    ),
    put_dict(Updates, Budget0, Budget),
    Options = [budget(Budget)|Rest].

mode_recursion_ceiling("direct", 0).
mode_recursion_ceiling("direct-rlm", 2).

enforce_mode_recursion(Mode, Options, Options) :-
    (   member(budget(Budget), Options),
        get_dict(max_recursion_depth, Budget, Depth),
        mode_recursion_ceiling(Mode, Ceiling),
        Depth > Ceiling
    ->  throw(error(invalid_mode_recursion(Mode, Depth, Ceiling), _))
    ;   true
    ).

is_budget_option(budget(_)).

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

turn_payload(Turn, Model, Mode, Compaction, Payload) :-
    AssistantText = Turn.assistant.content,
    atom_string(Model, ModelText),
    (   get_dict(completion, Turn, Completion),
        is_dict(Completion),
        get_dict(usage, Completion, Usage),
        is_dict(Usage)
    ->  UsageField = _{usage:Usage}
    ;   UsageField = _{}
    ),
    put_dict(UsageField,
             _{text:AssistantText, provider:"openrouter", model:ModelText, mode:Mode,
               meta:_{compaction:Compaction}},
             Payload).

%% Structured error classification: budget exhaustion is surfaced as its own
%% code so callers never parse Prolog terms to distinguish exhausted turns
%% from generic failures.
turn_error_details(Error, "budget_exhausted", Details) :-
    sub_term(Sub, Error),
    is_dict(Sub),
    get_dict(kind, Sub, token_budget_exceeded),
    get_dict(limit, Sub, Limit),
    get_dict(used, Sub, Used),
    integer(Limit), integer(Used), !,
    format(string(Message), "completion token budget exceeded (~d/~d tokens)", [Used, Limit]),
    Details = _{message:Message, kind:"token_budget_exceeded", limit:Limit, used:Used}.
turn_error_details(Error, Code, _{message:Text}) :-
    error_code(Error, Code),
    safe_term_string(Error, Text).

error_code(Error, "budget_exhausted") :-
    ( sub_term(Sub, Error), is_dict(Sub),
      get_dict(kind, Sub, token_budget_exceeded) ), !.
error_code(Error, "budget_exhausted") :-
    contains_ground_term(Error, max_iterations), !.
error_code(Error, "budget_exhausted") :-
    contains_ground_term(Error, max_recursion_depth), !.
error_code(Error, "budget_exhausted") :-
    contains_ground_term(Error, max_model_calls), !.
error_code(Error, "budget_exhausted") :-
    contains_ground_term(Error, max_total_tokens), !.
error_code(_, "turn_failed").

contains_ground_term(Term, Needle) :-
    ground(Term),
    (   Term == Needle
    ->  true
    ;   compound(Term),
        arg(_, Term, Arg),
        contains_ground_term(Arg, Needle)
    ).

session_cancel(Frame) :-
    SessionId = Frame.session_id,
    findall(RequestId-Token,
            sidecar_turn(SessionId, RequestId, Token),
            Active),
    cancel_turns(SessionId, Active),
    length(Active, Count),
    ( Count > 0 -> Accepted = true ; Accepted = false ),
    reply_ok(Frame, _{accepted:Accepted, active_turns:Count}).

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
    ->  (   sidecar_mode(SessionId, Mode)
        ->  true
        ;   Mode = "symbolic"
        ),
        rlm_conversation:conversation_stats(Conversation, Outcome),
        (   Outcome = ok(Stats)
        ->  ( sidecar_turn(SessionId, _, _) -> Busy = true ; Busy = false ),
            ( sidecar_compaction_status(SessionId, C) -> true ; C = _{state:"not_run"} ),
            reply_ok(Frame, _{session_id:SessionId, busy:Busy, mode:Mode,
                              stats:Stats, compaction:C})
        ;   reply_runtime_outcome(Frame, inspect, Outcome)
        )
    ;   reply_error(Frame, "session_not_found", _{message:"unknown session"})
    ).

tool_list(Frame) :-
    SessionId = Frame.session_id,
    (   sidecar_tool_registry(SessionId, Registry)
    ->  rlm_tool:tool_discover(Registry, Schemas),
        findall(_{name:Name, description:Description},
                ( member(Schema, Schemas),
                  atom_string(Schema.name, Name),
                  Description = Schema.description ),
                Tools),
        reply_ok(Frame, _{tools:Tools})
    ;   reply_error(Frame, "session_not_found", _{message:"unknown session"})
    ).

%% Skill loading: roots are admitted into one sidecar-level catalog that is
%% offered to every canonical turn through the completion skill_catalog
%% option. Loading is confined by rlm_skill's bounded-package rules.
skill_load(Frame) :-
    catch(skill_load_(Frame),
          Error,
          reply_exception(Frame, skill_load, Error)).

skill_load_(Frame) :-
    payload_dict(Frame, Payload),
    (   get_dict(roots, Payload, Roots0), is_list(Roots0)
    ->  true
    ;   throw(error(invalid_payload_field(roots), _))
    ),
    maplist(normalize_skill_root, Roots0, Roots),
    sidecar_skill_catalog(Catalog0),
    (   Roots == []
    ->  catalog_skill_summaries(Catalog0, Summaries),
        length(Summaries, Count),
        reply_ok(Frame, _{loaded:Count, skills:Summaries})
    ;   rlm_skill:skill_catalog_load(Roots, [], Outcome),
        require_skill_outcome(Outcome, Loaded),
        rlm_skill:skill_catalog_merge(Catalog0, Loaded, MergeOutcome),
        require_skill_outcome(MergeOutcome, Merged),
        retractall(sidecar_skill_catalog(_)),
        assertz(sidecar_skill_catalog(Merged)),
        catalog_skill_summaries(Merged, Summaries),
        length(Summaries, Count),
        reply_ok(Frame, _{loaded:Count, skills:Summaries})
    ).

normalize_skill_root(Root0, Root) :-
    (   is_dict(Root0),
        get_dict(path, Root0, Path), string(Path), Path \== ""
    ->  true
    ;   throw(error(invalid_skill_root(Root0), _))
    ),
    (   get_dict(source, Root0, Source0), string(Source0), Source0 \== ""
    ->  atom_string(Source, Source0)
    ;   Source = external
    ),
    Root = skill_root(Source, Path).

skill_list(Frame) :-
    catch(( sidecar_skill_catalog(Catalog),
            catalog_skill_summaries(Catalog, Summaries),
            reply_ok(Frame, _{skills:Summaries}) ),
          Error,
          reply_exception(Frame, skill_list, Error)).

skill_reset(Frame) :-
    catch(( rlm_skill:skill_default_catalog(DefaultOutcome),
            require_skill_outcome(DefaultOutcome, DefaultCatalog),
            retractall(sidecar_skill_catalog(_)),
            assertz(sidecar_skill_catalog(DefaultCatalog)),
            catalog_skill_summaries(DefaultCatalog, Summaries),
            reply_ok(Frame, _{skills:Summaries}) ),
          Error,
          reply_exception(Frame, skill_reset, Error)).

require_skill_outcome(ok(Value), Value) :- !.
require_skill_outcome(error(Error), _) :-
    throw(error(skill_runtime_error(Error), _)).

catalog_skill_summaries(Catalog, Summaries) :-
    rlm_skill:skill_catalog_skills(Catalog, Skills),
    maplist(skill_summary, Skills, Summaries).

skill_summary(Skill, Summary) :-
    json_text(Skill.name, Name),
    (   get_dict(description, Skill, Description)
    ->  json_text(Description, DescriptionText)
    ;   DescriptionText = ""
    ),
    Summary = _{name:Name, description:DescriptionText}.

json_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
json_text(Value, Value) :- string(Value), !.
json_text(Value, _) :- throw(error(invalid_text_value(Value), _)).

emit_event(SessionId, RunId, Event, Data) :-
    next_event_sequence(SessionId, RunId, Sequence),
    protocol_version(Version),
    Frame = _{version:Version,
              session_id:SessionId,
              run_id:RunId,
              event:Event,
              sequence:Sequence,
              data:Data},
    write_frame(Frame).

next_event_sequence(SessionId, RunId, Sequence) :-
    with_mutex(agentprolog_dsh_events,
               (   (   retract(sidecar_event_seq(SessionId, RunId, Previous))
                   ->  Sequence is Previous + 1
                   ;   Sequence = 0
                   ),
                   assertz(sidecar_event_seq(SessionId, RunId, Sequence))
               )).

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
