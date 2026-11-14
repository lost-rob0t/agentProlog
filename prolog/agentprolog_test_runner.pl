:- module(agentprolog_test_runner,[node_test_tool/5,preflight/7,execute/5]).
/** Fixed operator-selected Node tests. Process approval required.
    This is NOT an OS or network sandbox for test code. */
:- use_module(library(process)).
:- use_module(library(time)).
:- use_module(library(crypto)).
:- use_module(library(utf8)).
:- use_module('./agentprolog_workspace_tools',[]).
node_test_tool(Project,Node,Tests,Policy,tool(Schema,tool_handler(
 agentprolog_test_runner:preflight(Root,Executable,Tests,Limits),
 agentprolog_test_runner:execute(Root,Executable,Limits)))) :-
 current_prolog_flag(unix,true),is_absolute_file_name(Node),
 absolute_file_name(Node,Executable,[access(execute),file_errors(error)]),
 absolute_file_name(Project,Root,[file_type(directory),access(read),file_errors(error)]),
 valid_files(Tests,8),Tests\=[],valid_policy(Policy,Limits),
 Time is Limits.timeout+10,WireLimit is Limits.output_bytes*8+262144,
 Schema=tool_schema{name:workspace_test,description:"Execute only operator-configured Node test files. Requires process approval. Runs project code, NOT sandboxed. Inspect status, exit_code and evidence; TAP counts are untrusted output.",
 capability:tool(workspace_test),effect:process,
 arguments:_{type:object,properties:_{},additional_properties:false},
 result:_{type:object,required:[status,exit_code,output,truncated,evidence,evidence_current,binary_sha256,counts],additional_properties:false,
 properties:_{status:_{type:string},exit_code:_{type:integer},output:_{type:string},truncated:_{type:boolean},
 evidence:_{type:string},evidence_current:_{type:boolean},binary_sha256:_{type:string},
 counts:_{type:object,additional_properties:false,properties:_{tests:_{type:integer},passed:_{type:integer},failed:_{type:integer}}}}},
 limits:_{time_limit:Time,max_output_bytes:WireLimit}}.
valid_policy(P,L) :- is_dict(P),dict_pairs(P,_,Pairs),forall(member(K-_,Pairs),memberchk(K,[timeout,output_bytes,evidence_files])),
 put_dict(P,policy{timeout:5.0,output_bytes:16384,evidence_files:[]},L),
 number(L.timeout),L.timeout>=0.1,L.timeout=<60,integer(L.output_bytes),between(256,65536,L.output_bytes),
 valid_files(L.evidence_files,32),!.
valid_policy(_,_) :- throw(error(invalid_test_runner_policy,_)).
valid_files(Files,Max) :- is_list(Files),length(Files,N),N=<Max,
 forall(member(P,Files),(string(P),string_length(P,L),L>0,L=<1024)),sort(Files,U),length(U,N).
preflight(Root,Node,Tests,Limits,_,N,Details) :-
 append(Tests,Limits.evidence_files,All0),sort(All0,All),maplist(snapshot(Root),All,Snapshots),
 crypto_file_hash(Node,Hash,[algorithm(sha256),encoding(octet)]),
 findall(Absolute,(member(P,Tests),member(S,Snapshots),S.path==P,Absolute=S.absolute),Paths),
 append(['--test','--test-reporter=tap'],Paths,Argv),
 findall(_{path:P,sha256:H},(member(S,Snapshots),P=S.path,H=S.before),Evidence),
 N=_{snapshots:Snapshots,argv:Argv,binary_sha256:Hash,evidence:Evidence},
 Details=_{operation:execute_project_tests,executable:Node,argv:Argv,cwd:Root,
 evidence:Evidence,binary_sha256:Hash,timeout_seconds:Limits.timeout,output_bytes:Limits.output_bytes,
 warning:"Runs project code with host permissions. No OS/network sandbox; undeclared imports and dependencies are not snapshotted."}.
snapshot(Root,Path,S) :- agentprolog_workspace_tools:preflight(Root,read,_{path:Path},S,_).
execute(Root,Node,Limits,N,Result) :-
 maplist(revalidate(Root),N.snapshots),crypto_file_hash(Node,Hash,[algorithm(sha256),encoding(octet)]),
 (Hash==N.binary_sha256 -> true ; throw(error(stale_test_binary,_))),
 Progress=progress([],0),
 setup_call_cleanup(
  process_create(Node,N.argv,[cwd(Root),env([]),stdin(null),stdout(pipe(Output,[encoding(octet)])),
    stderr(pipe(Output,[encoding(octet)])),process(Pid),detached(true)]),
  catch(call_with_time_limit(Limits.timeout,capture(Output,Pid,Limits.output_bytes,Progress,Status,Code)),
    time_limit_exceeded,(Status="timeout",Code= -1)),
  cleanup_process(Pid,Output)),
 arg(1,Progress,Reverse),reverse(Reverse,Chunks),atomics_to_string(Chunks,"",Octets),
 string_codes(Octets,Bytes),
 (phrase(utf8_codes(Codes),Bytes) -> string_codes(Text,Codes) ; Text=Octets),
 (Status=="completed" -> Truncated=false ; Truncated=true),
 (catch(maplist(revalidate(Root),N.snapshots),_,fail) -> Current=true,FinalStatus=Status
 ; Current=false,(Status=="completed" -> FinalStatus="stale_evidence" ; FinalStatus=Status)),
 tap_counts(Text,Counts),term_string(N.evidence,Evidence,[quoted(true)]),atom_string(Hash,HashString),
 Result=_{status:FinalStatus,exit_code:Code,output:Text,truncated:Truncated,evidence:Evidence,
 evidence_current:Current,binary_sha256:HashString,counts:Counts}.
revalidate(Root,S) :- agentprolog_workspace_tools:execute(Root,read,S,_).
capture(Stream,Pid,Limit,P,Status,Code) :-
 arg(2,P,N),Want is min(1024,Limit-N+1),read_string(Stream,Want,Chunk),string_length(Chunk,Size),
 Keep is min(Size,Limit-N),sub_string(Chunk,0,Keep,_,Prefix),arg(1,P,Chunks),nb_setarg(1,P,[Prefix|Chunks]),
 Total is N+Keep,nb_setarg(2,P,Total),
 (Size>Keep -> Status="output_limit",Code= -1
 ; Size<Want -> process_wait(Pid,Exit),exit_code(Exit,Code),Status="completed"
 ; capture(Stream,Pid,Limit,P,Status,Code)).
cleanup_process(Pid,Stream) :-
 catch(process_group_kill(Pid,kill),_,true),catch(close(Stream),_,true),catch(process_wait(Pid,_,[timeout(1)]),_,true).
exit_code(exit(C),C) :- !.
exit_code(killed(_),137).
tap_counts(Text,Counts) :-
 split_string(Text,"\n","\r",Lines),
 findall(K-N,(member(K-Prefix,[tests-"# tests ",passed-"# pass ",failed-"# fail "]),
  findall(V,(member(Line,Lines),string_concat(Prefix,Digits,Line),catch(number_string(V,Digits),_,fail),integer(V),V>=0),[N])),Pairs),
 dict_pairs(Counts,counts,Pairs).
