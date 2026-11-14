:- module(agentprolog_generic_fixture, [configuration/3, model/4, validate/2]).

% Test-only model I/O. All tool execution still goes through native Prolog-RLM.
:- use_module('../../../../prolog/agentprolog_workspace_tools').
:- use_module(library(http/json)).
:- use_module('../../../../prolog/agentprolog_experts').
:- use_module('../../../../prolog/agentprolog_workflow',[workflow_initialize/3,workflow_tools/3]).
:- use_module('../../../../prolog/agentprolog_memory',[memory_tools/3,memory_read_tools/3]).
:- use_module(library(filesex)).
:- use_module('../../../../prolog/agentprolog_rsi').
:- use_module('../../../../prolog/agentprolog_context_experiment').
:- use_module('../../../../prolog/agentprolog_learning').
:- use_module('../../../../prolog/agentprolog_test_runner',[node_test_tool/5]).
:- use_module('../../../../prolog/agentprolog_repair',[repair_tools/7]).
:- use_module(library(crypto)).
:- use_module(library(lists)).

configuration(Root,repair,Config) :- !,
 absolute_file_name(path(node),Node,[access(execute)]),
 directory_file_path(Root,'sum.mjs',Source),setup_call_cleanup(open(Source,write,S),write(S,'export const sum = (a,b) => a-b;'),close(S)),
 directory_file_path(Root,'sum.test.mjs',Test),setup_call_cleanup(open(Test,write,T),
 write(T,'import test from "node:test"; import assert from "node:assert/strict"; import {sum} from "./sum.mjs"; test("sum",()=>assert.equal(sum(2,3),5));'),close(T)),
 repair_tools(Root,Node,["sum.mjs"],["sum.test.mjs"],_{},Tools,Caps),
 Config=_{profile:"bounded-repair",tools:Tools,capabilities:Caps,
 budget:_{max_model_calls:8,max_tool_calls:12,max_iterations:12,time_limit:60.0},
 runtime_options:[provider(provider(openai_compatible,[])),provider_name(openai_compatible),prompt_compile_mode(all_tools),
 model_handler(agentprolog_generic_fixture:model(repair,Root))],hooks:_{}}.
configuration(Root,Scenario,Config) :- memberchk(Scenario,[runner,runner_slow]),!,
 absolute_file_name(path(node),Node,[access(execute)]),directory_file_path(Root,'runner.test.mjs',Path),
 (Scenario==runner_slow -> Code="import {writeFileSync} from 'node:fs'; writeFileSync('runner-started','started');setTimeout(()=>writeFileSync('runner-late','bad'),2000);"
 ; Code="import test from 'node:test'; import {writeFileSync} from 'node:fs';test('runner',()=>{writeFileSync('runner-started','started');});"),
 setup_call_cleanup(open(Path,write,F),format(F,'~s',[Code]),close(F)),
 node_test_tool(Root,Node,["runner.test.mjs"],_{},Tool),
 Config=_{profile:"approved-test-runner",tools:[Tool],capabilities:[tool(workspace_test),context(peek)],
 runtime_options:[provider(provider(openai_compatible,[])),provider_name(openai_compatible),model_handler(agentprolog_generic_fixture:model(runner,Root))],hooks:_{}}.
configuration(Root,learn,Config) :- !,
 Spec=spec{id:demo,discovery:[example{id:train,input:"  HELLO  ",expected:"hello",origin:training}],
 evaluation:[example{id:test,input:" WORLD ",expected:"world",origin:heldout}]},
 learning_experiment_tool(Root,Spec,Tool),Config=_{profile:"learn-experiment",tools:[Tool],capabilities:[tool(learn_demo)],hooks:_{}}.
configuration(Root,context_experiment,Config) :- !,
 forall(member(N,[a,b]),(directory_file_path(Root,N,P),setup_call_cleanup(open(P,write,F),write(F,'12345678'),close(F)))),
 Spec=spec{id:demo,token_budget:3,files:[file{id:a,path:"a",mandatory:false,utility:1},file{id:b,path:"b",mandatory:false,utility:10}]},
 context_experiment_tool(Root,Spec,Tool),Config=_{profile:"context-experiment",tools:[Tool],capabilities:[tool(context_experiment_demo)],hooks:_{}}.
