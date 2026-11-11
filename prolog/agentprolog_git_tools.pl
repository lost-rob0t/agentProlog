:- module(agentprolog_git_tools, [git_tools_load/4]).
:- use_module(library(rlm_tool)).
:- use_module(library(rlm_tool_loader)).
:- use_module(library(crypto)).
:- use_module(library(error)).
:- use_module(agentprolog_tools, []).
:- use_module(agentprolog_process_tools, []).

git_tools_load(Registry,Root0,Git,Outcome) :-
    catch(load(Registry,Root0,Git,Outcome),E,
        Outcome=error(git_tools_error{kind:invalid_project,detail:E})).
load(Registry,Root0,Git,Outcome) :-
    absolute_file_name(Root0,Root,[file_type(directory),access(read)]),
    must_be(atom,Git),
    (is_absolute_file_name(Git),access_file(Git,execute) -> true
    ; domain_error(absolute_git_executable,Git)),
    term_string(Root-Git,Identity), crypto_data_hash(Identity,Hash,[algorithm(sha256)]),
    atom_concat(agentprolog_git_,Hash,Pack),
    findall(tool_export{name:N,capability:tool(N),effect:read},command(N,_),Exports),
    Manifest=tool_pack_manifest{library:agentprolog,category:git,tools:Exports},
    rlm_load_tool_pack_instance(Registry,Pack,Manifest,
        agentprolog_git_tools:register(Root,Git),Outcome).

command(git_status,[status,'--porcelain=v1','--untracked-files=normal']).
command(git_diff,[diff,'--no-ext-diff','--no-textconv','--no-color','HEAD','--']).
command(git_show,[show,'--no-ext-diff','--no-textconv','--no-color','--format=fuller','HEAD','--']).

register(Root,Git,Registry,Outcome) :-
    findall(N,command(N,_),Names), register_names(Names,Root,Git,Registry,Outcome).
register_names([],_,_,_,ok(registered)).
register_names([Name|Rest],Root,Git,Registry,Outcome) :-
    Schema=tool_schema{name:Name,capability:tool(Name),effect:read,
        description:"Read-only Git inspection of the host-bound project and HEAD; no model command text",
        arguments:_{type:object,required:[],properties:_{},additional_properties:false},
        result:_{type:any},limits:_{time_limit:10.0,max_output_bytes:524288}},
    tool_register(Registry,Schema,
        tool_handler(agentprolog_git_tools:preflight(Root,Git,Name),
                     agentprolog_process_tools:execute(Root)),First),
    (First=ok(_) -> register_names(Rest,Root,Git,Registry,Outcome); Outcome=First).

preflight(Root,Git,Name,_,json{profile:Profile},Details) :-
    agentprolog_tools:confined_path(Root,"agentprolog-git-cwd",_),
    command(Name,Command),
    append(['--no-pager','--no-optional-locks','-c','core.fsmonitor=false',
            '-c','core.hooksPath=/dev/null'],Command,Args),
    atom_string(Name,Id),
    Profile=profile{id:Id,snapshot:"fresh-read",executable:Git,argv:Args,seconds:5,kind:process,
        env:['PATH'='/usr/bin:/bin','LC_ALL'='C','GIT_CONFIG_NOSYSTEM'='1',
             'GIT_CONFIG_GLOBAL'='/dev/null','GIT_TERMINAL_PROMPT'='0']},
    Details=operation_details{project_root:Root,operation:Name}.
