:- module(agentprolog_example_project, [agentprolog_config/1]).

% Executed only after --trust-project. This project narrows the plugin setup.
agentprolog_config(_{
    profile:project_word_count,
    budget:_{max_model_calls:4, max_tool_calls:4, time_limit:30.0},
    runtime_options:[prompt_compile_mode(all_tools)]
}).
