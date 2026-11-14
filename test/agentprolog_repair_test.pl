:- begin_tests(agentprolog_repair).
:- use_module('../prolog/agentprolog_repair').
:- use_module(library(filesex)).
setup(R,N) :- tmp_file(repair,R),make_directory(R),absolute_file_name(path(node),N,[access(execute)]),
 directory_file_path(R,'source.mjs',P),setup_call_cleanup(open(P,write,S),write(S,'export const value=1;'),close(S)).
test(composes_only_requested_tools,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 repair_tools(R,N,["source.mjs"],["source.test.mjs"],_{},Tools,Caps),
 findall(Name,(member(tool(S,_),Tools),Name=S.name),Names),
 assertion(Names==[workspace_list,workspace_search,workspace_read,workspace_patch,workspace_test]),
 assertion(memberchk(tool(workspace_patch),Caps)),assertion(\+memberchk(tool(workspace_write),Caps)).
test(read_outside_manifest_denied,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R)),throws(error(repair_path_not_allowed,_))]) :-
 repair_tools(R,N,["source.mjs"],["source.test.mjs"],_{},Tools,_),
 member(tool(S,tool_handler(Pre,_)),Tools),S.name==workspace_read,call(Pre,_{path:"other.mjs"},_,_).
test(patch_outside_manifest_denied,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R)),throws(error(repair_path_not_allowed,_))]) :-
 repair_tools(R,N,["source.mjs"],["source.test.mjs"],_{},Tools,_),
 member(tool(S,tool_handler(Pre,_)),Tools),S.name==workspace_patch,call(Pre,_{path:"source.test.mjs"},_,_).
test(runner_preserves_additional_evidence,[setup(setup(R,N)),cleanup(delete_directory_and_contents(R))]) :-
 repair_tools(R,N,["source.mjs"],["source.test.mjs"],_{evidence_files:["extra.txt"]},Tools,_),
 member(tool(S,tool_handler(Pre,_)),Tools),S.name==workspace_test,
 Pre=agentprolog_test_runner:preflight(_,_,_,Policy),assertion(Policy.evidence_files==["extra.txt","source.mjs"]).
:- end_tests(agentprolog_repair).
