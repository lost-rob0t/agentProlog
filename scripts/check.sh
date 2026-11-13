#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
runtime="${1:-${PROLOG_RLM_SOURCE:-}}"
test -n "$runtime" || { echo 'Usage: bash scripts/check.sh /path/to/pinned/prolog-rlm' >&2; exit 2; }
export PROLOG_RLM_SOURCE="$runtime"
expected=$(sed -n 's/.*github:lost-rob0t\/prolog-rlm\/\([0-9a-f]\{40\}\).*/\1/p' flake.nix)
test "$(git -C "$runtime" rev-parse HEAD)" = "$expected"
python3 -B scripts/check-docs.py
python3 -B -m unittest discover -s test -p 'test_documentation.py'
python3 -B scripts/check-tutorial.py --runtime-lib "$runtime/prolog"
swipl -q -p "library=$runtime/prolog" \
  -s test/agentprolog_config_test.pl \
  -s test/agentprolog_agents_test.pl \
  -s test/agentprolog_skills_test.pl \
  -s test/agentprolog_check_tool_test.pl \
  -s test/documented_configs_test.pl \
  -s test/agentprolog_session_test.pl \
  -s test/agentprolog_workspace_tools_test.pl -g 'run_tests,halt'
for package in deepseek-harness zara-profile conversation-ui; do
  (cd "packages/$package"; node --test test/*.test.js)
done
(cd packages/conversation-ui; node --test test/generic.runtime.js test/native.runtime.js)
git diff --check
