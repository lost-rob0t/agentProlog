:- use_module('agentprolog_dsh_sidecar.pl', []).
:- use_module(library(plunit)).

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

:- end_tests(sidecar_mode_options).
