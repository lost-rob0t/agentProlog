:- begin_tests(agentprolog_workspace_tools).
:- use_module('../prolog/agentprolog_workspace_tools').
:- use_module(library(filesex)).
:- use_module(library(readutil)).
:- use_module(library(rlm_tool)).
:- use_module(library(rlm_authority)).
:- use_module(library(rlm_effect)).
:- use_module(library(rlm_async)).

setup_workspace(Root) :- tmp_file(agentprolog_workspace,Root), make_directory(Root).
cleanup_workspace(Root) :- delete_directory_and_contents(Root).
write_fixture(Root, Name, Text) :- directory_file_path(Root,Name,P),
    setup_call_cleanup(open(P,write,S,[encoding(utf8)]),format(S,'~s',[Text]),close(S)).
read_fixture(Root, Name, Text) :- directory_file_path(Root,Name,P),read_file_to_string(P,Text,[]).
operation(Root, Op, Args, Result) :- preflight(Root,Op,Args,Normalized,_),execute(Root,Op,Normalized,Result).

test(read_create_modify_write_actual_files,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R))]) :-
    operation(R,create,_{path:"note.txt",content:"one two\n"},Created),
    read_fixture(R,'note.txt',"one two\n"),
    operation(R,read,_{path:"note.txt"},Read), assertion(Read.sha256==Created.sha256),
    assertion(Read.content=="one two\n"),
    operation(R,modify,_{path:"note.txt",old_text:"two",new_text:"three",expected_sha256:Read.sha256},Modified),
    read_fixture(R,'note.txt',"one three\n"),
    operation(R,write,_{path:"note.txt",content:"final\n",expected_sha256:Modified.sha256},Final),
    assertion(Final.bytes=:=6), read_fixture(R,'note.txt',"final\n"),
    directory_files(R,Files), sort(Files,Sorted), assertion(Sorted==['.','..','note.txt']).

test(create_never_overwrites,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R)),throws(error(workspace_error(already_exists),_))]) :-
    write_fixture(R,'x',"original"), operation(R,create,_{path:"x",content:"replacement"},_).
test(stale_hash_rejected,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R)),throws(error(workspace_error(stale_content),_))]) :-
    write_fixture(R,'x',"original"),operation(R,write,_{path:"x",content:"replacement",expected_sha256:"incorrect"},_).
test(change_while_approval_pending_rejected,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R))]) :-
    write_fixture(R,'x',"original"), operation(R,read,_{path:"x"},Read),
    preflight(R,write,_{path:"x",content:"replacement",expected_sha256:Read.sha256},N,_),
    write_fixture(R,'x',"someone else's edit"),
    catch(execute(R,write,N,_),error(workspace_error(stale_content),_),Rejected=true),
    assertion(Rejected==true),read_fixture(R,'x',"someone else's edit").
test(non_unique_modification_rejected,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R)),throws(error(workspace_error(non_unique_match),_))]) :-
    write_fixture(R,'x',"a a"),operation(R,read,_{path:"x"},Read),
    operation(R,modify,_{path:"x",old_text:"a",new_text:"b",expected_sha256:Read.sha256},_).
test(paths_cannot_escape,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R))]) :-
    forall(member(Path,["../escape","/tmp/escape","a/../../escape","a\\escape","a//b","./x"]),
      (catch(preflight(R,create,_{path:Path,content:"no"},_,_),error(workspace_error(_),_),Rejected=true),assertion(Rejected==true))).
test(symlink_leaf_and_parent_rejected,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R))]) :-
    setup_workspace(Outside),setup_call_cleanup(true,
      (write_fixture(Outside,'secret',"outside"),directory_file_path(R,alias,Alias),link_file(Outside,Alias,symbolic),
       catch(operation(R,read,_{path:"alias/secret"},_),error(workspace_error(symlink_denied),_),Rejected=true),
       assertion(Rejected==true),
       directory_file_path(Outside,secret,Secret),directory_file_path(R,leaf,Leaf),link_file(Secret,Leaf,symbolic),
       catch(operation(R,write,_{path:"leaf",content:"bad",expected_sha256:"x"},_),error(workspace_error(symlink_denied),_),Denied=true),
       assertion(Denied==true),read_fixture(Outside,secret,"outside")),cleanup_workspace(Outside)).
test(oversized_content_rejected,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R)),throws(error(workspace_error(file_too_large),_))]) :-
    length(Codes,65537),maplist(=(0'a),Codes),string_codes(Text,Codes),operation(R,create,_{path:"large",content:Text},_).
test(missing_file_reported,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R)),throws(error(workspace_error(missing_file),_))]) :-
    operation(R,read,_{path:"absent"},_).

setup_registry(Root, Registry) :- tool_registry_create(Registry),workspace_tools(Root,Tools),
    forall(member(tool(S,H),Tools),tool_register(Registry,S,H,ok(_))).
test(native_capability_denial_prevents_read,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R))]) :-
    setup_call_cleanup(setup_registry(R,Registry),
      (write_fixture(R,'x',"safe"),tool_invoke(Registry,[],workspace_read,_{path:"x"},[],error(E),_),assertion(E.kind==capability_denied)),
      tool_registry_destroy(Registry)).
test(native_approval_required_then_exact_write,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R))]) :-
    directory_file_path(R,'effects.db',Store),
    setup_call_cleanup(rlm_effect_store_open(Store),
      setup_call_cleanup(setup_registry(R,Registry),
        (tool_invoke(Registry,[tool(workspace_create)],workspace_create,_{path:"approved.txt",content:"approved"},[],approval_required(Pending),_),
         directory_file_path(R,'approved.txt',Path),assertion(\+exists_file(Path)),
         rlm_pending_resolution_async(Pending.id,Future),rlm_approve(Pending.id,ok(_)),
         rlm_future_await(Future,5.0,Resolution), get_dict(outcome,Resolution,ok(_)),
         read_fixture(R,'approved.txt',"approved"),rlm_future_destroy(Future),
         rlm_approve(Pending.id,error(Stale)),assertion(Stale.kind==approval_not_pending)),
        tool_registry_destroy(Registry)),rlm_effect_store_close).
test(native_deny_never_writes,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R))]) :-
    directory_file_path(R,'effects.db',Store),
    setup_call_cleanup(rlm_effect_store_open(Store),
      setup_call_cleanup(setup_registry(R,Registry),
        (tool_invoke(Registry,[tool(workspace_create)],workspace_create,_{path:"denied.txt",content:"no"},[],approval_required(P),_),
         rlm_deny(P.id,operator_denied,ok(_)),
         directory_file_path(R,'denied.txt',Path),assertion(\+exists_file(Path)),
         rlm_approve(P.id,error(Stale)),assertion(Stale.kind==approval_not_pending)),
        tool_registry_destroy(Registry)),rlm_effect_store_close).
test(native_owner_cancel_never_writes,[setup(setup_workspace(R)),cleanup(cleanup_workspace(R))]) :-
    directory_file_path(R,'effects.db',Store),
    setup_call_cleanup(rlm_effect_store_open(Store),
      setup_call_cleanup(setup_registry(R,Registry),
        (tool_invoke(Registry,[tool(workspace_create)],workspace_create,_{path:"cancelled.txt",content:"no"},[],approval_required(P),_),
         rlm_pending_cancel_owner(Registry,user_cancelled),
         directory_file_path(R,'cancelled.txt',Path),assertion(\+exists_file(Path)),
         rlm_approve(P.id,error(Stale)),assertion(Stale.kind==approval_not_pending)),
        tool_registry_destroy(Registry)),rlm_effect_store_close).
:- end_tests(agentprolog_workspace_tools).
