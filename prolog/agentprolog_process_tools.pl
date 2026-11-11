:- module(agentprolog_process_tools, [process_tools_load/4]).
:- use_module(library(rlm_tool)).
:- use_module(library(rlm_tool_loader)).
:- use_module(library(rlm_closed_data)).
:- use_module(library(process)).
:- use_module(library(error)).
:- use_module(library(time)).
:- use_module(library(crypto)).
:- use_module(agentprolog_tools, []).

% Profiles are trusted host data, not repository-loaded executable config.
% Their executable and argv are fixed. The model selects only a profile id.
process_tools_load(Registry, Root0, Profiles0, Outcome) :-
    catch(load(Registry,Root0,Profiles0,Outcome), E,
        Outcome = error(process_tools_error{kind:invalid_profile,detail:E})).

load(Registry,Root0,Profiles0,Outcome) :-
    absolute_file_name(Root0,Root,[file_type(directory),access(read)]),
    closed_data_normalize(Profiles0,Profiles), must_be(list,Profiles),
    maplist(valid_profile,Profiles),
    findall(Id,(member(P,Profiles),Id=P.id),Ids),
    sort(Ids,Unique), length(Ids,N), length(Unique,U),
    (N =:= U -> true ; domain_error(unique_profile_ids,Ids)),
    term_string(Root-Profiles,Identity),
    crypto_data_hash(Identity,Hash,[algorithm(sha256)]),
    atom_concat(agentprolog_process_,Hash,Pack),
    Manifest = tool_pack_manifest{library:agentprolog,category:process,
        tools:[tool_export{name:process_run,capability:tool(process_run),effect:process},
               tool_export{name:run_tests,capability:tool(run_tests),effect:process}]},
    rlm_load_tool_pack_instance(Registry,Pack,Manifest,
        agentprolog_process_tools:register(Root,Profiles),Outcome).

valid_profile(P) :-
    must_be(string,P.id), must_be(string,P.snapshot), must_be(atom,P.executable),
    (is_absolute_file_name(P.executable),access_file(P.executable,execute) -> true
    ; domain_error(absolute_executable,P.executable)),
    must_be(list(atom),P.argv), must_be(list,P.env),
    maplist(valid_env,P.env),
    must_be(positive_integer,P.seconds),
    (P.seconds =< 300 -> true ; domain_error(process_deadline,P.seconds)),
    (memberchk(P.kind,[test,process]) -> true ; domain_error(profile_kind,P.kind)).
valid_env(Name=Value) :-
    must_be(atom,Name), must_be(atom,Value),
    ( memberchk(Name,['PATH','LANG','LC_ALL','TZ','TMPDIR']) -> true
    ; domain_error(process_environment_name,Name) ).

register(Root,Profiles,Registry,Outcome) :-
    register_one(process_run,Root,Profiles,Registry,First),
    (First = ok(_) -> register_one(run_tests,Root,Profiles,Registry,Outcome)
    ; Outcome=First).
register_one(Name,Root,Profiles,Registry,Outcome) :-
    Schema=tool_schema{name:Name,capability:tool(Name),effect:process,
        description:"Run a trusted fixed executable/argv profile in the bound project; exit status is explicit",
        arguments:_{type:object,required:[profile],additional_properties:false,
                    properties:_{profile:_{type:string}}},
        result:_{type:any},limits:_{time_limit:305.0,max_output_bytes:524288}},
    tool_register(Registry,Schema,
        tool_handler(agentprolog_process_tools:preflight(Name,Root,Profiles),
                     agentprolog_process_tools:execute(Root)),Outcome).

preflight(Name,Root,Profiles,Args,Normalized,Details) :-
    (member(P,Profiles), P.id == Args.profile -> true
    ; domain_error(known_process_profile,Args.profile)),
    (Name == run_tests, P.kind \== test -> domain_error(test_profile,Args.profile); true),
    % Use the same namespace validator; this sentinel need not exist.
    agentprolog_tools:confined_path(Root,"agentprolog-process-cwd",_),
    Normalized = json{profile:P},
    Details=operation_details{project_root:Root,profile:P.id,executable:P.executable,argv:P.argv}.

execute(Root,Args,Result) :-
    P=Args.profile,
    agentprolog_tools:confined_path(Root,"agentprolog-process-cwd",_),
    setup_call_cleanup(
        process_create(P.executable,P.argv,
            [cwd(Root),env(P.env),stdin(null),stdout(pipe(Out)),stderr(pipe(Out)),
             detached(true),process(Pid)]),
        call_with_time_limit(P.seconds, collect(Pid,Out,P,Result)),
        cleanup(Pid,Out)).

collect(Pid,Out,Profile,Result) :-
    read_string(Out,65537,Output), string_length(Output,N),
    (N =< 65536 -> true ; resource_error(process_output)),
    process_wait(Pid,Status),
    (Status = exit(Code)
    -> (Code =:= 0 -> State=passed ; State=failed),
       Result=json{profile:Profile.id,snapshot:Profile.snapshot,status:State,exit_code:Code,output:Output}
    ; term_string(Status,Reason),
      Result=json{profile:Profile.id,snapshot:Profile.snapshot,status:failed,reason:Reason,output:Output}).

cleanup(Pid,Out) :-
    catch(process_group_kill(Pid,kill),_,true),
    catch(process_wait(Pid,_,[timeout(1)]),_,true),
    catch(close(Out),_,true).
