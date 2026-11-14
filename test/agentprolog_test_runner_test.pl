:- begin_tests(agentprolog_test_runner).
:- use_module('../prolog/agentprolog_test_runner').
:- use_module(library(filesex)).
:- use_module(library(process)).
:- use_module(library(rlm_tool),[]).
setup(R,Node) :- tmp_file(test_runner,R),make_directory(R),absolute_file_name(path(node),Node,[access(execute)]).
source(R,T) :- directory_file_path(R,'test.mjs',P),setup_call_cleanup(open(P,write,S),format(S,'~s',[T]),close(S)).
configured(R,Node,Policy,Pre,Run) :- node_test_tool(R,Node,["test.mjs"],Policy,tool(_,tool_handler(Pre,Run))).
run(R,Node,Policy,Result) :- configured(R,Node,Policy,Pre,Run),call(Pre,_{},N,_),call(Run,N,Result).
test(real_pass_records_exit_counts_hashes,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 source(R,"import test from 'node:test'; test('real pass',()=>{});"),run(R,N,_{},X),
 assertion(X.status=="completed"),assertion(X.exit_code=:=0),assertion(X.counts.passed=:=1),assertion(X.counts.failed=:=0),
 assertion(X.truncated==false),assertion(sub_string(X.evidence,_,_,_,"sha256")).
test(real_failure_not_success,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 source(R,"import test from 'node:test'; test('failure',()=>{throw Error('expected');});"),run(R,N,_{},X),
 assertion(X.exit_code=\=0),assertion(X.counts.failed=:=1).
test(stale_approved_file_blocks_execution,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R)),throws(error(workspace_error(stale_content),_))]) :-
 source(R,""),configured(R,N,_{},Pre,Run),call(Pre,_{},A,_),source(R,"throw Error('changed');"),call(Run,A,_).
test(environment_is_not_inherited,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 setup_call_cleanup(setenv('MARA_TEST_SECRET','synthetic'),
 (source(R,"import test from 'node:test'; import assert from 'node:assert'; test('env',()=>assert.equal(process.env.MARA_TEST_SECRET,undefined));"),run(R,N,_{},X),assertion(X.exit_code=:=0)),unsetenv('MARA_TEST_SECRET')).
test(output_limit_is_bounded_and_not_success,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 source(R,"process.stdout.write('x'.repeat(1000000));"),run(R,N,_{output_bytes:256},X),
 assertion(X.status=="output_limit"),assertion(X.exit_code=:= -1),assertion(X.truncated==true),string_length(X.output,L),assertion(L=<256).
test(timeout_stops_process_group,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 source(R,"import {writeFileSync} from 'node:fs'; setTimeout(()=>writeFileSync('late','bad'),2000);"),
 run(R,N,_{timeout:0.2},X),assertion(X.status=="timeout"),sleep(2.2),directory_file_path(R,late,P),assertion(\+exists_file(P)).
test(normal_exit_cleans_up_unref_descendant,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 source(R,"import {spawn} from 'node:child_process'; spawn(process.execPath,['-e',\"setTimeout(()=>require('fs').writeFileSync('late','bad'),2000)\"],{stdio:'ignore'}).unref();"),
 run(R,N,_{},X),assertion(X.exit_code=:=0),sleep(2.2),directory_file_path(R,late,P),assertion(\+exists_file(P)).
test(no_model_supplied_arguments_schema,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 node_test_tool(R,N,["test.mjs"],_{},tool(S,_)),assertion(S.effect==process),assertion(S.arguments.additional_properties==false).
test(subject_changed_during_run_is_not_current_evidence,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 directory_file_path(R,'subject.txt',P),setup_call_cleanup(open(P,write,F),write(F,old),close(F)),
 source(R,"import {writeFileSync} from 'node:fs';writeFileSync('subject.txt','new');"),
 run(R,N,_{evidence_files:["subject.txt"]},X),assertion(X.exit_code=:=0),
 assertion(X.status=="stale_evidence"),assertion(X.evidence_current==false).
test(extra_model_arguments_rejected,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 source(R,""),node_test_tool(R,N,["test.mjs"],_{},tool(S,H)),
 setup_call_cleanup(rlm_tool:tool_registry_create(Reg),
 (rlm_tool:tool_register(Reg,S,H,ok(_)),rlm_tool:tool_invoke_execute(Reg,[tool(workspace_test)],workspace_test,_{argv:["--eval","bad"]},[],X),assertion(X.outcome=error(_))),
 rlm_tool:tool_registry_destroy(Reg)).
test(stale_approved_executable_blocks_execution,[setup(setup(R,_)),cleanup(delete_directory_and_contents(R)),throws(error(stale_test_binary,_))]) :-
 directory_file_path(R,'fake-node',N),
 setup_call_cleanup(open(N,write,F),write(F,'#!/bin/sh\nexit 0\n'),close(F)),
 process_create(path(chmod),['+x',N],[process(Pid)]),process_wait(Pid,exit(0)),
 source(R,""),configured(R,N,_{},Pre,Run),call(Pre,_{},A,_),
 setup_call_cleanup(open(N,append,G),write(G,'# changed\n'),close(G)),call(Run,A,_).
test(missing_capability_blocks_process,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 source(R,"import {writeFileSync} from 'node:fs';writeFileSync('executed','bad');"),
 node_test_tool(R,N,["test.mjs"],_{},tool(S,H)),
 setup_call_cleanup(rlm_tool:tool_registry_create(Reg),
 (rlm_tool:tool_register(Reg,S,H,ok(_)),rlm_tool:tool_invoke_execute(Reg,[],workspace_test,_{},[],X),
 assertion(X.outcome=error(_))),rlm_tool:tool_registry_destroy(Reg)),
 directory_file_path(R,executed,P),assertion(\+exists_file(P)).
test(ambiguous_tap_count_is_omitted) :-
 agentprolog_test_runner:tap_counts("# tests 2\n# pass 2\n# pass 900\n# fail 0\n",X),
 assertion(X.tests=:=2),assertion(X.failed=:=0),assertion(\+get_dict(passed,X,_)).
test(timeout_stops_spawned_descendant,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 source(R,"import {spawn} from 'node:child_process';import {writeFileSync} from 'node:fs';spawn(process.execPath,['-e',\"require('fs').writeFileSync('child-started','yes');setTimeout(()=>require('fs').writeFileSync('late','bad'),2000)\"],{stdio:'ignore'}).unref();setInterval(()=>{},1000);"),
 run(R,N,_{timeout:1.0},X),assertion(X.status=="timeout"),
 directory_file_path(R,'child-started',Started),assertion(exists_file(Started)),
 sleep(2.2),directory_file_path(R,late,P),assertion(\+exists_file(P)).
:- end_tests(agentprolog_test_runner).
