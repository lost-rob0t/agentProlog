:- begin_tests(agentprolog_config).
:- use_module('../prolog/agentprolog_config').
:- use_module(library(filesex)).
:- use_module(library(rlm_tool)).

with_project(Goal) :-
    tmp_file(agentprolog_config,Root), make_directory(Root),
    setup_call_cleanup(true, call(Goal,Root), delete_directory_and_contents(Root)).
write_source(Root, Relative, Text, Path) :-
    directory_file_path(Root,Relative,Path), file_directory_name(Path,Dir),
    make_directory_path(Dir),
    setup_call_cleanup(open(Path,write,S), format(S,'~s',[Text]),close(S)).
write_module(Root, Relative, Module, Body, Path) :-
    format(string(Text),':- module(~w,[agentprolog_config/1]).~nagentprolog_config(~s).~n',[Module,Body]),
    write_source(Root,Relative,Text,Path).

empty(Root) :-
    load_configuration(Root,[],C), assertion(C.profile == generic),
    assertion(C.capabilities == []), assertion(C.tools == []), assertion(C.sources == []).
test(default_deny_tools) :- with_project(empty).

untrusted(Root) :-
    write_source(Root,'.agentprolog/config.pl',
        ":- module(config_never_runs,[agentprolog_config/1]).\n:- throw(untrusted_code_ran).\nagentprolog_config(_{}).",_),
    catch(load_configuration(Root,[],_), E, true),
    assertion(E = error(agentprolog_config(untrusted_project(_)),_)),
    assertion(\+ current_module(config_never_runs)).
test(project_code_not_loaded_without_trust) :- with_project(untrusted).

precedence(Root) :-
    write_module(Root,'first.pl',config_first,
      "_{profile:first,runtime_options:[provider_name(first),prompt_compile_mode(all_tools)],budget:_{max_model_calls:6}}",First),
    write_module(Root,'second.pl',config_second,
      "_{profile:second,runtime_options:[provider_name(second)]}",Second),
    write_module(Root,'.agentprolog/config.pl',config_project,
      "_{profile:project,budget:_{max_model_calls:3}}",Project),
    setup_call_cleanup(true,
      (load_configuration(Root,[plugin(First),plugin(Second),trusted_project(true)],C),
       assertion(C.profile == project), assertion(C.budget.max_model_calls == 3),
       assertion(C.runtime_options == [prompt_compile_mode(all_tools),provider_name(second)]),
       assertion(C.sources == [First,Second,Project])),
      (unload_file(First),unload_file(Second),unload_file(Project))).
test(ordered_plugins_then_project_precedence) :- with_project(precedence).

unknown_key(Root) :-
    write_module(Root,'bad.pl',config_unknown,"_{surprise:true}",Path),
    catch(load_configuration(Root,[plugin(Path)],_),E,true),
    assertion(E = error(agentprolog_config(unknown_key(surprise)),_)),
    assertion(\+ current_predicate(config_unknown:agentprolog_config/1)).
test(invalid_config_unloads_failed_source) :- with_project(unknown_key).

budget(Root) :-
    write_module(Root,'budget.pl',config_budget,"_{budget:_{max_model_calls:9}}",Path),
    catch(load_configuration(Root,[plugin(Path)],_),E,true),
    assertion(E = error(agentprolog_config(invalid_budget(max_model_calls,9)),_)).
test(budget_cannot_expand_operator_ceiling) :- with_project(budget).

reserved(Root) :-
    write_module(Root,'reserved.pl',config_reserved,"_{runtime_options:[capabilities([tool(secret)])]}",Path),
    catch(load_configuration(Root,[plugin(Path)],_),E,true),
    assertion(E = error(agentprolog_config(unsupported_runtime_option(_)),_)).
test(runtime_options_cannot_override_capability_registry) :- with_project(reserved).

plugin_path(Path) :-
    source_file(plunit_agentprolog_config:plugin_path(_),File),
    file_directory_name(File,Dir), directory_file_path(Dir,'../examples/plugins/word_count.pl',Relative),
    absolute_file_name(Relative,Path,[access(read)]).
no_grant(Root) :- plugin_path(Path),
    catch(load_configuration(Root,[plugin(Path)],_),E,true),
    assertion(E = error(agentprolog_config(capability_not_granted(tool(word_count))),_)).
test(plugin_cannot_grant_its_own_tool_capability) :- with_project(no_grant).

execute_tool(Root) :- plugin_path(Path),
    setup_call_cleanup(true,
      (load_configuration(Root,[plugin(Path),allowed_capabilities([tool(word_count),context(peek)])],C),
       setup_call_cleanup(tool_registry_create(R),
         (register_config_tools(C,R),
          tool_invoke_execute(R,C.capabilities,word_count,_{text:"one two three"},[],Result),
          assertion(Result.outcome = ok(_)), Result.outcome = ok(Execution), assertion(Execution.value.count == 3)),
         tool_registry_destroy(R))),
      unload_file(Path)).
test(generic_plugin_registers_and_executes_via_native_authority) :- once(with_project(execute_tool)).

duplicate_tool(Root) :- plugin_path(Path),
    write_module(Root,'duplicate.pl',config_duplicate,
      "_{tools:[tool(tool_schema{name:word_count,capability:tool(word_count),effect:read,arguments:_{type:object,properties:_{},required:[],additional_properties:false},result:_{type:integer}},config_duplicate:handler)]}",Dup),
    catch(load_configuration(Root,[plugin(Path),plugin(Dup),allowed_capabilities([tool(word_count),context(peek)])],_),E,true),
    unload_file(Path), assertion(E = error(agentprolog_config(duplicate_tool_name),_)).
