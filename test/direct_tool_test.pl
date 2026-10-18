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

test(direct_rlm_admits_bounded_recursive_context) :-
    agentprolog_dsh_sidecar:mode_options("direct-rlm", [], Options),
    memberchk(capabilities(Capabilities), Options),
    assertion(memberchk(rlm, Capabilities)),
    assertion(memberchk(context(search), Capabilities)),
    memberchk(budget(Budget), Options),
    assertion(Budget.max_recursion_depth =:= 2).

test(warm_generator_never_inherits_active_tool_authority) :-
    Active = [provider(test_provider),
              cancel_token(test_token),
              tool_registry(untrusted_registry),
              skill_catalog(untrusted_catalog),
              capabilities([rlm, tool(project_read)])],
    agentprolog_dsh_sidecar:compaction_completion_options(Active, Safe),
    memberchk(capabilities(Capabilities), Safe),
    assertion(Capabilities == [model(openrouter),
                               context(peek), context(slice), context(search)]),
    assertion(\+ memberchk(tool(project_read), Capabilities)),
    assertion(\+ memberchk(rlm, Capabilities)),
    assertion(\+ memberchk(tool_registry(_), Safe)),
    assertion(\+ memberchk(skill_catalog(_), Safe)),
    memberchk(budget(Budget), Safe),
    assertion(Budget.max_recursion_depth =:= 0).

test(default_budget_override_merges_full_runtime_defaults) :-
    agentprolog_dsh_sidecar:mode_options("direct-rlm", [], Options0),
    agentprolog_dsh_sidecar:apply_budget_updates(
        Options0, _{max_total_tokens:20480}, Options),
    memberchk(budget(Budget), Options),
    assertion(Budget.max_total_tokens =:= 20480),
    assertion(Budget.max_recursion_depth =:= 2),
    assertion(Budget.max_tool_calls > 0).

test(token_budget_error_has_structured_diagnostics) :-
    Error = conversation_fault(
              completion_failed(
                  completion_error{kind:token_budget_exceeded,
                                   limit:8192, used:9347},
                  some_ref, some_ledger)),
    agentprolog_dsh_sidecar:turn_error_details(Error, Code, Details),
    assertion(Code == "budget_exhausted"),
    assertion(Details.kind == "token_budget_exceeded"),
    assertion(Details.limit =:= 8192),
    assertion(Details.used =:= 9347).

:- end_tests(direct_tool).

:- initialization((run_tests, halt), main).
