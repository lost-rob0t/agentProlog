:- module(agentprolog_coding, [coding_registry_create/5]).
:- use_module(library(rlm_tool)).
:- use_module(agentprolog_tools).
:- use_module(agentprolog_git_tools).
:- use_module(agentprolog_process_tools).
:- use_module(agentprolog_experts).

% Host composition only. It creates no effect store and changes no authority.
coding_registry_create(Root, Git, Profiles, Registry, Outcome) :-
    tool_registry_create(Candidate),
    catch((compose(Candidate,Root,Git,Profiles,Result) -> true
           ; Result=error(coding_registry_error{kind:composition_failed})),E,
          Result=error(coding_registry_error{detail:E})),
    ( Result=ok(_)
    -> Registry=Candidate, Outcome=ok(Candidate)
    ; tool_registry_destroy(Candidate), Registry=none, Outcome=Result ).

compose(R,Root,Git,Profiles,Outcome) :-
    coding_tools_load(R,Root,A),
    ( A=ok(_) -> git_tools_load(R,Root,Git,B) ; B=A ),
    ( B=ok(_) -> process_tools_load(R,Root,Profiles,C) ; C=B ),
    ( C=ok(_) -> coding_experts_load(R,Outcome) ; Outcome=C ).
