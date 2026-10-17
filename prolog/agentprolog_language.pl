:- module(agentprolog_language,[language_experts_load/2,inspect_source/2]).
:- use_module(library(rlm_expert)).
:- use_module(library(rlm_source_structure)).
:- use_module(library(error)).

language_experts_load(R,Outcome) :-
    register_all([source_inspect_expert,source_edit_expert,compiler_diagnostics_expert],R,Outcome).
register_all([],_,ok(registered)).
register_all([Name|Names],R,Outcome) :-
    contract(Name,Goal,Description,Fields,Handler),
    findall(Key,member(Key-_,Fields),Required),dict_pairs(Properties,json,Fields),
    C=expert_contract{id:Name,version:1,goal:Goal,priority:100,description:Description,
        arguments:_{type:object,required:Required,additional_properties:false,properties:Properties},
        result:_{type:any},limits:_{time_limit:5.0,max_output_bytes:1048576,inferences:8000000}},
    expert_register(R,C,Handler,One),
    (One=ok(_) -> register_all(Names,R,Outcome);Outcome=One).

contract(source_inspect_expert,source_structure,
    "Inspect supplied Common Lisp or Prolog source without evaluation; character spans, definitions and unresolved references",
    [language-_{type:string},content-_{type:string}],agentprolog_language:inspect_source).
contract(source_edit_expert,structural_edit,
    "Replace exactly one selected definition/clause, preserve its identity, validate resulting source, and propose a SHA-bound project_write",
    [language-_{type:string},content-_{type:string},path-_{type:string},
     start-_{type:integer,minimum:0},replacement-_{type:string}],agentprolog_language:edit_source).
contract(compiler_diagnostics_expert,compiler_diagnostics,
    "Classify supplied SWI-Prolog/SBCL output and exit status; retain raw output, never certify source freshness",
    [language-_{type:string},output-_{type:string},exit_code-_{type:integer,minimum:0,maximum:255}],
    agentprolog_language:compiler_diagnostics).

language("prolog",prolog) :- !.
language("common_lisp",common_lisp) :- !.
language(Other,_) :- domain_error(source_language,Other).
inspect_source(Args,Analysis) :-
    language(Args.language,L),source_structure(L,Args.content,Outcome),
    (Outcome=ok(Analysis) -> true ; throw(error(source_analysis(Outcome),_))).

edit_source(Args,Proposal) :-
    inspect_source(Args,Before),
    ( Before.status \== complete
    -> Proposal=json{status:blocked,reason:incomplete_source,diagnostics:Before.diagnostics}
    ; findall(D,(member(D,Before.definitions),D.start=:=Args.start),Matches),
      (Matches=[Definition]
      -> replacement_proposal(Args,Before,Definition,Proposal)
      ; Proposal=json{status:blocked,reason:definition_span_not_unique}) ).

replacement_proposal(Args,Before,D,Proposal) :-
    language(Args.language,L),source_structure(L,Args.replacement,Parsed),
    ( Parsed=ok(R),R.status==complete,R.definitions=[Replacement],R.declarations=[],
      same_identity(D,Replacement),
      % Ensure replacement is one definition, not a definition plus a call.
      sub_string(Args.replacement,0,Replacement.start,_,Prefix),
      sub_string(Args.replacement,Replacement.end,_,0,Suffix),
      normalize_space(string(""),Prefix),normalize_space(string(""),Suffix)
    -> sub_string(Args.content,0,D.start,_,Left),
       sub_string(Args.content,D.end,_,0,Right),
       atomics_to_string([Left,Args.replacement,Right],Changed),
       source_structure(L,Changed,Validated),
       ( Validated=ok(New),New.status==complete,
         maplist(definition_identity,Before.definitions,IDs),
         maplist(definition_identity,New.definitions,IDs)
       -> Proposal=json{status:proposed,tool:project_write,
               arguments:json{path:Args.path,expected_sha256:Before.sha256,content:Changed},
               selected:D,validation:structural_only}
       ; Proposal=json{status:blocked,reason:changed_definition_identity_or_invalid_source} )
    ; Proposal=json{status:blocked,reason:replacement_must_be_one_compatible_definition} ).

same_identity(A,B) :- A.name==B.name,A.kind==B.kind,A.arity==B.arity.
definition_identity(D,id(D.scope,D.name,D.kind,D.arity)).

compiler_diagnostics(Args,Result) :-
    language(Args.language,_),string_length(Args.output,N),
    (N =< 65536 -> true ; resource_error(diagnostic_output)),
    split_string(Args.output,"\n","\r",Lines),
    findall(D,(nth1(Index,Lines,Line),diagnostic_line(Line,Severity),
               diagnostic_location(Line,File,Row,Column),
               D=diagnostic{severity:Severity,output_line:Index,raw:Line,
                            file:File,line:Row,column:Column}),Diagnostics),
    (Args.exit_code=:=0,\+ (member(D,Diagnostics),D.severity==error)
    -> Status=passed ; Status=failed),
    Result=json{status:Status,exit_code:Args.exit_code,diagnostics:Diagnostics,
        raw_output:Args.output,evidence_scope:supplied_compiler_output}.

diagnostic_line(Line,error) :- string_lower(Line,L),
    (sub_string(L,_,_,_,"error:");sub_string(L,_,_,_,"unhandled ");sub_string(L,_,_,_,"fatal error")),!.
diagnostic_line(Line,warning) :- string_lower(Line,L),sub_string(L,_,_,_,"warning:"),!.
diagnostic_location(Line,File,Row,Column) :-
    split_string(Line,":","",[_Severity,Path,R,C|_]),
    catch(number_string(Row,R),_,fail),integer(Row),
    catch(number_string(Column,C),_,fail),integer(Column),!,normalize_space(string(File),Path).
diagnostic_location(_,unknown,unknown,unknown).
