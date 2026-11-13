:- begin_tests(documented_configs).
:- use_module('../prolog/agentprolog_config').
:- use_module('../prolog/agentprolog_prompt').
:- use_module('../prolog/agentprolog_skills').
:- use_module('../examples/configurations/support',[]).
:- use_module(library(filesex)).
:- use_module(library(rlm_tool)).

% These are loader/projection tests. They never call a provider or model.
example_path(Name, Path) :-
    source_file(plunit_documented_configs:example_path(_,_), Source),
    file_directory_name(Source, Directory),
    directory_file_path('../examples/configurations',Name,Relative),
    absolute_file_name(Relative,Path,[relative_to(Directory),access(read)]).

environment_name('AGENTPROLOG_EXAMPLE_PROJECT').
environment_name('AGENTPROLOG_EXAMPLE_NODE').
environment_name('AGENTPROLOG_EXAMPLE_LOCAL_MODEL').
saved_environment(Name, State) :-
    (getenv(Name,Value) -> State=set(Value) ; State=unset).
restore_environment(Name-set(Value)) :- setenv(Name,Value).
restore_environment(Name-unset) :- unsetenv(Name).

setup_fixture(fixture(Root,Environment,Before)) :-
    absolute_file_name(path(node),Node,[access(execute)]),
    findall(Name-State,(environment_name(Name),saved_environment(Name,State)),Environment),
    findall(File,source_file(File),Before),
    tmp_file(documented_configs,Root), make_directory(Root),
    setenv('AGENTPROLOG_EXAMPLE_PROJECT',Root),
    setenv('AGENTPROLOG_EXAMPLE_NODE',Node),
    setenv('AGENTPROLOG_EXAMPLE_LOCAL_MODEL','offline-fixture-model').
cleanup_fixture(fixture(Root,Environment,Before)) :-
    example_path('minimal.pl',Minimal),file_directory_name(Minimal,Directory),
    file_directory_name(Directory,Examples),
    findall(File,(source_file(File),\+memberchk(File,Before),
        atom_concat(Examples,'/',Prefix),atom_concat(Prefix,_,File)),NewFiles),
    maplist(unload_file,NewFiles),maplist(restore_environment,Environment),
    delete_directory_and_contents(Root).

read_grants([tool(workspace_read),context(peek)]).
coding_grants([tool(workspace_read),tool(workspace_create),tool(workspace_write),
    tool(workspace_modify),tool(workspace_check),context(peek)]).
rlm_grants([model(openrouter),context(peek),context(search)]).

plugin_example('minimal.pl',[],minimal).
plugin_example('openrouter.pl',[],generic).
plugin_example('local-compatible.pl',[],generic).
plugin_example('read-only-project.pl',Grants,read_only_project) :- read_grants(Grants).
plugin_example('coding-workspace.pl',Grants,coding_workspace) :- coding_grants(Grants).
plugin_example('named-agents.pl',Grants,workspace_team) :- coding_grants(Grants).
plugin_example('native-skills.pl',[],native_skills).
plugin_example('bounded-budget.pl',[],bounded).
plugin_example('system-instructions.pl',[],generic).
plugin_example('typed-rlm.pl',Grants,typed_rlm) :- rlm_grants(Grants).
plugin_example('artifact-hook.pl',[],artifact_review).

operator_example('operator-read-only.pl',read_only_project).
operator_example('operator-coding.pl',artifact_review).
operator_example('operator-local-pack.pl',coding_workspace).
operator_example('operator-budget.pl',bounded).

load_plugin(fixture(Root,_,_),Name,Config) :-
    plugin_example(Name,Grants,_),example_path(Name,Path),
    once(load_configuration(Root,[plugin(Path),allowed_capabilities(Grants)],Config)).
load_operator(fixture(Root,_,_),Name,Config) :-
    example_path(Name,Path),once(load_configuration(Root,[config_file(Path)],Config)).
tool_names(Config,Names) :- findall(Name,(member(tool(S,_),Config.tools),Name=S.name),Names).
write_fixture(fixture(Root,_,_),Name,Text) :-
    directory_file_path(Root,Name,Path),
    setup_call_cleanup(open(Path,write,S,[encoding(utf8)]),format(S,'~s',[Text]),close(S)).

test(all_plugins_load_through_real_loader,
     [forall(plugin_example(Name,Grants,Profile)),setup(setup_fixture(F)),cleanup(cleanup_fixture(F))]) :-
    load_plugin(F,Name,C),assertion(C.profile==Profile),
    F=fixture(Root,_,_),assertion(C.project==Root),
    forall(member(Cap,C.capabilities),assertion(memberchk(Cap,Grants))),
    example_path(Name,Path),assertion(memberchk(Path,C.sources)).

