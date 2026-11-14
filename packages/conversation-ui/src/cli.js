#!/usr/bin/env node
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';
import { realpathSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';
import { Client } from './client.js';
import { render, safe } from './render.js';
import { Activity, TranscriptViewport, renderChat, approvalDetails, shouldRedraw } from './presentation.js';
import {Composer} from './composer.js';
import {selectImage} from './images.js';
import { Notifications, notificationOptions } from './notifications.js';
export const HELP = `AgentProlog canonical conversation UI
Usage: agentProlog [--project DIR] [--state DIR]
                  [--config FILE] [--plugin FILE ...] [--package DIR ...] [--agent NAME] [--trust-project]
                  [--allow-tool NAME ...] [--allow-context OP ...] [--allow-model NAME ...]
       agentProlog --sidecar EXECUTABLE [--sidecar-arg ARG ...]
       agentProlog [--notify off|text|bell] [--notify-on approval,question,complete,failed,cancelled]
       agentProlog --help

/create                   initialize/select the configured canonical session
/select                   refresh the configured canonical session
/resume                   explicitly resume the previous objective as a new run
/ask NAME QUESTION        invoke a configured provider-free symbolic expert
/army PROFILES QUESTION   run bounded configured read-only subagents sequentially
/swarm PROFILES QUESTION  not a swarm: uses the /army bridge (upstream issue #568)
/learn NAME               propose a finite normalizer from labelled examples
/rsi-context NAME         compare bounded project context packs; no adoption
/sleep                    derive unverified chat consolidation preview
/rsi NAME                 evaluate configured baseline/candidate; no promotion
/remember [TEXT]          read private notes, or request approval to save text
/next                     show ready tasks from the configured private journal
/handoff                  show a read-only workflow handoff (no files written)
/image PATH               select local PNG/JPEG, not sent yet (max 256 KiB)
/send-image QUESTION      send selected image to configured provider
/image-clear              discard selected image
/compose                  open/resume an in-memory multiline draft
/draft-preview|undo       inspect draft or remove last line (in composer)
/draft-edit N TEXT        replace a draft line, preserving text
/draft-insert N TEXT      insert before N (or append at next line)
/draft-delete N           delete one draft line
/draft-preview [N [END]]  inspect at most 50 numbered draft lines
/draft-send[-image]       explicitly send draft (with selected image if requested)
/draft-pause|discard      leave composer, retaining or discarding draft
/draft-literal TEXT       insert a reserved draft-control line literally
/profile                  show runtime-owned profile and capabilities
/scroll up|down           page through bounded transcript (TTY only)
/bottom                   return to live output (TTY only)
/inspect                  toggle canonical evidence/usage view and chat view
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
shell commands, or collection are executed by this UI. /image explicitly reads
one selected local file; /send-image authorizes sending those bytes to the provider.
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
  let notifyMode='off', notifyEvents;
  for (let i = 0; i < argv.length; i++) {
    const option = argv[i];
    if (option === '--trust-project') { hostFlags.push(option); continue; }
    if (!argv[i + 1]) throw new Error(`Incomplete argument: ${option}`);
    const value = argv[++i];
    if (option === '--notify') { notifyMode=value; }
    else if (option === '--notify-on') { notifyEvents=value; }
    else if (option === '--sidecar') { command = value; external = true; }
    else if (option === '--sidecar-arg') args.push(value);
    else if (option === '--project') project = value;
    else if (option === '--state') state = resolve(value);
    else if (option === '--plugin' || option === '--package' || option === '--config') hostFlags.push(option, realpathSync(value));
    else if (option === '--agent') hostFlags.push(option, value);
    else if (option === '--allow-tool' || option === '--allow-context' || option === '--allow-model') hostFlags.push(option, value);
    else throw new Error(`Unknown argument: ${option}`);
  }
  const notifyConfig=notificationOptions(notifyMode,notifyEvents);
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
  const notifications=new Notifications(notifyConfig,{write:text=>process.stderr.write(text),isTTY:process.stderr.isTTY});
  client.on('view',(view,frame)=>notifications.consume(view,frame));
  const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: process.stdin.isTTY });
  // mode: null | {kind:'answer'|'approve', id} | {kind:'select', items}
  let mode = null;
  let selectedImage=null;
  const composer=new Composer();
  let draftPendingSignature="";
  const openPending = () => {
    const state = client.view?.state ?? {};
    return {
      questions: (state.questions ?? []).filter(row => row.status === 'pending'),
      approvals: (state.approvals ?? []).filter(row => row.status === 'pending'),
    };
  };
  const promptText = () => composer.active ? `draft ${composer.lines.length+1}> ` : mode === null ? (process.stdout.isTTY?'  › ':'agentprolog> ')
    : mode.kind === 'select' ? 'select> ' : `${mode.kind} ${mode.id}> `;
  const showInteraction = row => {
    if(mode.kind==='approve'){mode.signature=JSON.stringify(row);process.stdout.write(`\n${approvalDetails(row)}\n`);}
    const choices = row.choices?.length
      ? `\n  choices: ${row.choices.map((choice, index) => `[${index + 1}] ${choice}`).join('  ')}` : '';
    if (row.prompt) process.stdout.write(`\n${safe(row.prompt)}\n`);
    process.stdout.write(safe(`${mode.kind} ${row.id}${choices}\n  Enter a number${row.choices?.length ? '' : ' or free text'}, or /back without sending.\n`));
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
  let inspecting=false;
  const activity=new Activity();
  const viewport=new TranscriptViewport();
  client.on('view',(view,frame)=>activity.consume(view,frame));
  const show = (inspect=inspecting) => {
    if(composer.active)return;
    if(!shouldRedraw(process.stdout.isTTY,mode))return;
    if (process.stdout.isTTY) process.stdout.write('\x1b[2J\x1b[H');
    process.stdout.write((process.stdout.isTTY?'':'\n') + (process.stdout.isTTY&&!inspect ? renderChat(client.view,client.connected,activity,!process.env.NO_COLOR,{columns:process.stdout.columns,rows:process.stdout.rows,profile:client.descriptor?.profile,image:selectedImage?.name,viewport}) : render(client.view,client.connected)) + '\n');
    if(!process.stdout.isTTY||inspect)menuBlock();
    rl.setPrompt(promptText()); rl.prompt(true);
  };
  const onResize=()=>{viewport.bottom();show();};
  process.stdout.on('resize',onResize);
  const onKey=(_text,key)=>{
    if(!process.stdout.isTTY||mode||inspecting||!['pageup','pagedown'].includes(key?.name))return;
    viewport.page(key.name==='pageup'?-1:1);show();
  };
  process.stdin.on('keypress',onKey);
  let renderTimer;
  client.on('view', () => { if(composer.active){const pending=openPending();const signature=JSON.stringify(pending);if(signature!==draftPendingSignature&&(pending.approvals.length||pending.questions.length))process.stdout.write('\nPending interaction: /draft-pause then /approve or /answer to inspect.\n');draftPendingSignature=signature;return;} if(!renderTimer)renderTimer=setTimeout(()=>{renderTimer=null;show();},40); });
  const heartbeat=setInterval(()=>{if(process.stdout.isTTY&&client.connected&&client.view.state?.status==='running')show();},250);
  heartbeat.unref();
  client.on('fault', error => { process.stderr.write(`\n${safe(error.code ?? 'error')}: ${safe(error.message)}\n`); show(); });
  client.on('diagnostic', text => process.stderr.write(safe(text)));
  rl.setPrompt('agentprolog> ');
  let closing = false;
  const close = async () => { if (closing) return; closing = true; clearTimeout(renderTimer); clearInterval(heartbeat); process.stdout.off('resize',onResize);process.stdin.off('keypress',onKey); rl.close(); process.stdin.pause(); await client.close(); };
  rl.on('close', close);
  process.once('SIGINT', close); process.once('SIGTERM', close);
  const dispatch = async (op, words, line) => {
    if(op==='/compose'){composer.active=true;process.stdout.write('Multiline draft: Enter adds a line; /draft-send sends. /draft-preview, /draft-edit N TEXT, /draft-insert N TEXT, /draft-delete N, /draft-undo, /draft-pause, /draft-discard. Other slash lines are literal. Draft stays local until sent.\n');return;}
    if (op === '/quit') return await close();
    if (op === '/help') process.stdout.write(HELP);
    else if(op==='/image') {
      if(!client.descriptor?.capabilities?.includes('image_input'))throw new Error('Configured session does not enable image input.');
      selectedImage=await selectImage(line.slice('/image'.length).trim());
      process.stdout.write(safe(`Selected ${selectedImage.name} (${selectedImage.mime}). Not sent. /send-image QUESTION transmits these bytes to the configured provider for profile ${client.descriptor?.profile??'unknown'}. Bytes are not retained for future turns; /image-clear discards.\n`));
    }
    else if(op==='/image-clear'){selectedImage=null;process.stdout.write('Selected image discarded.\n');}
    else if(op==='/send-image') {
      if(!selectedImage)throw new Error('Select an image first with /image PATH.');
      const objective=line.slice('/send-image'.length).trim();if(!objective)throw new Error('Provide the image question.');
      await client.command('session.turn',{objective,images:[selectedImage]});selectedImage=null;
    }
    else if(op==='/scroll'||op==='/bottom'){
      if(!process.stdout.isTTY)throw new Error('Transcript navigation requires a terminal.');
      if(op==='/bottom')viewport.bottom();
      else if(words.length===1&&['up','down'].includes(words[0]))viewport.page(words[0]==='up'?-1:1);
      else throw new Error('Usage: /scroll up|down');
      show();
    }
    else if (op === '/inspect') {inspecting=!inspecting;show();}
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
      } else {
        const row=approvals.find(a=>a.id===words[0]);
        if(!row)throw new Error('No matching pending approval.');
        mode={kind:'approve',id:row.id};showInteraction(row);
        process.stdout.write('Review these details and enter a choice number to confirm; no decision sent yet.\n');
      }
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
    else if (op === '/army' || op === '/swarm') {
      if (words.length < 2) throw new Error(`Usage: ${op} PROFILE[,PROFILE] QUESTION or ${op} tasks JSON`);
      if (op === '/swarm') process.stderr.write('This is not a swarm. Uses ordinary subagents. Tracking: https://github.com/lost-rob0t/prolog-rlm/issues/568\n');
      await client.command('session.turn', { objective: line });
    }
    else if (op === '/rsi' || op === '/rsi-context' || op === '/learn') {
      if (words.length !== 1) throw new Error(`Usage: ${op} NAME`);
      await client.command('session.turn', { objective: line });
    }
    else if (op === '/remember') {
      await client.command('session.turn', { objective: line });
    }
    else if (op === '/next' || op === '/handoff' || op === '/sleep') {
      if (words.length) throw new Error(`${op} takes no arguments`);
      await client.command('session.turn', { objective: line });
    }
    else if (op === '/ask') {
      if (words.length < 2 || !/^[A-Za-z0-9_-]+$/.test(words[0])) throw new Error('Usage: /ask NAME QUESTION');
      await client.command('session.turn', { objective: line });
    }
    else if (op === REPORT_BUG_COMMAND) await client.command('session.turn', { objective: reportBugObjective(line.trim().slice(REPORT_BUG_COMMAND.length)) });
    else if (op?.startsWith('/')) throw new Error('Unknown command. Use /help.');
    else if (op) await client.command('session.turn', { objective: line });
  };
  rl.on('line', async line => {
    const [op, ...words] = line.trim().split(/\s+/);
    try {
      if(composer.active){
        let action;
        if(line.startsWith('/draft-literal ')){if(composer.sending)throw new Error('Draft send is pending.');composer.literal(line.slice(15));action='append';}
        else action=composer.input(line);
        if(action==='preview'||action?.kind==='preview'){
          const start=action.start??1,end=action.end??Math.min(20,composer.lines.length);
          process.stdout.write(composer.lines.slice(start-1,end).map((text,i)=>`${start+i}: ${safe(text)}`).join('\n')+'\n');
          process.stdout.write(`Draft: ${composer.lines.length} lines; showing ${composer.lines.length?`${start}-${end}`:'none'}. /draft-preview N END (max 50).\n`);
        }
        if(action==='send'||action==='send-image'){
          if(action==='send-image'&&!selectedImage)throw new Error('No selected image. /draft-pause then /image PATH, then /compose.');
          composer.sending=true;
          try{await client.command('session.turn',{objective:composer.text,...(action==='send-image'?{images:[selectedImage]}:{})});composer.sent();if(action==='send-image')selectedImage=null;}
          finally{composer.sending=false;}
        }
      } else if (mode) {
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
          if(mode.signature!==JSON.stringify(approval)){showInteraction(approval);throw new Error('Approval details changed; review them and choose again.');}
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
