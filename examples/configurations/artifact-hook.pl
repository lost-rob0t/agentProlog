:- module(agentprolog_example_artifact_hook,[agentprolog_config/1,review_artifact/2]).

agentprolog_config(_{profile:artifact_review,
    hooks:_{validate_artifact:agentprolog_example_artifact_hook:review_artifact}}).

% Structural review only: not execution evidence, publication or deployment.
review_artifact(Result, approval(_{kind:"draft",text:Text,
    policy:"operator_review_required",published:false})) :-
    get_dict(value,Result,Text), string(Text), string_length(Text,Length),
    Length > 0, Length =< 8192.
