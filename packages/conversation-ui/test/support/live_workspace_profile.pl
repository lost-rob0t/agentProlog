:- module(agentprolog_live_workspace_profile, [main/1]).

% Opt-in acceptance only. Uses real provider I/O and native generic workspace tools.
:- use_module('../../../../prolog/agentprolog_session', [serve/2]).
:- use_module('../../../../prolog/agentprolog_workspace_tools').
:- use_module(library(rlm_chain), []).
:- initialization(cli_main, main).
cli_main :- current_prolog_flag(argv, Args), main(Args).
main([Directory, Workspace]) :-
    getenv('AGENTPROLOG_LIVE_ACCEPTANCE', '1'),
    getenv('ZAI_API_KEY', Key), Key \== '',
    current_predicate(rlm_chain:zai_coding_provider/3),
    rlm_chain:zai_coding_provider(chat_completions, 'glm-5.3-flash', Provider),
    workspace_tools(Workspace, Tools),
    Config=_{project:Workspace,sources:[],mode:direct,profile:"live-workspace-acceptance",tools:Tools,
      capabilities:[tool(workspace_read),tool(workspace_create),tool(workspace_modify),tool(workspace_write),context(peek)],
      runtime_options:[provider(Provider),provider_name(zai_coding),prompt_compile_mode(all_tools)],
      budget:_{max_model_calls:12,max_tool_calls:12,max_iterations:16,max_context_ops:16,
               max_total_tokens:12000,max_output_bytes:65536,max_cost_usd:0.10,time_limit:120.0},hooks:_{}},
    serve(Directory, Config).
main(_) :- format(user_error,'Live acceptance unavailable: explicit opt-in, existing ZAI_API_KEY and coordinated provider pin required.~n',[]),halt(2).
