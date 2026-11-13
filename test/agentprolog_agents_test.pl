:- begin_tests(agentprolog_agents).
:- use_module('../prolog/agentprolog_config').
:- use_module(library(filesex)).

project(Root) :- tmp_file(agentprolog_agents,Root), make_directory(Root).
cleanup(Root) :- delete_directory_and_contents(Root).
plugin(Root, Body, Path) :-
    directory_file_path(Root,'agents.pl',Path),
    gensym(test_named_agents_,Module),
    setup_call_cleanup(open(Path,write,S),
      format(S,':- module(~w,[agentprolog_config/1]).~nagentprolog_config(~s).~n',[Module,Body]),close(S)).

test(select_named_agent_inherits_and_narrows,
     [setup(project(R)),cleanup(cleanup(R))]) :-
    plugin(R,"_{profile:team,capabilities:[context(peek),context(search)],agents:_{builder:_{capabilities:[context(peek)],budget:_{max_model_calls:3},runtime_options:[system_prompt(\"BUILD_MARKER\")]}},default_agent:builder}",P),
    setup_call_cleanup(true,
      (load_configuration(R,[plugin(P),allowed_capabilities([context(peek),context(search)])],C),
       assertion(C.agent == builder), assertion(C.profile == team),
       assertion(C.capabilities == [context(peek)]), assertion(C.budget.max_model_calls == 3),
       assertion(memberchk(system_prompt("BUILD_MARKER"),C.runtime_options))),unload_file(P)).

test(unknown_agent_rejected,[setup(project(R)),cleanup(cleanup(R)),
     throws(error(agentprolog_config(unknown_agent(missing)),_))]) :-
    load_configuration(R,[agent(missing)],_).

test(agent_cannot_expand_parent_capabilities,[setup(project(R)),cleanup(cleanup(R)),
     throws(error(agentprolog_config(agent_capability_expansion(context(search))),_))]) :-
    plugin(R,"_{capabilities:[context(peek)],agents:_{builder:_{capabilities:[context(search)]}}}",P),
    setup_call_cleanup(true,
      load_configuration(R,[plugin(P),agent(builder),allowed_capabilities([context(peek),context(search)])],_),unload_file(P)).

test(agent_cannot_expand_parent_budget,[setup(project(R)),cleanup(cleanup(R)),
     throws(error(agentprolog_config(invalid_budget(max_model_calls,5)),_))]) :-
    plugin(R,"_{budget:_{max_model_calls:2},agents:_{builder:_{budget:_{max_model_calls:5}}}}",P),
    setup_call_cleanup(true,load_configuration(R,[plugin(P),agent(builder)],_),unload_file(P)).

test(local_prolog_pack_loads_configuration,[setup(project(R)),cleanup(cleanup(R))]) :-
    directory_file_path(R,'pack.pl',Manifest),
    setup_call_cleanup(open(Manifest,write,S),
      format(S,"name(test_agentprolog_pack).~nversion('0.1.0').~n",[]),close(S)),
    directory_file_path(R,prolog,Dir),make_directory(Dir),
    directory_file_path(Dir,'agentprolog_plugin.pl',Entry),
    setup_call_cleanup(open(Entry,write,E),
      format(E,':- module(test_local_pack,[agentprolog_config/1]).~nagentprolog_config(_{profile:from_pack}).~n',[]),close(E)),
    setup_call_cleanup(true,
      (load_configuration(R,[package(R)],C),assertion(C.profile == from_pack),
       assertion(memberchk(Manifest,C.sources)),assertion(memberchk(Entry,C.sources))),unload_file(Entry)).

test(operator_prolog_file_configures_grants_agent_and_budget,
     [setup(project(R)),cleanup(cleanup(R))]) :-
    plugin(R,"_{capabilities:[context(peek)],agents:_{builder:_{budget:_{max_model_calls:12}}}}",P),
    directory_file_path(R,'operator.pl',O),
    setup_call_cleanup(open(O,write,S),
      format(S,':- module(test_operator_options,[agentprolog_options/1]).~nagentprolog_options([plugin(~q),agent(builder),allowed_capabilities([context(peek)]),budget_ceiling(_{max_model_calls:16})]).~n',[P]),close(S)),
    setup_call_cleanup(true,
      (load_configuration(R,[config_file(O)],C),assertion(C.agent==builder),
       assertion(C.capabilities==[context(peek)]),assertion(C.budget.max_model_calls==12),
       assertion(memberchk(O,C.sources))), (unload_file(O),unload_file(P))).

test(duplicate_local_pack_names_rejected_before_attachment,
     [setup(project(R)),cleanup(cleanup(R)),
      throws(error(agentprolog_config(duplicate_package(test_duplicate_pack)),_))]) :-
    findall(P,(member(Name,[one,two]),directory_file_path(R,Name,P),make_directory(P),
      directory_file_path(P,'pack.pl',Manifest),
      setup_call_cleanup(open(Manifest,write,S),format(S,"name(test_duplicate_pack).~nversion('0.1.0').~n",[]),close(S))),[A,B]),
    load_configuration(R,[package(A),package(B)],_).

:- end_tests(agentprolog_agents).
