agentprolog_skills([
    prompt_unit{
        unit:skill('build-todo'),
        description:"Build a small functional CRUD todo application from an explicit acceptance contract.",
        content:"Read the requirements before writing. Implement real create, list, update and delete behavior, not a static mock. Use the available workspace tools to write the complete implementation. Keep it dependency-free unless requirements say otherwise. Handle invalid inputs and unknown IDs. Supply an HTML interface when required. Inspect tool results via context_peek. When workspace_check is available, run it, inspect its exit_code and output, repair syntax errors and check again before finishing. Avoid duplicate import/export identifiers and unescaped nested template literals in generated HTML/JavaScript. Final completion is subject to independent execution tests; do not fabricate test results.",
        triggers:[trigger(keyword("todo"),100)],
        priority:100
    }
]).