test(duplicate_tool_names_fail_instead_of_shadowing) :- with_project(duplicate_tool).

module_conflict(Root) :-
    write_module(Root,'a.pl',config_same_name,"_{profile:a}",A),
    write_module(Root,'b.pl',config_same_name,"_{profile:b}",B),
    setup_call_cleanup(true,
      (load_configuration(Root,[plugin(A)],_),
       catch(load_configuration(Root,[plugin(B)],_),E,true),
       assertion(E = error(agentprolog_config(module_conflict(config_same_name,_,_)),_))),
      unload_file(A)).
test(module_identity_cannot_cross_project_sources) :- with_project(module_conflict).

recovery(Root) :-
    write_module(Root,'recover.pl',config_recover,"_{unknown:true}",Path),
    catch(load_configuration(Root,[plugin(Path)],_),_,true),
    write_module(Root,'recover.pl',config_recover,"_{profile:recovered}",_),
    setup_call_cleanup(true,
      (load_configuration(Root,[plugin(Path)],C), assertion(C.profile == recovered)),
      unload_file(Path)).
test(valid_config_loads_after_failed_load) :- with_project(recovery).

non_unique(Root) :-
    write_source(Root,'multiple.pl',":- module(config_multiple,[agentprolog_config/1]).\nagentprolog_config(_{profile:a}).\nagentprolog_config(_{profile:b}).",Path),
    catch(load_configuration(Root,[plugin(Path)],_),E,true),
    assertion(E = error(agentprolog_config(non_unique_configuration(_)),_)).
test(nondeterministic_config_rejected) :- with_project(non_unique).

test(conflicting_operator_options_rejected,
     [throws(error(agentprolog_config(duplicate_option),_))]) :-
    load_configuration('.',[trusted_project(false),trusted_project(true)],_).

context_caps(Root) :-
    write_module(Root,'context.pl',config_context,"_{capabilities:[context(peek)]}",Path),
    setup_call_cleanup(true,
      (load_configuration(Root,[plugin(Path),allowed_capabilities([context(peek)])],C),
       assertion(C.capabilities == [context(peek)])),
      unload_file(Path)).
test(native_context_capability_requires_explicit_grant) :- with_project(context_caps).

isolated(Root) :-
    write_module(Root,'isolation.pl',config_isolation,"_{profile:changed,runtime_options:[provider_name(test)]}",Path),
    setup_call_cleanup(true,
      (load_configuration(Root,[plugin(Path)],A),
       load_configuration(Root,[],B),
       assertion(A.profile == changed), assertion(B.profile == generic),
       assertion(B.runtime_options == [])), unload_file(Path)).
test(configuration_output_does_not_leak_previous_project_options) :- with_project(isolated).

preflight_binding(Root) :-
    write_module(Root,'preflight.pl',config_preflight,
      "_{tools:[tool(tool_schema{name:bounded,capability:tool(bounded),effect:read,arguments:_{type:object,properties:_{},required:[],additional_properties:false},result:_{type:integer}},tool_handler(config_preflight:check,config_preflight:execute))]}",Path),
    setup_call_cleanup(true,
      (load_configuration(Root,[plugin(Path)],C), assertion(C.tools = [tool(_,tool_handler(_,_))])), unload_file(Path)).
test(native_preflight_handler_shape_accepted) :- once(with_project(preflight_binding)).

model_caps(Root) :-
    write_module(Root,'model.pl',config_model,
      "_{mode:rlm,capabilities:[model(test_provider)],runtime_options:[planner_handler(config_model:plan)]}",Path),
    setup_call_cleanup(true,
      (load_configuration(Root,[plugin(Path),allowed_capabilities([model(test_provider)])],C),
       assertion(C.mode == rlm), assertion(C.capabilities == [model(test_provider)]),
       assertion(C.runtime_options == [planner_handler(config_model:plan)])), unload_file(Path)).
test(rlm_planner_handler_and_model_grant_accepted) :- with_project(model_caps).

ungranted_model(Root) :-
    write_module(Root,'model-denied.pl',config_model_denied,"_{capabilities:[model(test_provider)]}",Path),
    catch(load_configuration(Root,[plugin(Path)],_),E,true),
    assertion(E = error(agentprolog_config(capability_not_granted(model(test_provider))),_)).
test(model_capability_cannot_be_self_granted) :- with_project(ungranted_model).

unqualified_planner(Root) :-
    write_module(Root,'bad-planner.pl',config_bad_planner,"_{runtime_options:[planner_handler(plan)]}",Path),
    catch(load_configuration(Root,[plugin(Path)],_),E,true),
    assertion(E = error(agentprolog_config(qualified_handler_required(plan)),_)).
test(unqualified_planner_callable_rejected) :- with_project(unqualified_planner).

invalid_planner(Root) :-
    write_module(Root,'noncallable-planner.pl',config_noncallable_planner,"_{runtime_options:[planner_handler(config_noncallable_planner:42)]}",Path),
    catch(load_configuration(Root,[plugin(Path)],_),E,true),
    assertion(E = error(agentprolog_config(qualified_handler_required(_)),_)).
test(noncallable_planner_rejected) :- with_project(invalid_planner).
:- end_tests(agentprolog_config).
