:- module(agentprolog_history,[history_depth/2,history_record/4,history_messages/3,history_validate/2]).

/** Opt-in bounded completed-turn memory, projected by the canonical runtime.
    This is not a transcript store, execution cursor, or a second agent loop. */
:- use_module(library(option)).
:- use_module('./agentprolog_commands').
:- use_module('./agentprolog_images').
:- use_module(library(rlm_conversation), []).

history_depth(Config, Depth) :- option(history_depth(Depth),Config.runtime_options,0).

history_validate(Config,History) :-
    history_depth(Config,Depth), is_list(History), length(History,N),N=<Depth,
    forall(member(T,History),
      (is_dict(T),dict_pairs(T,_,[assistant-A,user-U]),
       string(A),string(U),string_length(A,AN),AN=<16000,string_length(U,UN),UN=<16000)), !.
history_validate(_,_) :- throw(error(invalid_session_history,_)).

history_record(Config, State, Text, History) :-
    history_depth(Config,Depth),
    (Depth=:=0 -> History=[]
    ; (get_dict(history,State,Previous) -> true ; Previous=[]),
      exclude(private_turn,Previous,Old),
      (private_objective(State.objective) -> All=Old
       ; (get_dict(image_refs,State,Refs)->true;Refs=[]),
         image_marker(Refs,State.objective,Marked),bounded_text(Marked,User), bounded_text(Text,Assistant),
         append(Old,[turn{user:User,assistant:Assistant}],All)),
      length(All,N), Drop is max(0,N-Depth), length(Prefix,Drop),
      append(Prefix,History,All)).
bounded_text(Text,Bounded) :- string_length(Text,N), K is min(N,16000),sub_string(Text,0,K,_,Bounded).

history_messages(Config, History, Messages) :-
    history_depth(Config,Depth),
    (Depth=:=0 ; History==[]), !, Messages=[].
history_messages(Config,History,Messages) :-
    exclude(private_turn,History,PublicHistory),
    setup_call_cleanup(rlm_conversation:conversation_store_open(memory,ok(Store)),
      (rlm_conversation:conversation_create(Store,[id(agentprolog_history)],ok(C)),
       forall(member(T,PublicHistory),
         (rlm_conversation:conversation_append(C,message(user,T.user),ok(_)),
          rlm_conversation:conversation_append(C,message(assistant,T.assistant),ok(_)))),
       Limit is max(1,min(4096,Config.budget.max_total_tokens//4)),
       Policy=_{max_context_tokens:Limit,provider_context_tokens:Limit,
         reserve_output_tokens:0,safety_margin_tokens:0,min_recent_turns:0,overflow:deny},
       rlm_conversation:conversation_context_pack(C,[policy(Policy)],Result),
       (Result=ok(Pack) -> complete_pairs(Pack.selected,Messages)
        ; throw(error(history_projection(Result),_)))),
      rlm_conversation:conversation_store_close(Store,_)).

% Never supply an orphaned answer after budget selection drops its question.
complete_pairs(Selected,Messages) :-
    findall(Seq-[message{role:user,content:User},message{role:assistant,content:Assistant}],
      (member(SU,Selected),U=SU.value,U.role==user,Seq=U.sequence,
       Next is Seq+1,member(SA,Selected),A=SA.value,A.sequence=:=Next,A.role==assistant,User=U.content,Assistant=A.content),Pairs),
    keysort(Pairs,Sorted),pairs_messages(Sorted,Messages).
pairs_messages([],[]).
pairs_messages([_-Pair|Rest],Messages) :- pairs_messages(Rest,Tail),append(Pair,Tail,Messages).

% Private memory commands never become provider conversation context, including
% older checkpoints produced before this exclusion was introduced.
private_turn(Turn) :- private_objective(Turn.user).
private_objective(Objective) :- command_head(Objective,Command,_),memberchk(Command,["/remember","/rsi","/rsi-context","/sleep","/learn"]).
