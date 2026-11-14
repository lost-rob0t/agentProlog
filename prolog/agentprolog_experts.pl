:- module(agentprolog_experts,[expert_question_tool/2,ask_command/1,ask_request/3,ask_execute/5,invoke/3]).

/** Explicit provider-free expert questions through canonical tool authority.
    Contract and handler are trusted plugin data, never parsed from the question. */
:- use_module(library(rlm_expert)).
:- use_module(library(rlm_expert_tool)).
:- use_module(library(rlm_tool)).
:- use_module('./agentprolog_commands').


expert_question_tool(Contract,tool(Schema,agentprolog_experts:invoke(Contract))) :-
    with_projection(Contract,discover_schema(Schema)).

discover_schema(Schema,Tools,Name) :- tool_lookup(Tools,Name,ok(Schema)).

:- meta_predicate with_projection(+,2).
with_projection(Contract,Goal) :-
    setup_call_cleanup(expert_registry_create([],Experts),
      setup_call_cleanup(tool_registry_create(Tools),
        (expert_register(Experts,Contract,Registered),require_ok(Registered,_),
         atom_concat(expert_,Contract.id,Name),
         Projection=expert_tool{name:Name,goal:ask/1,description:"Ask the configured symbolic expert"},
         expert_tool_register(Tools,Experts,Contract.id,Projection,Projected),require_ok(Projected,_),
         call(Goal,Tools,Name)),tool_registry_destroy(Tools)),
      expert_registry_destroy(Experts)).
require_ok(ok(X),X) :- !.
require_ok(Error,_) :- throw(error(expert_configuration(Error),_)).

invoke(Contract,Args,Value) :-
    with_projection(Contract,invoke_projection(Contract.requires,Args,Value)).
invoke_projection(Requires,Args,Value,Tools,Name) :-
    % The outer canonical gate already checked this same fixed set. No request
    % can choose additional capabilities or a different goal/handler.
    tool_invoke_execute(Tools,[tool(Name)|Requires],Name,Args,[],Result),
    require_ok(Result.outcome,Envelope),
    % Expert evidence/goal terms are symbolic Prolog, not JSON values. Preserve
    % the bounded report as inert text for the canonical UI wire protocol.
    term_string(Envelope.value,Report,[quoted(true)]),
    Value=_{report:Report,expert_status:Envelope.value.status,model_calls:0}.

% Recognizer and parser deliberately share the same whitespace predicate.
% A malformed /ask is still an expert command, never a normal model objective.
ask_command(Objective) :-
    string_codes(Objective,Codes),phrase(command_prefix(Rest),Codes),
    (Rest=[] ; Rest=[C|_],command_space(C)).
command_prefix(Rest) --> blanks, "/ask", remainder(Rest).

ask_request(Objective,Name,Question) :-
    string_codes(Objective,Codes),phrase(question_command(Name,Question),Codes).
question_command(Name,Question) --> blanks, "/ask", blank, blanks,
    identifier(Id), blank, remainder(Rest),
    {Id\=[],Rest\=[],atom_codes(Name,Id),string_codes(Question,Rest),
     \+forall(member(C,Rest),command_space(C))}.
blanks --> blank, !, blanks.
blanks --> [].
blank --> [C], {command_space(C)}.
identifier([C|Cs]) --> [C], {code_type(C,alnum);memberchk(C,[0'_,0'-])}, !, identifier(Cs).
identifier([]) --> [].
remainder([C|Cs]) --> [C],!,remainder(Cs).
remainder([]) --> [].

ask_execute(Config,_,_,_,error(_{kind:budget_exceeded,phase:tool})) :-
    Config.budget.max_tool_calls < 1, !.
ask_execute(Config,Registry,Name,Question,Outcome) :-
    atom_concat(expert_,Name,ToolName),
    (member(tool(Schema,agentprolog_experts:invoke(_)),Config.tools),Schema.name==ToolName
    -> tool_invoke_execute(Registry,Config.capabilities,ToolName,_{arguments:[Question]},[],Result),
       (Result.outcome=ok(Envelope)
        -> Text=Envelope.value.report,Status=Envelope.value.expert_status,
           string_bytes(Text,Bytes,utf8),length(Bytes,Size),
           (Status\==succeeded
            -> Outcome=error(_{kind:expert_not_succeeded,phase:tool,expert_status:Status,report:Text})
            ; Size=<Config.budget.max_output_bytes
            -> Outcome=ok(_{value:Text,usage:_{model_calls:0,tool_calls:1,total_tokens:0}})
            ; Outcome=error(_{kind:budget_exceeded,phase:tool}))
        ; Outcome=Result.outcome)
    ; Outcome=error(_{kind:unknown_expert,phase:tool})).
