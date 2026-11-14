:- begin_tests(agentprolog_discovery).
:- use_module('../prolog/agentprolog_discovery').
:- use_module(library(filesex)).
:- use_module(library(rlm_tool),[]).
setup(R) :- tmp_file(discovery,R),make_directory(R).
write_source(R,P,T) :- directory_file_path(R,P,A),setup_call_cleanup(open(A,write,S),format(S,'~s',[T]),close(S)).
handlers(R,Files,List,Search) :- discovery_tools(R,Files,[tool(_,List),tool(_,Search)]).
test(list_only_manifest,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 write_source(R,'a.pl',"alpha"),write_source(R,'other.pl',"hidden"),handlers(R,["a.pl"],List,_),
 call(List,_{},X),assertion(X.entries=[_{path:"a.pl",status:"available"}]),assertion(X.content_read==false).
test(literal_search_provenance,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 write_source(R,'a.pl',"alpha\n[b].\nalpha\n"),handlers(R,["a.pl"],_,Search),
 call(Search,_{text:"[b]."},X),X.matches=[M],assertion(M.line=:=2),assertion(M.column=:=0),
 assertion(M.snippet=="[b]."),assertion(M.path=="a.pl"),string_length(M.sha256,64),assertion(X.budget_exhausted==false).
test(private_paths_rejected,[forall(member(P,[".prolog/state.pl",".git/config",".env","secrets/a.pl","credentials.txt","src/private.js","../a.pl","a/../b.pl","/tmp/a.pl","keys.json","node_modules/a.js","nested/.hidden/a.pl"])),setup(setup(R)),cleanup(delete_directory_and_contents(R)),throws(error(invalid_discovery_manifest,_))]) :-
 discovery_tools(R,[P],_).
test(symlink_manifest_denied,[setup(setup(R)),cleanup(delete_directory_and_contents(R)),throws(error(workspace_error(symlink_denied),_))]) :-
 write_source(R,'real.pl',"alpha"),directory_file_path(R,'real.pl',A),directory_file_path(R,'link.pl',B),link_file(A,B,symbolic),discovery_tools(R,["link.pl"],_).
test(symlink_replacement_not_read,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 write_source(R,'a.pl',"alpha"),handlers(R,["a.pl"],_,Search),directory_file_path(R,'a.pl',A),delete_file(A),link_file('/etc/passwd',A,symbolic),
 call(Search,_{text:"root"},X),assertion(X.matches==[]),X.files=[F],assertion(F.status=="unavailable_or_not_bounded_text"),assertion(X.absence_proven==false).
test(oversized_file_is_unresolved,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 length(Cs,65537),maplist(=(0'a),Cs),string_codes(T,Cs),write_source(R,'a.pl',T),handlers(R,["a.pl"],_,Search),
 call(Search,_{text:"a"},X),assertion(X.matches==[]),X.files=[F],assertion(F.status=="unavailable_or_not_bounded_text").
test(match_limit,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 length(Lines,70),maplist(=("alpha"),Lines),atomics_to_string(Lines,"\n",T),write_source(R,'a.pl',T),handlers(R,["a.pl"],_,Search),
 call(Search,_{text:"alpha"},X),length(X.matches,64),assertion(X.budget_exhausted==true).
test(file_limit,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 findall(P,(between(1,33,I),format(string(P),'f~d.pl',[I]),write_source(R,P,"alpha")),Files),handlers(R,Files,_,Search),
 call(Search,_{text:"alpha"},X),length(X.matches,32),assertion(X.budget_exhausted==true),assertion(X.manifest_files=:=33).
test(capability_required,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 write_source(R,'a.pl',"alpha"),discovery_tools(R,["a.pl"],[_,tool(S,H)]),
 setup_call_cleanup(rlm_tool:tool_registry_create(Reg),
 (rlm_tool:tool_register(Reg,S,H,ok(_)),rlm_tool:tool_invoke_execute(Reg,[],workspace_search,_{text:"alpha"},[],X),assertion(X.outcome=error(_))),rlm_tool:tool_registry_destroy(Reg)).
test(empty_query_rejected,[setup(setup(R)),cleanup(delete_directory_and_contents(R)),throws(error(invalid_discovery_query,_))]) :-
 write_source(R,'a.pl',"alpha"),handlers(R,["a.pl"],_,Search),call(Search,_{text:""},_).
test(canonical_tool_success_and_closed_arguments,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 write_source(R,'a.pl',"alpha"),discovery_tools(R,["a.pl"],[_,tool(S,H)]),
 setup_call_cleanup(rlm_tool:tool_registry_create(Reg),
 (rlm_tool:tool_register(Reg,S,H,ok(_)),
  rlm_tool:tool_invoke_execute(Reg,[tool(workspace_search)],workspace_search,_{text:"alpha"},[],X),
  assertion(X.outcome=ok(_)),
  rlm_tool:tool_invoke_execute(Reg,[tool(workspace_search)],workspace_search,_{text:"alpha",path:"/etc/passwd"},[],Bad),
  assertion(Bad.outcome=error(_))),rlm_tool:tool_registry_destroy(Reg)).
test(deadline_not_reclassified_as_missing) :-
 catch(agentprolog_discovery:unavailable(time_limit_exceeded),E,true),assertion(E==time_limit_exceeded).
test(cancellation_not_reclassified_as_missing,[throws(error(cancelled,test))]) :-
 agentprolog_discovery:unavailable(error(cancelled,test)).
:- end_tests(agentprolog_discovery).
