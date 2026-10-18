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

test(direct_grants_read_and_result_inspection_without_recursion) :-
    agentprolog_dsh_sidecar:mode_options("direct", [], Options),
    memberchk(capabilities(Capabilities), Options),
    assertion(memberchk(tool(project_read), Capabilities)),
    assertion(memberchk(context(peek), Capabilities)),
    assertion(\+ memberchk(rlm, Capabilities)),
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

test(symbolic_children_and_parent_admit_project_read) :-
    forall(member(Mode, ["symbolic", "symbolic-recursive"]),
           ( agentprolog_dsh_sidecar:mode_options(Mode, [], Options),
             rlm_completion:capability_options(Options, openrouter, Parent, Child),
             assertion(memberchk(tool(project_read), Parent)),
             assertion(memberchk(tool(project_read), Child)) )).

test(skill_options_are_canonical_and_consumed) :-
    setup_call_cleanup(
        ( rlm_skill:skill_default_catalog(ok(Catalog)),
          assertz(agentprolog_dsh_sidecar:sidecar_skill_catalog(Catalog)) ),
        ( agentprolog_dsh_sidecar:skill_options(
              _{explicit_skills:["rlm-operate"], disabled_skills:["rlm-facts"]}, [], Options),
          assertion(is_list(Options)),
          rlm_completion:option_value(explicit_skills, Options, [], Selected),
          assertion(Selected == ["rlm-operate"]),
          rlm_completion:option_value(disabled_skills, Options, [], Disabled),
          assertion(Disabled == ["rlm-facts"]),
          assertion(memberchk(skill_catalog(Catalog), Options)) ),
        retractall(agentprolog_dsh_sidecar:sidecar_skill_catalog(_))).

test(compaction_spending_survives_execution_failure) :-
    Warm = auto_warm_status{enabled:true, published:true,
                           source_range:range(1,3),
                           generation:_{usage:_{total_tokens:127}}},
    agentprolog_dsh_sidecar:compaction_status(
        error(conversation_error{kind:conversation_error, auto_warm:Warm}), Status),
    assertion(Status.state == "published"),
    assertion(Status.usage.total_tokens =:= 127),
    assertion(Status.start =:= 1), assertion(Status.end =:= 3).

test(failed_compaction_preserves_known_spending_without_inventing_unknown_usage) :-
    Warm = auto_warm_status{enabled:true, published:false, reason:failed},
    agentprolog_dsh_sidecar:compaction_status(error(_{auto_warm:Warm}), Unknown),
    assertion(Unknown.state == "failed"),
    assertion(\+ get_dict(usage, Unknown, _)),
    put_dict(generation, Warm, _{usage:_{total_tokens:91}}, WithUsage),
    agentprolog_dsh_sidecar:compaction_status(error(_{auto_warm:WithUsage}), Known),
    assertion(Known.state == "failed"),
    assertion(Known.usage.total_tokens =:= 91).

test(all_modes_execute_managed_turns_with_visible_project_reads) :-
    forall(member(Mode, ["direct", "direct-rlm", "symbolic", "symbolic-recursive"]),
           managed_mode_turn(Mode)).

managed_mode_turn(Mode) :-
    setup_call_cleanup(
        ( agentprolog_dsh_sidecar:session_tool_registry(".", Registry),
          rlm_conversation:conversation_store_open(memory, ok(Store)),
          rlm_conversation:conversation_create(Store, [], ok(Conversation)),
          rlm_completion:rlm_cancellation_token(Token),
          assertz(agentprolog_dsh_sidecar:sidecar_tool_registry("mode-test", Registry)) ),
        ( rlm_conversation:conversation_append(Conversation, message(user, "prior evidence"), ok(First)),
          agentprolog_dsh_sidecar:completion_options(Mode, _{}, Token,
              _{session_id:"mode-test"}, Options),
          agentprolog_dsh_sidecar:mode_strategy(Mode, Strategy),
          rlm_conversation_runtime:conversation_turn(Conversation, message(user, "inspect project"),
              [strategy(Strategy), completion_options([
                  model_handler(plunit_direct_tool:native_reply),
                  planner_handler(plunit_direct_tool:symbolic_reply)|Options])], ok(Turn)),
          assertion(Turn.assistant.content == "checked"),
          assertion(Turn.completion.usage.total_tokens =:= 12),
          ( Strategy == native -> assertion(Turn.completion.turns =:= 1) ; true ),
          rlm_conversation:conversation_message(Conversation, 1, ok(Restored)),
          assertion(Restored == First) ),
        ( retractall(agentprolog_dsh_sidecar:sidecar_tool_registry("mode-test", _)),
          rlm_tool:tool_registry_destroy(Registry),
          rlm_conversation:conversation_store_close(Store, _) )).

native_reply(Request, ok(_{text:"checked", tool_calls:[],
                           usage:_{prompt_tokens:10, completion_tokens:2, total_tokens:12}})) :-
    term_string(Request.options.tools, Schemas),
    assertion(sub_string(Schemas, _, _, _, "project_read")),
    term_string(Request.messages, Messages),
    assertion(sub_string(Messages, _, _, _, "prior evidence")).

symbolic_reply(Request, ok(_{plan:plan([final(literal("checked"))]),
                            usage:_{prompt_tokens:10, completion_tokens:2, total_tokens:12}})) :-
    term_string(Request.messages, Messages),
    assertion(sub_string(Messages, _, _, _, "project_read")),
    assertion(sub_string(Messages, _, _, _, "prior evidence")).

:- end_tests(direct_tool).

:- initialization((run_tests -> halt(0); halt(1)), main).
