:- module(agentprolog_example_bounded_budget,[agentprolog_config/1]).

agentprolog_config(_{profile:bounded,
    budget:_{max_model_calls:3,max_tool_calls:4,max_iterations:6,
        max_total_tokens:8192,max_output_bytes:32768,max_recursion_depth:0,
        max_concurrent_subcalls:1,max_context_ops:4,max_native_calls_per_batch:2,
        time_limit:30.0,max_cost_usd:0.05},
    agents:_{brief:_{budget:_{max_model_calls:1,max_tool_calls:0,max_iterations:2}}}}).
