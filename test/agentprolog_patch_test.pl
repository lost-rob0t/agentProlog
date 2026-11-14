:- begin_tests(agentprolog_patch).
:- use_module('../prolog/agentprolog_patch').
:- use_module('../prolog/agentprolog_workspace_tools',[]).
:- use_module(library(filesex)).
:- use_module(library(readutil)).
:- use_module(library(rlm_tool)).
:- use_module(library(rlm_authority)).
:- use_module(library(rlm_effect)).
:- use_module(library(rlm_async)).
setup(R) :- tmp_file(patch,R),make_directory(R),put(R,"one two" ).
put(R,T) :- directory_file_path(R,'a.txt',P),setup_call_cleanup(open(P,write,S),format(S,'~s',[T]),close(S)).
read_fixture(R,T) :- directory_file_path(R,'a.txt',P),read_file_to_string(P,T,[]).
args(R,Edits,A) :- agentprolog_workspace_tools:preflight(R,read,_{path:"a.txt"},N,_),A=_{path:"a.txt",expected_sha256:N.before,edits:Edits}.
edits([_{old_text:"one",new_text:"first"},_{old_text:"two",new_text:"second"}]).
test(ordered_edit_receipt_and_preview,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 edits(Es),args(R,Es,A),preflight(R,A,N,D),read_fixture(R,"one two"),assertion(D.edits==Es),assertion(D.edit_count=:=2),
 execute(R,N,X),read_fixture(R,"first second"),assertion(X.edit_count=:=2),assertion(X.sha256==D.result_sha256).
test(later_edit_targets_earlier_result,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 args(R,[_{old_text:"one",new_text:"first"},_{old_text:"first",new_text:"last"}],A),preflight(R,A,N,_),execute(R,N,_),read_fixture(R,"last two").
test(late_edit_failure_never_partially_writes,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 args(R,[_{old_text:"one",new_text:"first"},_{old_text:"missing",new_text:"bad"}],A),
 catch(preflight(R,A,_,_),error(workspace_error(non_unique_match),_),Rejected=true),assertion(Rejected==true),read_fixture(R,"one two").
test(stale_while_approval_pending,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 edits(Es),args(R,Es,A),preflight(R,A,N,_),put(R,"user change"),
 catch(execute(R,N,_),error(workspace_error(stale_content),_),Rejected=true),assertion(Rejected==true),read_fixture(R,"user change").
test(empty_or_invalid_edits,[forall(member(E,[[],[_{old_text:"",new_text:"x"}],[_{old_text:"one",new_text:"x",extra:true}]])),setup(setup(R)),cleanup(delete_directory_and_contents(R)),throws(error(invalid_patch_edits,_))]) :-
 args(R,E,A),preflight(R,A,_,_).
test(too_many_edits,[setup(setup(R)),cleanup(delete_directory_and_contents(R)),throws(error(invalid_patch_edits,_))]) :-
 length(Es,17),maplist(=(_{old_text:"one",new_text:"x"}),Es),args(R,Es,A),preflight(R,A,_,_).
registry(R,Reg) :- tool_registry_create(Reg),patch_tool(R,tool(S,H)),tool_register(Reg,S,H,ok(_)).
test(native_approval_then_patch,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 directory_file_path(R,'effects.db',Store),edits(Es),args(R,Es,A),
 setup_call_cleanup(rlm_effect_store_open(Store),setup_call_cleanup(registry(R,Reg),
 (tool_invoke(Reg,[tool(workspace_patch)],workspace_patch,A,[],approval_required(P),_),read_fixture(R,"one two"),
 rlm_pending_resolution_async(P.id,F),rlm_approve(P.id,ok(_)),rlm_future_await(F,5.0,Resolution),
 assertion(Resolution.outcome=ok(_)),read_fixture(R,"first second"),rlm_future_destroy(F)),tool_registry_destroy(Reg)),rlm_effect_store_close).
test(native_deny_never_writes,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 directory_file_path(R,'effects.db',Store),edits(Es),args(R,Es,A),
 setup_call_cleanup(rlm_effect_store_open(Store),setup_call_cleanup(registry(R,Reg),
 (tool_invoke(Reg,[tool(workspace_patch)],workspace_patch,A,[],approval_required(P),_),
 rlm_deny(P.id,operator_denied,ok(_)),read_fixture(R,"one two")),tool_registry_destroy(Reg)),rlm_effect_store_close).
test(native_cancel_never_writes,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 directory_file_path(R,'effects.db',Store),edits(Es),args(R,Es,A),
 setup_call_cleanup(rlm_effect_store_open(Store),setup_call_cleanup(registry(R,Reg),
 (tool_invoke(Reg,[tool(workspace_patch)],workspace_patch,A,[],approval_required(P),_),
 rlm_pending_cancel_owner(Reg,user_cancelled),rlm_approve(P.id,error(_)),read_fixture(R,"one two")),tool_registry_destroy(Reg)),rlm_effect_store_close).
test(missing_capability_denied,[setup(setup(R)),cleanup(delete_directory_and_contents(R))]) :-
 edits(Es),args(R,Es,A),setup_call_cleanup(registry(R,Reg),
 (tool_invoke(Reg,[],workspace_patch,A,[],error(E),_),assertion(E.kind==capability_denied),read_fixture(R,"one two")),tool_registry_destroy(Reg)).
test(oversized_intermediate_rejected,[setup(setup(R)),cleanup(delete_directory_and_contents(R)),throws(error(workspace_error(file_too_large),_))]) :-
 length(Cs,65535),maplist(=(0'a),Cs),string_codes(T,Cs),string_concat("X",T,Source),put(R,Source),
 args(R,[_{old_text:"X",new_text:"XX"}],A),preflight(R,A,_,_).
:- end_tests(agentprolog_patch).
