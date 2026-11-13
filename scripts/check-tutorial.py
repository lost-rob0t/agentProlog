#!/usr/bin/env python3
"""Load the tutorial's complete Prolog modules offline, never a model turn.

The repository tutorial is trusted test input, not a sandbox for arbitrary Org.
Only its two explicitly named configuration modules are extracted and consulted.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-lib', required=True, type=Path)
    parser.add_argument('--swipl', default='swipl')
    parser.add_argument('--node', default=shutil.which('node'))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    runtime = args.runtime_lib.resolve(strict=True)
    if not args.node:
        parser.error('a Node executable is required for the fixed syntax-check tool descriptor')
    tutorial = (repo / 'docs/wiki/tutorial-todo-app.org').read_text()
    blocks = re.findall(r'^#\+begin_src prolog[^\n]*\n(.*?)^#\+end_src\s*$',
                        tutorial, flags=re.I | re.M | re.S)
    modules = {}
    for name in ('todo_tutorial_operator', 'todo_tutorial_project'):
        matches = [b for b in blocks if re.search(r':-\s*module\(\s*' + name + r'\s*,', b)]
        if len(matches) != 1:
            raise SystemExit(f'Tutorial must contain exactly one complete {name} module')
        modules[name] = matches[0]
    with tempfile.TemporaryDirectory(prefix='agentprolog-tutorial-check-') as temporary:
        root = Path(temporary)
        workspace = root / 'workspace'
        (workspace / '.agentprolog').mkdir(parents=True)
        operator = root / 'operator.pl'
        operator.write_text(modules['todo_tutorial_operator'])
        (workspace / '.agentprolog/config.pl').write_text(modules['todo_tutorial_project'])
        env = os.environ.copy()
        env.update(AGENTPROLOG_TUTORIAL_REPO=str(repo),
                   AGENTPROLOG_TUTORIAL_WORKSPACE=str(workspace),
                   AGENTPROLOG_TUTORIAL_NODE=str(Path(args.node).resolve()))
        # Provider constructors retain references; validation needs no credentials.
        for key in ('OPENROUTER_API_KEY', 'ZAI_API_KEY'):
            env.pop(key, None)
        goal = (f'use_module({quote(repo / "prolog/agentprolog_config.pl")}),'
                f'load_configuration({quote(workspace)},[config_file({quote(operator)})],C),'
                'get_dict(agent,C,builder),get_dict(profile,C,todo_tutorial),'
                'get_dict(budget,C,B),get_dict(max_model_calls,B,16),'
                'get_dict(max_cost_usd,B,Cost),Cost=:=0.04,'
                'get_dict(capabilities,C,Caps),memberchk(tool(workspace_check),Caps),'
                '\\+memberchk(tool(workspace_modify),Caps),'
                "get_dict(selected_skills,C,['build-todo']),halt")
        subprocess.run([args.swipl, '-q', '-p', f'library={runtime}', '-p',
                        f'library={repo / "prolog"}', '-g', goal],
                       env=env, check=True, timeout=30)
    print('Tutorial operator/project modules loaded through the real configuration API; no model calls.')


if __name__ == '__main__':
    main()
