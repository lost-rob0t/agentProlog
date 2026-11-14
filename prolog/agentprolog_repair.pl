:- module(agentprolog_repair,[repair_tools/7,guard_preflight/5]).
/** Composition only: no scheduler, model client, approval bypass or automatic
    repair. Source manifest is the explicit read/patch allowlist. */
:- use_module('./agentprolog_workspace_tools',[]).
:- use_module('./agentprolog_discovery',[]).
:- use_module('./agentprolog_patch',[]).
:- use_module('./agentprolog_test_runner',[]).
repair_tools(Project,Node,Sources,Tests,Policy,Tools,Capabilities) :-
 agentprolog_discovery:discovery_tools(Project,Sources,Discovery),
 agentprolog_workspace_tools:workspace_tools(Project,Workspace),
 once((member(tool(ReadSchema,tool_handler(ReadPre,ReadRun)),Workspace),ReadSchema.name==workspace_read)),
 agentprolog_patch:patch_tool(Project,tool(PatchSchema,tool_handler(PatchPre,PatchRun))),
 (get_dict(evidence_files,Policy,Extra) -> true ; Extra=[]),
 append(Sources,Extra,AllEvidence),sort(AllEvidence,Evidence),
 put_dict(evidence_files,Policy,Evidence,RunnerPolicy),
 agentprolog_test_runner:node_test_tool(Project,Node,Tests,RunnerPolicy,Runner),
 append(Discovery,[tool(ReadSchema,tool_handler(agentprolog_repair:guard_preflight(Sources,ReadPre),ReadRun)),
 tool(PatchSchema,tool_handler(agentprolog_repair:guard_preflight(Sources,PatchPre),PatchRun)),Runner],Tools),
 Capabilities=[tool(workspace_list),tool(workspace_search),tool(workspace_read),tool(workspace_patch),tool(workspace_test),context(peek)].
guard_preflight(Paths,Pre,Args,N,D) :-
 (get_dict(path,Args,P),memberchk(P,Paths) -> call(Pre,Args,N,D)
 ; throw(error(repair_path_not_allowed,_))).
