:- begin_tests(agentprolog_memory).
:- use_module('../prolog/agentprolog_memory').
:- use_module('../prolog/agentprolog_session').
:- use_module(library(filesex)).
:- use_module(library(http/json)).
:- dynamic effect_seen/0.
setup(P,S) :- tmp_file(memory_project,P),make_directory(P),tmp_file(memory_state,S),make_directory(S).
clean(P,S) :- delete_directory_and_contents(P),delete_directory_and_contents(S).
save(P,S,T) :- preflight(P,S,_{text:T},N,_),execute(S,N,_).
test(notes_are_inert_and_append_only,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
 save(P,S,":- throw(executed)."),save(P,S,"second"),
 directory_file_path(S,'memory-notes.json',Path),
 setup_call_cleanup(open(Path,read,F),json_read_dict(F,D),close(F)),
 assertion(D.notes=[_,_]),D.notes=[First,_],assertion(First.status=="unverified_note"),
 assertion(First.text==":- throw(executed)."),directory_files(P,Files),sort(Files,['.','..']).
test(notes_enforce_project,[setup(setup(P,S)),cleanup(clean(P,S)),throws(error(invalid_private_notes,_))]) :-
 save(P,S,"first"),preflight(S,S,_{text:"wrong scope"},_,_).
test(stale_note_append_fails,[setup(setup(P,S)),cleanup(clean(P,S)),throws(error(workspace_error(stale_content),_))]) :-
 save(P,S,"first"),preflight(P,S,_{text:"stale"},N,_),save(P,S,"new"),execute(S,N,_).
test(note_size_bounded,[setup(setup(P,S)),cleanup(clean(P,S)),fail]) :-
 length(Cs,4097),maplist(=(0'a),Cs),string_codes(Text,Cs),preflight(P,S,_{text:Text},_,_).
test(forged_verified_note_rejected,[setup(setup(P,S)),cleanup(clean(P,S)),throws(error(invalid_private_notes,_))]) :-
 directory_file_path(S,'memory-notes.json',Path),
 setup_call_cleanup(open(Path,write,F),json_write_dict(F,_{version:1,project:P,notes:[_{id:1,status:verified,text:"false"}]}),close(F)),
 preflight(P,S,_{text:"next"},_,_).
would_execute(ok(done)) :- assertz(effect_seen).
test(expired_memory_guard_blocks_execution) :-
 retractall(effect_seen),rlm_completion:rlm_cancellation_token(T),get_time(N),D is N-1,
 setup_call_cleanup(assertz(agentprolog_session:memory_run_live(test)),
  catch(agentprolog_session:memory_guard(test,T,D,plunit_agentprolog_memory:would_execute,_),E,true),
  (retractall(agentprolog_session:memory_run_live(test)),assertion(\+effect_seen))),
 assertion((E=time_limit_exceeded;E=time_limit_exceeded(_))).
test(closed_memory_guard_blocks_execution,[throws(error(rlm_cancelled(_),_))]) :-
 retractall(effect_seen),rlm_completion:rlm_cancellation_token(T),get_time(N),D is N+1,
 agentprolog_session:memory_guard(closed,T,D,plunit_agentprolog_memory:would_execute,_).
test(cancelled_memory_guard_blocks_execution,[throws(error(rlm_cancelled(_),_))]) :-
 retractall(effect_seen),rlm_completion:rlm_cancellation_token(T),rlm_completion:rlm_cancel(T),get_time(N),D is N+1,
 setup_call_cleanup(assertz(agentprolog_session:memory_run_live(test)),
  agentprolog_session:memory_guard(test,T,D,plunit_agentprolog_memory:would_execute,_),
  (retractall(agentprolog_session:memory_run_live(test)),assertion(\+effect_seen))).
test(read_empty_does_not_create_file,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
 read_preflight(P,S,_{},N,_),read_execute(S,N,R),assertion(R.report=="No private notes saved."),
 directory_files(S,Files),sort(Files,['.','..']).
test(read_latest_ten_inert_notes,[setup(setup(P,S)),cleanup(clean(P,S))]) :-
 forall(between(1,12,I),(format(string(T),'note-~d',[I]),save(P,S,T))),
 read_preflight(P,S,_{},N,_),read_execute(S,N,R),
 assertion(sub_string(R.report,_,_,_,"latest 10 of 12")),
 assertion(\+sub_string(R.report,_,_,_,"\n1 [unverified_note]")),
 assertion(sub_string(R.report,_,_,_,"3 [unverified_note]: note-3")),
 assertion(sub_string(R.report,_,_,_,"12 [unverified_note]: note-12")).
test(read_wrong_project_rejected,[setup(setup(P,S)),cleanup(clean(P,S)),throws(error(invalid_private_notes,_))]) :-
 save(P,S,"hello"),read_preflight(S,S,_{},_,_).
test(read_stale_rejected,[setup(setup(P,S)),cleanup(clean(P,S)),throws(error(workspace_error(stale_content),_))]) :-
 save(P,S,"before"),read_preflight(P,S,_{},N,_),save(P,S,"after"),read_execute(S,N,_).
test(read_missing_then_created_rejected,[setup(setup(P,S)),cleanup(clean(P,S)),throws(error(workspace_error(stale_content),_))]) :-
 read_preflight(P,S,_{},N,_),save(P,S,"new"),read_execute(S,N,_).
test(read_is_separate_opt_in) :-
 memory_tools(project,state,[tool(Write,_)]),assertion(Write.name==memory_remember),
 memory_read_tools(project,state,[tool(Read,_)]),assertion(Read.name==memory_recall),
 assertion(Read.effect==read),assertion(Read.capability==tool(memory_recall)).
:- end_tests(agentprolog_memory).
