:- module(agentprolog_example_named_agents,[agentprolog_config/1]).

:- use_module('./support').

agentprolog_config(_{
    profile:workspace_team, tools:Tools, capabilities:Capabilities,
    agents:_{
        builder:_{
            runtime_options:[system_prompt("Implement the requested change using the confined workspace tools. Inspect opaque results with context_peek. Run workspace_check on changed JavaScript and report its actual exit code. Do not claim behavior tests from a syntax check.")],
            budget:_{max_model_calls:6,max_tool_calls:12}},
        reviewer:_{
            capabilities:[tool(workspace_read),context(peek)],
            runtime_options:[system_prompt("Review existing workspace files. Do not modify them. Separate observed defects, assumptions and untested behavior.")],
            budget:_{max_model_calls:2,max_tool_calls:4}}
    }, default_agent:reviewer
}) :- coding_tools(Tools), coding_capabilities(Capabilities).