test(all_operator_files_load_through_real_loader,
     [forall(operator_example(Name,Profile)),setup(setup_fixture(F)),cleanup(cleanup_fixture(F))]) :-
    load_operator(F,Name,C),assertion(C.profile==Profile),
    example_path(Name,Path),assertion(memberchk(Path,C.sources)).

test(at_least_twelve_complete_examples_and_no_undocumented_entrypoints) :-
    findall(Name,(plugin_example(Name,_,_);operator_example(Name,_)),Names),
    length(Names,Count),assertion(Count>=12),sort(Names,Unique),length(Unique,Count),
    example_path('minimal.pl',Minimal),file_directory_name(Minimal,Directory),directory_files(Directory,Files),
    forall((member(File,Files),file_name_extension(_,pl,File),File\=='support.pl'),
        assertion(memberchk(File,Names))).

test(workspace_plugins_cannot_grant_themselves_authority,
     [forall(member(Name,['read-only-project.pl','coding-workspace.pl','named-agents.pl','typed-rlm.pl'])),
      setup(setup_fixture(F)),cleanup(cleanup_fixture(F)),
      throws(error(agentprolog_config(capability_not_granted(_)),_))]) :-
    F=fixture(Root,_,_),example_path(Name,Path),
    load_configuration(Root,[plugin(Path),allowed_capabilities([])],_).

test(workspace_root_must_be_explicit,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F)),
      throws(error(existence_error(environment_variable,'AGENTPROLOG_EXAMPLE_PROJECT'),_))]) :-
    unsetenv('AGENTPROLOG_EXAMPLE_PROJECT'),load_plugin(F,'read-only-project.pl',_).

test(relative_workspace_root_is_rejected,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F)),
      throws(error(domain_error(absolute_project_directory,'.'),_))]) :-
    setenv('AGENTPROLOG_EXAMPLE_PROJECT','.'),load_plugin(F,'read-only-project.pl',_).

test(operator_paths_do_not_depend_on_cwd,[setup(setup_fixture(F)),cleanup(cleanup_fixture(F))]) :-
    F=fixture(Root,_,_),example_path('operator-coding.pl',Operator),
    setup_call_cleanup(working_directory(Previous,Root),
      (once(load_configuration(Root,[config_file(Operator)],C)),
       assertion(C.selected_skills==['review-evidence']),
       forall(member(Path,C.sources),assertion(is_absolute_file_name(Path)))),
      working_directory(_,Previous)).

test(operator_does_not_silently_trust_project_code,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F)),
      throws(error(agentprolog_config(untrusted_project(_)),_))]) :-
    F=fixture(Root,_,_),directory_file_path(Root,'.agentprolog',Directory),make_directory(Directory),
    write_fixture(F,'.agentprolog/config.pl',":- throw(project_code_must_not_run).\n"),
    load_operator(F,'operator-read-only.pl',_).

test(read_only_example_registers_only_a_read_tool,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F))]) :-
    load_plugin(F,'read-only-project.pl',C),tool_names(C,Names),
    assertion(Names==[workspace_read]),read_grants(Grants),assertion(C.capabilities==Grants),
    write_fixture(F,'note.txt',"offline evidence\n"),
    setup_call_cleanup(tool_registry_create(Registry),
      (register_config_tools(C,Registry),
       once(tool_invoke_execute(Registry,C.capabilities,workspace_read,_{path:"note.txt"},[],Result)),
       Result.outcome=ok(Execution),assertion(Execution.value.content=="offline evidence\n")),
      tool_registry_destroy(Registry)).

test(coding_example_has_fixed_check_tool_not_a_shell,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F))]) :-
    load_plugin(F,'coding-workspace.pl',C),tool_names(C,Names),
    assertion(Names==[workspace_read,workspace_create,workspace_write,workspace_modify,workspace_check]),
    once((member(tool(Check,tool_handler(Preflight,Execute)),C.tools),Check.name==workspace_check)),
    assertion(Check.effect==process),assertion(Check.arguments.required==[path]),
    write_fixture(F,'app.mjs',"throw new Error('MUST_NOT_EXECUTE');\n"),
    call(Preflight,_{path:"app.mjs"},Normalized,_),call(Execute,Normalized,Result),
    assertion(Result.exit_code==0).

