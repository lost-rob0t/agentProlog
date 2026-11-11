:- use_module(library(plunit)).
:- begin_tests(coding_tools).
:- use_module(library(filesex)).
:- use_module(library(uuid)).
:- use_module(library(readutil)).
:- use_module(library(rlm_tool)).
:- use_module(library(rlm_effect)).
:- use_module(library(rlm_authority)).
:- use_module('../prolog/agentprolog_tools').
:- use_module('../prolog/agentprolog_process_tools').
:- use_module('../prolog/agentprolog_experts').
:- use_module('../prolog/agentprolog_coding').
:- use_module('../prolog/agentprolog_git_tools').
:- use_module(library(process)).
:- use_module(library(rlm_expert)).

setup_project(state(Root, R, Store)) :-
    uuid(Id), atom_concat('/tmp/agentprolog-', Id, Root), make_directory(Root),
    directory_file_path(Root, 'sample.txt', File),
    setup_call_cleanup(open(File, write, S), write(S, 'hello world'), close(S)),
    tmp_file(effects, Store), rlm_effect_store_open(Store),
    tool_registry_create(R), coding_tools_load(R, Root, ok(_)).
cleanup_project(state(Root, R, Store)) :-
    tool_registry_destroy(R), rlm_effect_store_close,
    delete_file(Store), delete_directory_and_contents(Root),
    rlm_authority_clear(session(coding_test)).
invoke(R, Name, Args, Outcome) :-
    tool_invoke(R, [tool(Name)], Name, Args,
                [authority_context(session(coding_test))], Outcome, _).