configuration(Root,rsi,Config) :- !,
    B=expert_contract{id:baseline,version:1,accepts:[ask/1],produces:value,specialties:[fixture],requires:[],observations:[],effects:[],fallback:none,child_policy:never,limits:expert_limits{},handler:agentprolog_generic_fixture:rsi_baseline},
    put_dict(_{id:candidate,handler:agentprolog_generic_fixture:rsi_candidate},B,C),
    Spec=spec{id:echo,version:1,baseline:B,candidate:C,cases:[case{id:held,input:"EXPECTED",expected:"EXPECTED",origin:synthetic_fixture}]},
    rsi_evaluation_tool(Root,Spec,Tool),Config=_{profile:"rsi-evaluation",tools:[Tool],capabilities:[tool(rsi_echo)],hooks:_{}}.
rsi_baseline(ask(_),_,succeeded("WRONG",[])).
rsi_candidate(ask(Q),_,succeeded(Q,[])).
configuration(Root, army, Config) :- !,
    Config=_{profile:"army-fixture",tools:[],capabilities:[model(openai_compatible)],
      runtime_options:[subagents(true),provider(provider(openai_compatible,[])),provider_name(openai_compatible),
        planner_handler(agentprolog_generic_fixture:army_planner(Root))],
      agents:_{reader:_{mode:rlm},reviewer:_{mode:rlm},
        fast:_{mode:rlm,runtime_options:[planner_handler(agentprolog_generic_fixture:fast_army_planner)]}},hooks:_{}}.
configuration(Root, memory_fast, Config) :- !,
    configuration(Root,memory,Base),put_dict(budget,Base,_{time_limit:0.5},Config).
configuration(Root, memory, Config) :- !,
    file_directory_name(Root,Parent),directory_file_path(Parent,notes,State),make_directory_path(State),
    memory_tools(Root,State,Writes),memory_read_tools(Root,State,Reads),append(Writes,Reads,Tools),Config=_{profile:"memory-fixture",tools:Tools,
      capabilities:[tool(memory_remember),tool(memory_recall)],hooks:_{}}.
configuration(Root, workflow, Config) :- !,
    file_directory_name(Root,Parent),directory_file_path(Parent,journal,State),
    make_directory_path(State),directory_file_path(State,'task-workflow.pl',Path),
    (exists_file(Path) -> true ; workflow_initialize(Root,r1,State),
     agentprolog_workflow:preflight(Root,State,add,_{id:"first",title:"READY_FIXTURE",dependencies:[]},N,_),
     agentprolog_workflow:execute(State,add,N,_)),
    workflow_tools(Root,State,Tools),
    Config=_{profile:"workflow-fixture",tools:Tools,
      capabilities:[tool(workflow_next),tool(workflow_handoff)],hooks:_{}}.
configuration(_, expert, Config) :- !,
    Contract=expert_contract{id:echo,version:1,accepts:[ask/1],produces:value,
      specialties:[fixture],requires:[],observations:[],effects:[],fallback:none,
      child_policy:never,limits:expert_limits{},handler:agentprolog_generic_fixture:expert_echo},
    expert_question_tool(Contract,Tool),
    Config=_{profile:"symbolic-fixture",tools:[Tool],capabilities:[tool(expert_echo)],hooks:_{}}.
configuration(Root,sleep_loopback(Endpoint),Config) :- !,
    configuration(Root,loopback(Endpoint),Base),
    put_dict(capabilities,Base,[model(openai_compatible),context(peek)],Config).
configuration(Root, memory_loopback(Endpoint), Config) :- !,
    configuration(Root,memory,Memory),configuration(Root,loopback(Endpoint),Provider),
    put_dict(_{tools:Memory.tools,capabilities:Memory.capabilities},Provider,Config).
configuration(Root, image_loopback(Endpoint), Config) :- !,
 configuration(Root,loopback(Endpoint),Base),put_dict(runtime_options,Base,[image_inputs(true)|Base.runtime_options],Config).
configuration(Root, stream_loopback(Endpoint), Config) :- !,
 configuration(Root,loopback(Endpoint),Base),put_dict(runtime_options,Base,[stream_responses(true)|Base.runtime_options],Config).
configuration(_, loopback(Endpoint), Config) :- !,
    Config=_{profile:"loopback-history",tools:[],capabilities:[],
      runtime_options:[history_depth(2),system_prompt("Trusted loopback system"),
        provider(provider(openai_compatible,[endpoint(Endpoint),credential(none),model('test/model')])),
        provider_name(openai_compatible)],hooks:_{}}.
