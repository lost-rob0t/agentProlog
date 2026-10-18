% Verified by test/direct_tool_test.pl and the real sidecar integration suite.
session_tool(project_read, 'rlm_tool:register_project_read_tool/4').
tool_root(project_read, 'session.start payload cwd or sidecar process cwd').
direct_capability(tool(project_read)).
skill_catalog_api('rlm_skill:skill_catalog_load/3').