test(read_search_patch, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S = state(_, R, _),
    invoke(R, project_read, _{path:"sample.txt"}, ok(Read)),
    assertion(Read.value.content == "hello world"),
    invoke(R, project_search, _{path:"sample.txt", query:"world"}, ok(Search)),
    assertion(Search.value.matches = [_]),
    rlm_set_authority(session(coding_test), dangerous, ok(_)),
    invoke(R, project_patch, _{path:"sample.txt", expected_sha256:Read.value.sha256,
                             old:"world", new:"Prolog"}, ok(_)),
    invoke(R, project_read, _{path:"sample.txt"}, ok(After)),
    assertion(After.value.content == "hello Prolog").

test(stale_preimage, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S = state(_, R, _),
    rlm_set_authority(session(coding_test), dangerous, ok(_)),
    invoke(R, project_write, _{path:"sample.txt", expected_sha256:"stale", content:"bad"}, error(_)),
    invoke(R, project_read, _{path:"sample.txt"}, ok(Read)),
    assertion(Read.value.content == "hello world").

test(traversal_and_symlink, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S = state(Root, R, _),
    invoke(R, project_read, _{path:"../outside"}, error(_)),
    directory_file_path(Root, link, Link), link_file('/etc', Link, symbolic),
    invoke(R, project_read, _{path:"link/passwd"}, error(_)).

test(approval_no_write, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S = state(_, R, _),
    invoke(R, project_write, _{path:"new.txt", expected_sha256:"missing", content:"new"}, approval_required(_)),
    invoke(R, project_read, _{path:"new.txt"}, error(_)).

test(capability_denial, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S = state(_, R, _),
    tool_invoke(R, [], project_read, _{path:"sample.txt"}, [], error(_), _).

test(expert_to_edit, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S = state(_,R,_), coding_experts_load(R,ok(_)),
    invoke(R,project_read,_{path:"sample.txt"},ok(Read)),
    expert_select(R,edit,_{capabilities:[tool(write_expert)]},ok(Selected)),
    expert_invoke(R,Selected.selected,
        _{path:"sample.txt",content:Read.value.content,old:"world",new:"experts"},
        _{capabilities:[tool(write_expert)]},[],ok(Proposal),_),
    assertion(Proposal.value.status == proposed),
    rlm_set_authority(session(coding_test),dangerous,ok(_)),
    invoke(R,Proposal.value.tool,Proposal.value.arguments,ok(_)),
    invoke(R,project_read,_{path:"sample.txt"},ok(After)),
    assertion(After.value.content == "hello experts").

test(process_nonzero, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S = state(Root,R,_),
    process_tools_load(R,Root,[_{id:"fail",snapshot:"fixture-v1",executable:'/usr/bin/false',argv:[],
        env:[],kind:test,seconds:2}],ok(_)),
    invoke(R,run_tests,_{profile:"unknown"},error(_)),
    rlm_set_authority(session(coding_test),dangerous,ok(_)),
    invoke(R,run_tests,_{profile:"fail"},ok(Result)),
    assertion(Result.value.status == failed),
    assertion(Result.value.exit_code =:= 1).

test(approval_then_stale, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S = state(Root,R,_),
    invoke(R,project_read,_{path:"sample.txt"},ok(Read)),
    invoke(R,project_write,_{path:"sample.txt",expected_sha256:Read.value.sha256,content:"approved"},approval_required(Pending)),
    directory_file_path(Root,'sample.txt',File),
    setup_call_cleanup(open(File,write,Out),write(Out,'user changed it'),close(Out)),
    rlm_pending_resolution_async(Pending.id,Future),
    rlm_approve(Pending.id,ok(_)),
    rlm_async:rlm_future_await(Future,5,Resolution),
    assertion(Resolution.outcome = error(_)),
    rlm_async:rlm_future_destroy(Future),
    invoke(R,project_read,_{path:"sample.txt"},ok(After)),
    assertion(After.value.content == "user changed it").
test(git_status_fresh, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S=state(Root,R,_),
    process_create(path(git),[init,'--quiet',Root],[process(Pid)]),
    process_wait(Pid,exit(0)),
    absolute_file_name(path(git),Git,[access(execute)]),
    git_tools_load(R,Root,Git,ok(_)),
    invoke(R,git_status,_{},ok(Status)),
    assertion(sub_string(Status.value.output,_,_,_,"sample.txt")),
    directory_file_path(Root,'sample.txt',File),delete_file(File),
    invoke(R,git_status,_{},ok(After)),
    assertion(After.value.output == "").

test(process_output_bound, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S=state(Root,R,_),
    process_tools_load(R,Root,[_{id:"flood",snapshot:"fixture-v1",executable:'/usr/bin/yes',argv:[],
        env:[],kind:test,seconds:2}],ok(_)),
    rlm_set_authority(session(coding_test),dangerous,ok(_)),
    invoke(R,run_tests,_{profile:"flood"},error(_)).

test(preserve_executable_mode, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S=state(Root,R,_), directory_file_path(Root,'sample.txt',File),chmod(File,0o750),
    invoke(R,project_read,_{path:"sample.txt"},ok(Read)),
    rlm_set_authority(session(coding_test),dangerous,ok(_)),
    invoke(R,project_write,_{path:"sample.txt",expected_sha256:Read.value.sha256,content:"new"},ok(_)),
    files_ex:file_mode_(File,Mode), assertion(Mode /\ 0o777 =:= 0o750).

test(process_timeout, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S=state(Root,R,_),
    process_tools_load(R,Root,[_{id:"wait",snapshot:"fixture-v1",executable:'/usr/bin/sleep',argv:['10'],
        env:[],kind:test,seconds:1}],ok(_)),
    rlm_set_authority(session(coding_test),dangerous,ok(_)),
    invoke(R,run_tests,_{profile:"wait"},error(_)).

test(process_snapshot_replay, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S=state(Root,R,_),
    Profile=profile{id:"counter",snapshot:"fixture-v1",executable:'/bin/sh',
        argv:['-c','printf x >> counter'],env:[],kind:test,seconds:2},
    process_tools_load(R,Root,[Profile],ok(_)),
    rlm_set_authority(session(coding_test),dangerous,ok(_)),
    invoke(R,run_tests,_{profile:"counter"},ok(_)),
    invoke(R,run_tests,_{profile:"counter"},ok(_)),
    directory_file_path(Root,counter,File),read_file_to_string(File,"x",[]),
    setup_call_cleanup(tool_registry_create(R2),
        (process_tools_load(R2,Root,[Profile.put(snapshot,"fixture-v2")],ok(_)),
         invoke(R2,run_tests,_{profile:"counter"},ok(_))),
        tool_registry_destroy(R2)),
    read_file_to_string(File,"xx",[]).

test(host_composition, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S=state(Root,_,_), absolute_file_name(path(git),Git,[access(execute)]),
    coding_registry_create(Root,Git,[],Registry,ok(_)),
    setup_call_cleanup(true,
        (tool_lookup(Registry,project_patch,ok(_)),
         tool_lookup(Registry,write_expert,ok(_)),
         tool_lookup(Registry,run_tests,ok(_)),
         tool_lookup(Registry,git_status,ok(_))),
        tool_registry_destroy(Registry)).

test(composition_failure_cleanup, [setup(setup_project(S)), cleanup(cleanup_project(S))]) :-
    S=state(Root,_,_),
    coding_registry_create(Root,'/does/not/exist',[],Registry,error(_)),
    assertion(Registry == none).
:- end_tests(coding_tools).
