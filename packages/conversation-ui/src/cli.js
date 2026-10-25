#!/usr/bin/env node
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';
import { realpathSync } from 'node:fs';
import { Client } from './client.js';
import { render, safe } from './render.js';
export const HELP = `AgentProlog canonical conversation UI
Usage: agentProlog --sidecar EXECUTABLE [--sidecar-arg ARG ...]
       agentProlog --help

/inspect                  show canonical session, tools, evidence and usage
/reconnect                restart connection and obtain a canonical checkpoint
/cancel                   request canonical session cancellation
/approve ID DECISION      choose an exact runtime-offered approval decision
/answer ID TEXT           answer a pending runtime question
/help                     show this help
/quit                     close the sidecar and exit

Runtime-owned commands are not invented by this frontend. Session selection and
turn submission require a negotiated product command contract. No tools, provider
calls, shell commands, or collection are executed by this UI.
`;
export async function main(argv = process.argv.slice(2)) {
  if (argv.includes('--help')) { process.stdout.write(HELP); return; }
  let command = process.env.AGENTPROLOG_SIDECAR; const args = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--sidecar' && argv[i + 1]) command = argv[++i];
    else if (argv[i] === '--sidecar-arg' && argv[i + 1]) args.push(argv[++i]);
    else throw new Error(`Unknown or incomplete argument: ${argv[i]}`);
  }
  if (!command) throw new Error('Configure --sidecar EXECUTABLE (canonical prolog_agent_ui_v1). No runtime was started.');
  const client = new Client({ command, args });
  const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: process.stdin.isTTY });
  const show = () => { process.stdout.write('\n' + render(client.view, client.connected) + '\n'); rl.prompt(); };
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
      else if (op === '/reconnect') await client.connect();
      else if (op === '/cancel') await client.command('session.cancel');
      else if (op === '/approve') await client.command('approval.decide', { approval_id: words[0], decision: words[1] });
      else if (op === '/answer') await client.command('question.answer', { question_id: words[0], answer: words.slice(1).join(' ') });
      else if (op) throw new Error('Turn submission is unavailable until the runtime advertises the product command contract. Use /help.');
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