configuration(Root, history, Config) :- !,
    configuration(Root, hello, Base),
    select(model_handler(_),Base.runtime_options,model_handler(agentprolog_generic_fixture:history_model),Options),
    put_dict(runtime_options,Base,[history_depth(2)|Options],Config).
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
    (Scenario == slow -> directory_file_path(Root,'model-started',StartMarker), setup_call_cleanup(open(StartMarker,write,Start),write(Start,started),close(Start)) ; true),
    step(Scenario,N,Messages,Text,Calls),
    (Scenario == slow -> directory_file_path(Root,'model-completed',Marker), setup_call_cleanup(open(Marker,write,S),write(S,completed),close(S)) ; true),
    Response=model_response{provider:fake,requested_model:fake,selected_model:fake,
      response_id:"fixture",assistant:message{role:assistant,content:Text,tool_calls:Calls,reasoning:"",reasoning_details:[]},
      text:Text,tool_calls:Calls,reasoning:"",reasoning_details:[],finish_reason:stop,
      usage:usage{present:true,prompt_tokens:2,completion_tokens:1,total_tokens:3,cost:0.0},
      metadata:provider_metadata{provider:fake,http_status:200,response_received:true}}.
step(repair,0,_,"",[C]) :- native_call("source","workspace_read",_{path:"sum.mjs"},C).
step(repair,1,_,"",[C]) :- native_call("peeksource","context_peek",_{context:"result_source",selector:_{type:"item",index:0}},C).
step(repair,2,Messages,"",[C]) :- retained(Messages,"a-b"),native_call("before","workspace_test",_{},C).
step(repair,3,_,"",[C]) :- native_call("peekbefore","context_peek",_{context:"result_before",selector:_{type:"item",index:0}},C).
step(repair,4,Messages,"",[C]) :- retained(Messages,"exit_code"),
 crypto_data_hash("export const sum = (a,b) => a-b;",H,[algorithm(sha256),encoding(utf8)]),atom_string(H,Hash),
 native_call("repair","workspace_patch",_{path:"sum.mjs",expected_sha256:Hash,edits:[_{old_text:"a-b",new_text:"a+b"}]},C).
step(repair,5,_,"",[C]) :- native_call("after","workspace_test",_{},C).
step(repair,6,_,"",[C]) :- native_call("peekafter","context_peek",_{context:"result_after",selector:_{type:"item",index:0}},C).
step(repair,7,Messages,"Scripted repair completed; inspect before and after test receipts.",[]) :- retained(Messages,"exit_code").
step(runner,0,_,"",[Call]) :- native_call("tests1","workspace_test",_{},Call).
step(runner,1,_,"",[Call]) :- native_call("peektests","context_peek",_{context:"result_tests1",selector:_{type:"item",index:0}},Call).
step(runner,2,Messages,"Observed test-runner receipt",[]) :- member(M,Messages),sub_string(M.content,_,_,_,"exit_code").
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

history_model(Request, Outcome) :-
    findall(T,(member(M,Request.messages),M.role==user,T=M.content),Users),last(Users,Current),
    (Current=="What was the marker?"
    -> memberchk("FIRST_TURN_MARKER",Users),
       member(A,Request.messages),A.role==assistant,A.content=="Synthetic hello"
    ; true), model(hello,unused,Request,Outcome).

expert_echo(ask(Question),_,succeeded(Question,[symbolic_fixture])).

army_planner(Root,Request,ok(Output)) :-
    term_string(Request,S),
    (sub_string(S,_,_,_,"SLOW_CHILD")
     -> directory_file_path(Root,'child-started',Path),setup_call_cleanup(open(Path,write,F),write(F,started),close(F)),
        sleep(2),directory_file_path(Root,'child-finished',Done),setup_call_cleanup(open(Done,write,D),write(D,done),close(D))
     ; true),
    Output=planner_output{plan:plan([final(literal("CANONICAL_CHILD_RESULT"))]),
      usage:_{prompt_tokens:1,completion_tokens:1,total_tokens:2,cost:0.0}}.

fast_army_planner(_,ok(planner_output{plan:plan([final(literal("FAST_CHILD"))]),usage:_{prompt_tokens:1,completion_tokens:1,total_tokens:2,cost:0.0}})).
