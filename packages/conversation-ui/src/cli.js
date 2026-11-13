#!/usr/bin/env node
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';
import { realpathSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';
import { Client } from './client.js';
import { render, safe } from './render.js';
export const HELP = `AgentProlog canonical conversation UI
Usage: agentProlog [--project DIR] [--state DIR]
                  [--plugin FILE ...] [--trust-project]
                  [--allow-tool NAME ...] [--allow-context OP ...] [--allow-model NAME ...]
       agentProlog --sidecar EXECUTABLE [--sidecar-arg ARG ...]
       agentProlog --help

/create                   initialize/select the configured canonical session
/select                   refresh the configured canonical session
/resume                   explicitly resume the previous objective as a new run
/profile                  show runtime-owned profile and capabilities
/inspect                  show canonical session, tools, evidence and usage
/reconnect                restart connection and obtain a canonical checkpoint
/cancel                   request canonical session cancellation
/approve ID DECISION      choose an exact runtime-offered approval decision
/answer ID TEXT           answer a pending runtime question
/help                     show this help
/quit                     close the sidecar and exit

Plugins and --trust-project explicitly authorize executing that local Prolog code.
Project configuration is never silently trusted. Tool grants are explicit.
Type an objective or follow-up to submit a session.turn command.
The configured sidecar owns the session and profile. Choose a different operator-
configured sidecar/state directory to switch workspaces. No tools, provider calls,
shell commands, or collection are executed by this UI.
`;
export async function main(argv = process.argv.slice(2)) {
  if (argv.includes('--help')) { process.stdout.write(HELP); return; }
  let command = process.env.AGENTPROLOG_SIDECAR;
  let external = Boolean(command), project = process.cwd(), state;
  const args = [], hostFlags = [];
  for (let i = 0; i < argv.length; i++) {
    const option = argv[i];
    if (option === '--trust-project') { hostFlags.push(option); continue; }
    if (!argv[i + 1]) throw new Error(`Incomplete argument: ${option}`);
    const value = argv[++i];
    if (option === '--sidecar') { command = value; external = true; }
    else if (option === '--sidecar-arg') args.push(value);
    else if (option === '--project') project = value;
    else if (option === '--state') state = resolve(value);
    else if (option === '--plugin') hostFlags.push(option, realpathSync(value));
    else if (option === '--allow-tool' || option === '--allow-context' || option === '--allow-model') hostFlags.push(option, value);
    else throw new Error(`Unknown argument: ${option}`);
  }
  if (external) {
    if (hostFlags.length || state || project !== process.cwd()) {
      throw new Error('Use --sidecar-arg for external adapters; project/config flags require the bundled generic host.');
    }
  } else {
    command = process.env.AGENTPROLOG_SESSION;
    if (!command) throw new Error('Run the packaged Nix application, set AGENTPROLOG_SESSION to the generic host launcher, or configure --sidecar.');
    project = realpathSync(project);
    const projectKey = createHash('sha256').update(project).digest('hex');
    state ??= join(process.env.XDG_STATE_HOME ?? join(homedir(), '.local/state'), 'agentprolog', projectKey);
    args.push(state, project, ...hostFlags);
  }
  const client = new Client({ command, args });
  const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: process.stdin.isTTY });
  const show = () => {
    if (process.stdout.isTTY) process.stdout.write('\x1b[2J\x1b[H');
    process.stdout.write('\n' + render(client.view, client.connected) + '\n'); rl.prompt(true);
  };
  let renderTimer;
  client.on('view', () => { clearTimeout(renderTimer); renderTimer = setTimeout(show, 40); });
  client.on('fault', error => { process.stderr.write(`\n${safe(error.code ?? 'error')}: ${safe(error.message)}\n`); show(); });
  client.on('diagnostic', text => process.stderr.write(safe(text)));
  rl.setPrompt('agentprolog> ');
  let closing = false;
  const close = async () => { if (closing) return; closing = true; clearTimeout(renderTimer); rl.close(); process.stdin.pause(); await client.close(); };
  rl.on('close', close);
  process.once('SIGINT', close); process.once('SIGTERM', close);
  rl.on('line', async line => {
    const [op, ...words] = line.trim().split(/\s+/);
    try {
      if (op === '/quit') return await close();
      if (op === '/help') process.stdout.write(HELP);
      else if (op === '/inspect') show();
      else if (op === '/profile') process.stdout.write(safe(JSON.stringify(client.descriptor, null, 2)) + '\n');
      else if (op === '/create') await client.command('session.create');
      else if (op === '/select') await client.command('session.select');
      else if (op === '/resume') await client.command('session.resume');
      else if (op === '/reconnect') await client.connect();
      else if (op === '/cancel') await client.command('session.cancel');
      else if (op === '/approve') await client.command('approval.decide', { approval_id: words[0], decision: words[1] });
      else if (op === '/answer') await client.command('question.answer', { question_id: words[0], answer: words.slice(1).join(' ') });
      else if (op?.startsWith('/')) throw new Error('Unknown command. Use /help.');
      else if (op) await client.command('session.turn', { objective: line });
    } catch (error) { process.stderr.write(`${safe(error.code ?? 'error')}: ${safe(error.message)}\n`); }
    rl.prompt();
  });
  process.stdout.write(HELP);
  try { await client.connect(); rl.prompt(); }
  catch (error) { await close(); throw error; }
}
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main().catch(error => { process.stderr.write(safe(error.message) + '\n'); process.exitCode = 1; });
}
