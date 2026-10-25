:- module(agentprolog_generic_fixture, [configuration/3, model/4, validate/2]).

% Test-only model I/O. All tool execution still goes through native Prolog-RLM.
:- use_module('../../../../prolog/agentprolog_workspace_tools').
:- use_module(library(http/json)).
:- use_module(library(crypto)).
:- use_module(library(lists)).

configuration(Root, Scenario, Config) :-
    workspace_tools(Root, Tools),
    (Scenario == budget -> ModelCalls=1 ; ModelCalls=8),
    (Scenario == artifact -> Hooks=_{validate_artifact:agentprolog_generic_fixture:validate} ; Hooks=_{}),
    Config=_{profile:"generic-native-fixture",tools:Tools,
      capabilities:[tool(workspace_read),tool(workspace_create),tool(workspace_modify),tool(workspace_write),context(peek)],
      runtime_options:[provider(provider(openai_compatible,[])),provider_name(openai_compatible),
                       prompt_compile_mode(all_tools),model_handler(agentprolog_generic_fixture:model(Scenario,Root))],
      budget:_{max_model_calls:ModelCalls,max_tool_calls:8,max_iterations:8,time_limit:10.0},hooks:Hooks}.

validate(Result, approval(_{text:Result.value, fixture:true})).
model(failure, _, _, _) :- throw(error(deliberate_fixture_failure,_)).
model(Scenario, Root, Request, ok(Response)) :-
    findall(M, (member(M,Request.messages),M.role==tool), Messages), length(Messages, N),
    step(Scenario,N,Messages,Text,Calls),
    (Scenario == slow -> directory_file_path(Root,'model-completed',Marker), setup_call_cleanup(open(Marker,write,S),write(S,completed),close(S)) ; true),
    Response=model_response{provider:fake,requested_model:fake,selected_model:fake,
      response_id:"fixture",assistant:message{role:assistant,content:Text,tool_calls:Calls,reasoning:"",reasoning_details:[]},
      text:Text,tool_calls:Calls,reasoning:"",reasoning_details:[],finish_reason:stop,
      usage:usage{present:true,prompt_tokens:2,completion_tokens:1,total_tokens:3,cost:0.0},
      metadata:provider_metadata{provider:fake,http_status:200,response_received:true}}.
step(hello,_,_,"Synthetic hello",[]).
step(artifact,_,_,"Synthetic reviewable artifact",[]).
step(slow,_,_,"Synthetic slow response",[]) :- sleep(2).
step(budget,0,_,"",[Call]) :- native_call("budget_read","workspace_read",_{path:"input.txt"},Call).
step(budget,N,_,"Budget was not enforced",[]) :- N > 0.
step(read,0,_,"",[Call]) :- native_call("read1","workspace_read",_{path:"input.txt"},Call).
step(read,1,_,"",[Call]) :- native_call("peek1","context_peek",_{context:"result_read1",selector:_{type:"item",index:0}},Call).
step(read,2,Messages,"Observed actual fixture input: READ_MARKER",[]) :-
    member(M,Messages), sub_string(M.content,_,_,_,"READ_MARKER").
step(write,0,_,"",[Call]) :- native_call("create1","workspace_create",_{path:"created.txt",content:"first bytes"},Call).
step(write,1,Messages,"",[Call]) :-
    retained(Messages,"result_create1"), crypto_data_hash("first bytes",Hash,[algorithm(sha256),encoding(utf8)]),
    atom_string(Hash,HashString), native_call("modify1","workspace_modify",_{path:"created.txt",old_text:"first",new_text:"second",expected_sha256:HashString},Call).
step(write,2,Messages,"",[Call]) :-
    retained(Messages,"result_modify1"), crypto_data_hash("second bytes",Hash,[algorithm(sha256),encoding(utf8)]),
    atom_string(Hash,HashString), native_call("write1","workspace_write",_{path:"created.txt",content:"final bytes",expected_sha256:HashString},Call).
step(write,3,Messages,"",[Call]) :- retained(Messages,"result_write1"), native_call("read2","workspace_read",_{path:"created.txt"},Call).
step(write,4,_,"",[Call]) :- native_call("peek2","context_peek",_{context:"result_read2",selector:_{type:"item",index:0}},Call).
step(write,5,Messages,"Created, modified, wrote and read actual file: final bytes",[]) :-
    member(M,Messages),sub_string(M.content,_,_,_,"final bytes").
retained(Messages,Name) :- member(M,Messages),sub_string(M.content,_,_,_,Name),!.
native_call(Id,Name,Args,_{id:Id,type:"function",function:_{name:Name,arguments:JSON}}) :-
    atom_json_dict(Atom,Args,[width(0)]),atom_string(Atom,JSON).
