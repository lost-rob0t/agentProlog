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
                  [--config FILE] [--plugin FILE ...] [--package DIR ...] [--agent NAME] [--trust-project]
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
/approve [ID DECISION]  choose an exact offered decision; bare: selection menu for newest approval
/answer [ID TEXT]       answer a pending question; bare: reopen newest; /answer list lists all
/report-bug [TEXT]        start an AI bug-intake interview about a problem you hit
/help                     show this help
/quit                     close the sidecar and exit

Interactive menus: while a question/approval is pending, /answer or /approve
opens a numbered selection menu (/back leaves it without sending). /answer list
shows pending and answered questions; answered ones are read-only history.

Plugins and --trust-project explicitly authorize executing that local Prolog code.
Project configuration is never silently trusted. Tool grants are explicit.
Type an objective or follow-up to submit a session.turn command.
The configured sidecar owns the session and profile. Choose a different operator-
configured sidecar/state directory to switch workspaces. No tools, provider calls,
shell commands, or collection are executed by this UI.
`;
export const REPORT_BUG_COMMAND = '/report-bug';
export function reportBugObjective(input = '') {
  const described = input.trim();
  const symptom = described
    ? `The user's initial report: "${described}"`
    : 'The user typed no description yet; your first question must ask for the first concrete observation.';
  return [
    'Bug intake interview for AgentProlog. Collect exactly one structured bug report.',
    symptom,
    'Rules: ask the user short clarifying questions one at a time through your available question mechanism, and only about what you still need; never invent facts, never modify files, never run mutation tools, and never claim an issue was filed anywhere. When you have enough information, reply with the final report only, using exactly these headings: Title, Component, Environment, Steps to reproduce, Expected, Actual, Severity, Suspected cause, Missing information. If this configuration gives you no way to ask questions, produce the report from what you have and record the gaps under Missing information.'
  ].join('\n');
}
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
    else if (option === '--plugin' || option === '--package' || option === '--config') hostFlags.push(option, realpathSync(value));
    else if (option === '--agent') hostFlags.push(option, value);
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
  // mode: null | {kind:'answer'|'approve', id} | {kind:'select', items}
  let mode = null;
  const openPending = () => {
    const state = client.view?.state ?? {};
    return {
      questions: (state.questions ?? []).filter(row => row.status === 'pending'),
      approvals: (state.approvals ?? []).filter(row => row.status === 'pending'),
    };
  };
  const promptText = () => mode === null ? 'agentprolog> '
    : mode.kind === 'select' ? 'select> ' : `${mode.kind} ${mode.id}> `;
  const showInteraction = row => {
    const choices = row.choices?.length
      ? `\n  choices: ${row.choices.map((choice, index) => `[${index + 1}] ${choice}`).join('  ')}` : '';
    if (row.prompt) process.stdout.write(`\n${safe(row.prompt)}\n`);
    process.stdout.write(`${mode.kind} ${row.id}${choices}\n  Enter a number${row.choices?.length ? '' : ' or free text'}, or /back without sending.\n`);
  };
  const menuBlock = () => {
    const open = openPending();
    const rows = [
      ...open.questions.map(question => `question ${question.id}${question.choices?.length ? ` (${question.choices.join(', ')})` : ''}`),
      ...open.approvals.map(approval => `approval ${approval.id}${approval.choices?.length ? ` (${approval.choices.join(', ')})` : ''}`),
    ];
    if (rows.length) process.stdout.write(`\nPending: ${rows.join(' · ')}\n/answer or /approve opens a selection menu; /answer list lists everything.\n`);
  };
  const listInteractions = () => {
    const state = client.view.state ?? {};
    const items = [];
    process.stdout.write('\nInteractions:\n');
    (state.questions ?? []).forEach(row => {
      if (row.status === 'pending') {
        items.push({ kind: 'answer', id: row.id });
        process.stdout.write(` [${items.length}] question ${row.id} (pending)${row.choices?.length ? ` choices: ${row.choices.join(', ')}` : ' — free text'}\n`);
      } else {
        process.stdout.write(` – question ${row.id} (${row.status ?? 'answered'}) answer: ${safe(String(row.answer ?? ''))} — already submitted; send a follow-up objective to correct.\n`);
      }
    });
    (state.approvals ?? []).filter(row => row.status === 'pending').forEach(row => {
      items.push({ kind: 'approve', id: row.id });
      process.stdout.write(` [${items.length}] approval ${row.id}${row.choices?.length ? ` choices: ${row.choices.join(', ')}` : ''}\n`);
    });
    if (!items.length) process.stdout.write(' (nothing pending; answered history above is read-only)\n');
    else process.stdout.write('Enter a number to open one; /back or an empty line leaves this list.\n');
    return items;
  };
  const show = () => {
    if (process.stdout.isTTY) process.stdout.write('\x1b[2J\x1b[H');
    process.stdout.write('\n' + render(client.view, client.connected) + '\n');
    menuBlock();
    rl.setPrompt(promptText()); rl.prompt(true);
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
  const dispatch = async (op, words, line) => {
    if (op === '/quit') return await close();
    if (op === '/help') process.stdout.write(HELP);
    else if (op === '/inspect') show();
    else if (op === '/profile') process.stdout.write(safe(JSON.stringify(client.descriptor, null, 2)) + '\n');
    else if (op === '/create') await client.command('session.create');
    else if (op === '/select') await client.command('session.select');
    else if (op === '/resume') await client.command('session.resume');
    else if (op === '/reconnect') await client.connect();
    else if (op === '/cancel') await client.command('session.cancel');
    else if (op === '/approve') {
      const approvals = openPending().approvals;
      if (!words.length) {
        if (!approvals.length) throw new Error('No pending approvals.');
        mode = { kind: 'approve', id: approvals[approvals.length - 1].id };
        showInteraction(approvals[approvals.length - 1]);
      } else if (words[0] === 'list') {
        mode = { kind: 'select', items: listInteractions() };
      } else await client.command('approval.decide', { approval_id: words[0], decision: words[1] });
    }
    else if (op === '/answer') {
      if (!words.length) {
        const questions = openPending().questions;
        if (!questions.length) throw new Error('No pending questions. /answer list shows answered history.');
        mode = { kind: 'answer', id: questions[questions.length - 1].id };
        showInteraction(questions[questions.length - 1]);
      } else if (words[0] === 'list') {
        mode = { kind: 'select', items: listInteractions() };
      } else await client.command('question.answer', { question_id: words[0], answer: words.slice(1).join(' ') });
    }
    else if (op === REPORT_BUG_COMMAND) await client.command('session.turn', { objective: reportBugObjective(line.trim().slice(REPORT_BUG_COMMAND.length)) });
    else if (op?.startsWith('/')) throw new Error('Unknown command. Use /help.');
    else if (op) await client.command('session.turn', { objective: line });
  };
  rl.on('line', async line => {
    const [op, ...words] = line.trim().split(/\s+/);
    try {
      if (mode) {
        if (op === '/back' || (mode.kind === 'select' && !op)) mode = null;
        else if (op?.startsWith('/')) { mode = null; await dispatch(op, words, line); }
        else if (mode.kind === 'answer') {
          const question = client.view.state?.questions?.find(row => row.id === mode.id);
          if (!question || question.status !== 'pending') throw new Error(`Question ${mode.id} is no longer pending; /answer list to review.`);
          const index = Number(line);
          const answer = Number.isInteger(index) && question.choices?.[index - 1] !== undefined
            ? String(question.choices[index - 1]) : line;
          await client.command('question.answer', { question_id: mode.id, answer });
          mode = null;
        } else if (mode.kind === 'approve') {
          const approval = client.view.state?.approvals?.find(row => row.id === mode.id);
          if (!approval || approval.status !== 'pending') throw new Error(`Approval ${mode.id} is no longer pending.`);
          const index = Number(line);
          if (!Number.isInteger(index) || approval.choices?.[index - 1] === undefined)
            throw new Error(`Enter a choice number 1-${approval.choices?.length ?? 0}, or /back without sending.`);
          await client.command('approval.decide', { approval_id: mode.id, decision: approval.choices[index - 1] });
          mode = null;
        } else {
          const index = Number(line);
          if (!Number.isInteger(index) || index < 1 || index > mode.items.length)
            throw new Error(`Enter 1-${mode.items.length}, or /back.`);
          const item = mode.items[index - 1];
          const row = item.kind === 'answer'
            ? client.view.state?.questions?.find(candidate => candidate.id === item.id)
            : client.view.state?.approvals?.find(candidate => candidate.id === item.id);
          if (!row || row.status !== 'pending') throw new Error('That interaction is no longer pending; /answer list again.');
          mode = { kind: item.kind, id: item.id };
          showInteraction(row);
        }
      } else await dispatch(op, words, line);
    } catch (error) { process.stderr.write(`${safe(error.code ?? 'error')}: ${safe(error.message)}\n`); }
    if (!closing) { rl.setPrompt(promptText()); rl.prompt(); }
  });
  process.stdout.write(HELP);
  try { await client.connect(); rl.prompt(); }
  catch (error) { await close(); throw error; }
}
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main().catch(error => { process.stderr.write(safe(error.message) + '\n'); process.exitCode = 1; });
}
