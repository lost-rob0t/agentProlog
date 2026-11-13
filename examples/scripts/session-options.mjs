import { accessSync, constants, realpathSync, statSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { Client } from '../../packages/conversation-ui/src/client.js';

export const connectionHelp = `  --executable FILE       Explicit native session launcher (or SWI executable)
  --executable-arg ARG    Repeatable prefix argument; never evaluated by a shell
  --project DIR          Existing project directory
  --state DIR            Explicit durable session directory (may be new)
  --config FILE          Trusted operator Prolog configuration
  --request-timeout-ms N  Per-request/snapshot timeout, 1..60000 (default 5000)`;

export function options(argv, task = false) {
  if (argv.includes('--help')) return null;
  const result = { args: [], timeoutMs: 5000, waitMs: 30000 };
  const seen = new Set();
  const fields = new Map([
    ['--executable', 'command'], ['--project', 'project'], ['--state', 'state'],
    ['--config', 'config'], ['--request-timeout-ms', 'timeoutMs'],
    ...(task ? [['--objective', 'objective'], ['--wait-ms', 'waitMs']] : []),
  ]);
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag !== '--executable-arg' && !fields.has(flag)) throw new Error(`Unknown option: ${flag}`);
    if (i + 1 >= argv.length || argv[i + 1] === '') throw new Error(`Missing value: ${flag}`);
    const value = argv[++i];
    if (flag === '--executable-arg') { result.args.push(value); continue; }
    if (seen.has(flag)) throw new Error(`Duplicate option: ${flag}`);
    seen.add(flag); result[fields.get(flag)] = value;
  }
  for (const name of ['command', 'project', 'state', 'config', ...(task ? ['objective'] : [])]) {
    if (!result[name]?.trim()) throw new Error(`Required input: ${name}`);
  }
  for (const [name, maximum] of [['timeoutMs', 60000], ['waitMs', 300000]]) {
    if (!/^\d+$/.test(String(result[name])) || Number(result[name]) < 1 || Number(result[name]) > maximum) {
      throw new Error(`${name} must be an integer in 1..${maximum}`);
    }
    result[name] = Number(result[name]);
  }
  if (task && [...result.objective].length > 16000) throw new Error('objective exceeds 16000 characters');
  result.command = realpathSync(result.command);
  accessSync(result.command, constants.X_OK);
  if (!statSync(result.command).isFile()) throw new Error('executable must be a file');
  result.project = realpathSync(result.project);
  if (!statSync(result.project).isDirectory()) throw new Error('project must be a directory');
  result.config = realpathSync(result.config);
  if (!statSync(result.config).isFile()) throw new Error('config must be a file');
  result.state = resolve(result.state);
  if (existsSync(result.state) && !statSync(result.state).isDirectory()) throw new Error('state must be a directory');
  return result;
}

export function session(input) {
  return new Client({ command: input.command,
    args: [...input.args, input.state, input.project, '--config', input.config], timeoutMs: input.timeoutMs });
}

export function checkpoint(client) {
  return { session_id: client.view.sessionId, at_seq: client.view.cursor,
    state: structuredClone(client.view.state) };
}

export function report(value, code = 0) {
  process.stdout.write(JSON.stringify(value) + '\n'); process.exitCode = code;
}

export function parse(argv, task = false) {
  try { return options(argv, task); }
  catch (error) { report({ status: 'invalid_arguments', message: error.message }, 2); return false; }
}
