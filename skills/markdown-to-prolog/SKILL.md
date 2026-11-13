---
name: markdown-to-prolog
description: Import an existing Markdown Agent Skill into inert native Prolog prompt-unit data while preserving its source provenance.
---

Use `agentprolog-import-skill SKILL_ROOT OUTPUT.pl`. The source root must contain
standard `SKILL.md` packages. The converter uses Prolog-RLM's loader and emits
`agentprolog_skills([prompt_unit{...}])`, the existing compiler IR serialized as
data. It never executes Markdown or consults the output. Existing output files
are not overwritten.

Add the resulting file to `skill_files` in an explicitly trusted
`agentprolog_config/1` configuration. Select a skill with `selected_skills` or let
the canonical prompt compiler route it. Imports do not grant tools, capability,
authority or mandatory status. Package resources are not copied; keep their
original package available if you need those separate resources. Inspect the
native result and source provenance before activating it.
