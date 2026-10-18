:- use_module(library(plunit)).
:- use_module(library(rlm_tool), []).
:- use_module('../prolog/agentprolog_dsh_sidecar.pl', []).

:- begin_tests(direct_tool).

test(project_read_is_registered_and_confined) :-
    agentprolog_dsh_sidecar:session_tool_registry(".", Registry),
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

test(recursive_child_project_read_is_granted_by_parent) :-
    agentprolog_dsh_sidecar:mode_options("symbolic-recursive", [], Options),
    rlm_completion:capability_options(Options, openrouter, Parent, Child),
    assertion(memberchk(tool(project_read), Parent)),
    assertion(memberchk(tool(project_read), Child)).

test(skill_selection_options_are_consumed_by_runtime) :-
    agentprolog_dsh_sidecar:skill_options(
        _{skill_mode:"off", explicit_skills:["rlm-operate"], disabled_skills:["rlm-facts"]}, [], Options),
    rlm_completion:option_value(skill_mode, Options, on, Mode),
    rlm_completion:option_value(explicit_skills, Options, [], Selected),
    rlm_completion:option_value(disabled_skills, Options, [], Disabled),
    assertion(Mode == off), assertion(Selected == ["rlm-operate"]),
    assertion(Disabled == ["rlm-facts"]).

:- end_tests(direct_tool).

:- initialization((run_tests -> halt(0); halt(1)), main).