test(named_reviewer_narrows_builder_authority,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F))]) :-
    load_plugin(F,'named-agents.pl',Reviewer),assertion(Reviewer.agent==reviewer),
    read_grants(Read),assertion(Reviewer.capabilities==Read),
    assertion(Reviewer.budget.max_model_calls==2),
    F=fixture(Root,_,_),example_path('named-agents.pl',Path),coding_grants(Grants),
    once(load_configuration(Root,[plugin(Path),allowed_capabilities(Grants),agent(builder)],Builder)),
    assertion(Builder.agent==builder),assertion(Builder.capabilities==Grants),
    assertion(Builder.budget.max_model_calls==6).

test(native_skill_is_inert_and_reaches_projection,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F))]) :-
    F=fixture(Root,_,_),example_path('native-skills.pl',Skills),
    example_path('system-instructions.pl',Instructions),
    once(load_configuration(Root,[plugin(Skills),plugin(Instructions),allowed_capabilities([])],C)),
    assertion(C.capabilities==[]),
    load_skill_units(C.skill_files,[Unit]),assertion(Unit.unit==skill('review-evidence')),
    assertion(Unit.mandatory_context==false),
    setup_call_cleanup(tool_registry_create(Registry),
      (once(prepare_runtime_options(C,Registry,"Review these claims",Options)),
       memberchk(model_handler(Handler),Options),
       projected_request(Handler,model_request{messages:[]},Request),
       Request.messages=[Message],assertion(sub_string(Message.content,_,_,_,"Distinguish syntax checks")),
       assertion(sub_string(Message.content,_,_,_,"State assumptions briefly"))),
      tool_registry_destroy(Registry)).

test(provider_examples_keep_only_credential_references,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F))]) :-
    load_plugin(F,'openrouter.pl',Remote),
    memberchk(provider(provider(openrouter,RemoteOptions)),Remote.runtime_options),
    assertion(memberchk(credential(env('OPENROUTER_API_KEY')),RemoteOptions)),
    load_plugin(F,'local-compatible.pl',Local),
    memberchk(provider(provider(openai_compatible,LocalOptions)),Local.runtime_options),
    assertion(memberchk(credential(none),LocalOptions)),
    assertion(memberchk(model('offline-fixture-model'),LocalOptions)),
    assertion(memberchk(endpoint('http://127.0.0.1:1234/v1/chat/completions'),LocalOptions)).

test(budget_layers_and_selected_agent_narrow_operator_ceiling,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F))]) :-
    load_operator(F,'operator-budget.pl',C),assertion(C.agent==brief),
    assertion(C.budget.max_model_calls==1),assertion(C.budget.max_tool_calls==0),
    assertion(C.budget.max_total_tokens==8192),assertion(C.budget.max_cost_usd=:=0.05).

test(plugin_budget_cannot_exceed_smaller_operator_limit,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F)),
      throws(error(agentprolog_config(invalid_budget(max_model_calls,3)),_))]) :-
    F=fixture(Root,_,_),example_path('bounded-budget.pl',Path),
    load_configuration(Root,[plugin(Path),allowed_capabilities([]),
        budget_limits(_{max_model_calls:2})],_).

test(rlm_example_declares_canonical_model_authority,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F))]) :-
    load_plugin(F,'typed-rlm.pl',C),assertion(C.mode==rlm),
    assertion(memberchk(model(openrouter),C.capabilities)),
    assertion(memberchk(provider_name(openrouter),C.runtime_options)),
    assertion(memberchk(planner_max_tokens(512),C.runtime_options)).

test(artifact_policy_requires_review_and_rejects_invalid_drafts,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F))]) :-
    load_plugin(F,'artifact-hook.pl',C),Hook=C.hooks.validate_artifact,
    call(Hook,_{value:"Draft for review"},approval(Artifact)),
    assertion(Artifact.text=="Draft for review"),assertion(Artifact.published==false),
    assertion(\+call(Hook,_{value:""},_)),assertion(\+call(Hook,_{value:17},_)),
    length(Codes,8193),maplist(=(0'x),Codes),string_codes(Oversized,Codes),
    assertion(\+call(Hook,_{value:Oversized},_)).

test(ordinary_local_pack_consumes_existing_native_skills,
     [setup(setup_fixture(F)),cleanup(cleanup_fixture(F))]) :-
    load_operator(F,'operator-local-pack.pl',C),assertion(C.agent==builder),
    assertion(C.selected_skills==['build-todo']),
    load_skill_units(C.skill_files,[Unit]),assertion(Unit.unit==skill('build-todo')),
    example_path('../packs/coding/pack.pl',Manifest),assertion(memberchk(Manifest,C.sources)).

:- end_tests(documented_configs).
