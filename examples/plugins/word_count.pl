:- module(agentprolog_word_count, [agentprolog_config/1, count_words/2]).

% A reusable plugin supplies typed native tools, never an agent/model loop.
agentprolog_config(_{
    profile:word_count,
    tools:[tool(tool_schema{
        name:word_count,
        description:"Count whitespace-separated words in caller-supplied text",
        capability:tool(word_count), effect:read,
        arguments:_{type:object, properties:_{text:_{type:string}},
                    required:[text], additional_properties:false},
        result:_{type:object, properties:_{count:_{type:integer}},
                 required:[count], additional_properties:false},
        limits:_{time_limit:0.5, max_output_bytes:1024}},
        agentprolog_word_count:count_words)],
    capabilities:[tool(word_count),context(peek)]
}).

count_words(Args, _{count:Count}) :-
    split_string(Args.text, " \t\r\n", " \t\r\n", Words), length(Words, Count).
