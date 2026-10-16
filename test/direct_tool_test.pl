:- use_module(library(plunit)).
:- use_module(library(rlm_tool), []).
:- use_module('../prolog/agentprolog_dsh_sidecar.pl', []).

:- begin_tests(direct_tool).

test(project_read_is_registered_and_confined) :-
    agentprolog_dsh_sidecar:session_tool_registry(_{payload:_{cwd:"."}}, Registry),
    setup_call_cleanup(
        true,
        ( rlm_tool:tool_invoke(Registry, [tool(project_read)], project_read,
                               json{path:"docs/architecture.md"}, [], ok(Execution), _),
          once(sub_string(Execution.value.content, _, _, _, "AgentProlog")),
          rlm_tool:tool_invoke(Registry, [tool(project_read)], project_read,
                               json{path:"../README.md"}, [], error(Denied), _),
          assertion(Denied.kind == confinement_denied)
        ),
        rlm_tool:tool_registry_destroy(Registry)).

test(direct_completion_grants_only_model_and_read_tool) :-
    agentprolog_dsh_sidecar:mode_options("direct", [], Options),
    memberchk(capabilities(Capabilities), Options),
    assertion(Capabilities == [model(openrouter), tool(project_read)]),
    memberchk(budget(Budget), Options),
    assertion(Budget.max_recursion_depth == 0).

:- end_tests(direct_tool).

:- initialization((run_tests, halt), main).
