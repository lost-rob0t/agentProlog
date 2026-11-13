:- module(agentprolog_coding_pack,[agentprolog_config/1]).

% Executable local package configuration; --package explicitly trusts this code.
agentprolog_config(_{
    profile:coding,
    agents:_{
        builder:_{
            runtime_options:[system_prompt("You are the coding agent. Make actual file changes through the supplied confined tools. Treat tool results as opaque: inspect result aliases with context_peek. Never claim tests ran unless there is actual test evidence. Follow the user's acceptance contract.")],
            selected_skills:['build-todo']},
        reviewer:_{
            capabilities:[context(peek)],
            runtime_options:[system_prompt("Review supplied evidence. You have no file mutation capabilities. Clearly distinguish verified facts from assumptions.")]}
    },
    default_agent:builder,
    skill_files:['../skills/build-todo.pl']
}).
