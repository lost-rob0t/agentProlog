:- module(agentprolog_experts, [coding_experts_load/2]).
:- use_module(library(rlm_expert)).
:- use_module(library(crypto)).
:- use_module(library(error)).

% These leaf experts reason over supplied data. They neither read files nor
% run processes, and a proposal is not an approval or a completed edit.
coding_experts_load(Registry, Outcome) :-
    patch_contract(Patch),
    expert_register(Registry, Patch, agentprolog_experts:patch_proposal, First),
    ( First = ok(_)
    -> test_contract(Test),
       expert_register(Registry, Test, agentprolog_experts:test_result, Outcome)
    ; Outcome = First ).

patch_contract(expert_contract{id:write_expert,version:1,goal:edit,priority:100,
    description:"Derive a unique exact replacement and SHA-256 preimage; returns an unexecuted project_patch proposal",
    arguments:_{type:object,required:[path,content,old,new],additional_properties:false,
        properties:_{path:_{type:string},content:_{type:string},old:_{type:string},new:_{type:string}}},
    result:_{type:any},limits:_{time_limit:1.0,max_output_bytes:524288,inferences:1000000}}).

test_contract(expert_contract{id:test_result_expert,version:1,goal:test_result,priority:100,
    description:"Classify a supplied process exit code; does not verify a Frozen Spec or certify evidence freshness",
    arguments:_{type:object,required:[exit_code],additional_properties:false,
        properties:_{exit_code:_{type:integer,minimum:0,maximum:255}}},
    result:_{type:any},limits:_{time_limit:1.0,max_output_bytes:4096,inferences:10000}}).

patch_proposal(Args, Result) :-
    string_length(Args.content, Size),
    ( Size =< 65536, Args.old \== "" -> true
    ; domain_error(bounded_nonempty_edit, Args.path) ),
    findall(B, sub_string(Args.content,B,_,_,Args.old), Matches),
    ( Matches = [_]
    -> crypto_data_hash(Args.content, Hash, [algorithm(sha256),encoding(utf8)]),
       atom_string(Hash, SHA),
       Result = json{status:proposed, tool:project_patch,
           arguments:json{path:Args.path,expected_sha256:SHA,old:Args.old,new:Args.new}}
    ; Result = json{status:blocked,reason:ambiguous_or_missing_replacement} ).

test_result(Args, Result) :-
    ( Args.exit_code =:= 0
    -> Result = json{status:passed, exit_code:0, scope:process_exit_only}
    ; Result = json{status:failed, exit_code:Args.exit_code, next:inspect_failure_output} ).
