:- module(agentprolog_patch,[patch_tool/2,preflight/4,execute/3]).
/** Ordered, exact-match edits for one bounded file. Existing workspace authority,
    stale-content checks and atomic replacement remain the execution boundary. */
:- use_module('./agentprolog_workspace_tools',[]).
patch_tool(Project,tool(Schema,tool_handler(agentprolog_patch:preflight(Root),agentprolog_patch:execute(Root)))) :-
 absolute_file_name(Project,Root,[file_type(directory),access(write),file_errors(error)]),
 agentprolog_workspace_tools:reject_link_chain(Root),
 Schema=tool_schema{name:workspace_patch,description:"Apply 1-16 ordered unique literal replacements to one file after write approval. Expected source hash required; no fuzzy matching or multi-file transaction.",
 capability:tool(workspace_patch),effect:write,
 arguments:_{type:object,required:[path,expected_sha256,edits],additional_properties:false,
 properties:_{path:_{type:string},expected_sha256:_{type:string},edits:_{type:array,items:_{type:object,required:[old_text,new_text],additional_properties:false,
 properties:_{old_text:_{type:string},new_text:_{type:string}}}}}},
 result:_{type:object,required:[path,sha256,bytes,edit_count],additional_properties:false,
 properties:_{path:_{type:string},sha256:_{type:string},bytes:_{type:integer},edit_count:_{type:integer}}},
 limits:_{time_limit:5.0,max_output_bytes:400000}}.
preflight(Root,Args,N,Details) :-
 valid_edits(Args.edits),
 agentprolog_workspace_tools:preflight(Root,read,_{path:Args.path},Read,_),
 (Read.before==Args.expected_sha256 -> true ; throw(error(workspace_error(stale_content),_))),
 foldl(apply_edit,Args.edits,Read.content,Final),
 agentprolog_workspace_tools:preflight(Root,write,_{path:Args.path,content:Final,expected_sha256:Args.expected_sha256},Write,Base),
 length(Args.edits,Count),N=_{write:Write,edit_count:Count},
 agentprolog_workspace_tools:hash_text(Final,After),
 put_dict(_{operation:patch,edit_count:Count,edits:Args.edits,result_sha256:After},Base,Details).
execute(Root,N,Result) :-
 agentprolog_workspace_tools:execute(Root,write,N.write,Written),
 put_dict(edit_count,Written,N.edit_count,Result).
valid_edits(Edits) :-
 (is_list(Edits),length(Edits,N),between(1,16,N),maplist(valid_edit,Edits)
 -> true ; throw(error(invalid_patch_edits,_))).
valid_edit(E) :- is_dict(E),dict_pairs(E,_,[new_text-New,old_text-Old]),
 string(Old),string(New),string_length(Old,A),A>0,A=<4096,string_length(New,B),B=<4096.
apply_edit(E,Before,After) :-
 findall(P,sub_string(Before,P,_,_,E.old_text),Matches),
 (Matches=[Start] -> true ; throw(error(workspace_error(non_unique_match),_))),
 string_length(E.old_text,L),End is Start+L,
 sub_string(Before,0,Start,_,Prefix),sub_string(Before,End,_,0,Suffix),
 atomics_to_string([Prefix,E.new_text,Suffix],After),
 agentprolog_workspace_tools:content_bytes(After,Bytes),
 (Bytes=<65536 -> true ; throw(error(workspace_error(file_too_large),_))).
