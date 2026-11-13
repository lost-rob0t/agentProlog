:- module(agentprolog_check_tool,[syntax_check_tool/3,preflight/4,execute/4]).

/** Fixed, bounded Node syntax checking. No shell, script execution or ambient env. */
:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module(library(time)).
:- use_module('./agentprolog_workspace_tools',[]).

syntax_check_tool(Root,Node,tool(Schema,tool_handler(agentprolog_check_tool:preflight(Root),
                                                 agentprolog_check_tool:execute(Root,Node)))) :-
    absolute_file_name(Node,_,[access(execute),file_errors(error)]),
    Schema=tool_schema{name:workspace_check,description:"Check JavaScript syntax with Node --check; does not execute the program. Inspect exit_code and output.",
      capability:tool(workspace_check),effect:process,
      arguments:_{type:object,required:[path],properties:_{path:_{type:string}},additional_properties:false},
      result:_{type:object,required:[path,sha256,exit_code,output],additional_properties:false,
        properties:_{path:_{type:string},sha256:_{type:string},exit_code:_{type:integer},output:_{type:string}}},
      limits:_{time_limit:8.0,max_output_bytes:12000}}.

preflight(Root,Args,Normalized,Details) :-
    agentprolog_workspace_tools:preflight(Root,read,Args,Normalized,Details).
execute(Root,Node,Args,Result) :-
    agentprolog_workspace_tools:execute(Root,read,Args,Read),
    setup_call_cleanup(
      process_create(Node,['--check',Args.absolute],
        [cwd(Root),env([]),stdin(null),stdout(null),stderr(pipe(Output)),process(Pid)]),
      call_with_time_limit(5,
        (read_string(Output,8193,Text),string_length(Text,Size),
         (Size>8192 -> throw(error(syntax_check_output_limit,_)) ; true),
         process_wait(Pid,Exit),exit_code(Exit,Code),
         Result=_{path:Args.path,sha256:Read.sha256,exit_code:Code,output:Text})),
      (close(Output),catch(process_kill(Pid,kill),_,true),catch(process_wait(Pid,_),_,true))).
exit_code(exit(Code),Code) :- !.
exit_code(killed(_),137).
