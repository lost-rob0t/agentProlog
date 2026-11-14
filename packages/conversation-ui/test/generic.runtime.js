// Full generic host process with mocked model I/O, real native tools and files.
import test from 'node:test';
import { createServer } from 'node:http';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, access, rm, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { spawn, execFileSync } from 'node:child_process';
import { Client } from '../src/client.js';
import { render } from '../src/render.js';
const repo = fileURLToPath(new URL('../../../', import.meta.url));
const runtime = process.env.PROLOG_RLM_SOURCE;
assert.ok(runtime, 'PROLOG_RLM_SOURCE must name the pinned runtime checkout');
const support = fileURLToPath(new URL('./support/generic_fixture.pl', import.meta.url));
const quote = value => `'${value.replaceAll("'", "''")}'`;
const terminal = c => c.view.state?.run?.outcome?.status;
const approval = c => c.view.state?.approvals.find(a => a.status === 'pending');
async function until(c, predicate, diagnostics = () => '') {
  if (predicate()) return;
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { cleanup(); reject(new Error(`Native generic timeout\n${render(c.view)}\n${diagnostics()}`)); }, 15000);
    const check = () => { if (predicate()) { cleanup(); resolve(); } };
    const fail = error => { cleanup(); reject(error); };
    function cleanup() { clearTimeout(timer); c.off('view', check); c.off('fault', fail); }
    c.on('view', check); c.on('fault', fail);
  });
}
async function setup(t, scenario, projectLocal = false) {
  const temp = await mkdtemp(join(tmpdir(), 'agentprolog-generic-'));
  const project = join(temp, 'project'), state = join(temp, 'state'); await mkdir(project);
  await writeFile(join(project, 'input.txt'), 'READ_MARKER: synthetic input only\n');
  if (projectLocal) await mkdir(join(project,'.agentprolog'));
  const plugin = projectLocal ? join(project,'.agentprolog/config.pl') : join(temp, 'fixture.pl');
  await writeFile(plugin, `:- module(test_generic_profile,[agentprolog_config/1]).\n:- use_module(${quote(support)}).\nagentprolog_config(C) :- configuration(${quote(project)},${scenario},C).\n`);
  const args = ['-q', '-p', `library=${runtime}/prolog`, '-s', join(repo, 'prolog/agentprolog_session.pl'), '--', state, project, ...(projectLocal ? ['--trust-project'] : ['--plugin', plugin]),
    ...['workspace_read','workspace_create','workspace_modify','workspace_write','expert_echo','workflow_next','workflow_handoff','memory_remember','memory_recall','rsi_echo','context_experiment_demo','learn_demo','workspace_test','workspace_patch','workspace_list','workspace_search'].flatMap(name => ['--allow-tool',name]), '--allow-context', 'peek', '--allow-model', 'openai_compatible'];
  const c = new Client({ command: process.env.SWIPL ?? 'swipl', args }); let stderr = '';
  c.on('diagnostic', x => stderr += x);
  t.after(async () => { await c.close(); await rm(temp,{recursive:true,force:true}); });
  try { await c.connect(); await until(c, () => c.ready, () => stderr); }
  catch (error) { throw new Error(`${error.message}\n${stderr}`, {cause:error}); }
  return { c, project, state, stderr: () => stderr };
}
test('generic native tool reads actual file and model inspects opaque result context', async t => {
  const { c, stderr, state } = await setup(t,'read');
  await access(join(state,'effects.db'));
  await c.command('session.turn',{objective:'Read the harmless synthetic file'});
  await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'complete',render(c.view));
  assert.match(render(c.view),/READ_MARKER/);
  assert.ok(c.view.state.tools.some(tool => tool.name === 'workspace_read' && tool.output.content.includes('READ_MARKER')));
  assert.ok(c.view.state.usage.total_tokens > 0);
});
test('generic artifact approval allow and deny preserve canonical truth', async t => {
  const { c, stderr } = await setup(t,'artifact');
  await c.command('session.turn',{objective:'Produce a reviewable synthetic artifact'});
  await until(c,()=>approval(c)||terminal(c),stderr); assert.ok(approval(c),render(c.view));
  await c.command('approval.decide',{approval_id:approval(c).id,decision:'deny'});
  await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'rejected');
  await c.command('session.resume'); await until(c,()=>approval(c)||terminal(c),stderr);
  assert.ok(approval(c),render(c.view)); const id=approval(c).id;
  await c.command('approval.decide',{approval_id:id,decision:'allow_once'});
  await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'complete');
  assert.equal(c.view.state.run.outcome.published,false);
  assert.throws(()=>c.command('approval.decide',{approval_id:id,decision:'allow_once'}),{code:'stale_decision'});
});
test('generic cancellation and process crash recover without false completion', async t => {
  const { c, project, stderr } = await setup(t,'slow');
  await c.command('session.turn',{objective:'Slow synthetic model response'});
  await fileAppears(join(project,'model-started'));
  await c.command('session.cancel'); await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'cancelled');
  await new Promise(resolve => setTimeout(resolve, 2200));
  await assert.rejects(access(join(project,'model-completed')));
  await c.command('session.resume'); await until(c,()=>c.view.state.status==='running',stderr);
  const disconnected=once(c,'fault'); c.child.kill('SIGKILL'); await disconnected;
  const session=c.view.sessionId; await c.connect().catch(error => { throw new Error(`${error.message}\n${stderr()}`, {cause:error}); }); await until(c,()=>c.ready,stderr);
  assert.equal(c.view.sessionId,session); assert.equal(terminal(c),'interrupted');
});
for (const scenario of ['failure','budget']) test(`generic ${scenario} produces failed outcome, never success`, async t => {
  const { c, stderr } = await setup(t,scenario);
  await c.command('session.turn',{objective:'Controlled failure path'}); await until(c,()=>terminal(c),stderr);
  assert.equal(terminal(c),'failed'); assert.match(render(c.view),/Run outcome: failed/);
});
test('native workspace create/modify/write requires each approval and changes actual bytes', async t => {
  const { c, project, stderr } = await setup(t,'write');
  await c.command('session.turn',{objective:'Create and edit only the synthetic file'});
  for (const expected of [null,'first bytes','second bytes']) {
    await until(c,()=>approval(c)||terminal(c),stderr); assert.ok(approval(c),render(c.view));
    if (expected===null) await assert.rejects(access(join(project,'created.txt')));
    else assert.equal(await readFile(join(project,'created.txt'),'utf8'),expected);
    const id=approval(c).id;
    await c.command('approval.decide',{approval_id:id,decision:'allow_once'});
    await until(c,()=>!approval(c)||approval(c).id!==id||terminal(c),stderr);
  }
  await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'complete',render(c.view));
  assert.equal(await readFile(join(project,'created.txt'),'utf8'),'final bytes');
  assert.match(render(c.view),/Created, modified, wrote and read actual file/);
});
test('native denied workspace creation leaves the filesystem unchanged', async t => {
  const { c, project, stderr } = await setup(t,'write');
  await c.command('session.turn',{objective:'Request synthetic creation, then deny'});
  await until(c,()=>approval(c)||terminal(c),stderr); assert.ok(approval(c),render(c.view));
  await c.command('approval.decide',{approval_id:approval(c).id,decision:'deny'});
  await until(c,()=>terminal(c),stderr); assert.notEqual(terminal(c),'complete');
  await assert.rejects(access(join(project,'created.txt')));
});
test('trusted project-local config supports canonical question, answer, select and follow-up', async t => {
  const { c, stderr } = await setup(t,'hello',true);
  await c.command('session.create'); const session=c.view.sessionId;
  await c.command('session.turn',{objective:''});
  await until(c,()=>c.view.state.questions.some(q=>q.status==='pending'),stderr);
  const question=c.view.state.questions.find(q=>q.status==='pending');
  await c.command('question.answer',{question_id:question.id,answer:'Synthetic greeting'});
  await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'complete');
  const run=c.view.state.run.run_id;
  await c.command('session.select'); assert.equal(c.view.sessionId,session);
  await c.command('session.turn',{objective:'Synthetic follow-up'});
  await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'complete');
  assert.notEqual(c.view.state.run.run_id,run); assert.match(render(c.view),/Synthetic hello/);
});
test('durable state rejects another project binding and recovers with original project', async t => {
  const { c, project, state, stderr } = await setup(t,'hello'); const session=c.view.sessionId;
  await c.close(); const other=join(project,'other-project'); await mkdir(other);
  const index=c.args.indexOf(state)+1; assert.equal(c.args[index],project);
  c.args[index]=other; await assert.rejects(c.connect()); assert.equal(c.ready,false);
  c.args[index]=project;
  try { await c.connect(); await until(c,()=>c.ready); }
  catch(error) { throw new Error(`${error.message}\n${stderr()}`,{cause:error}); }
  assert.equal(c.view.sessionId,session);
});
test('installed CLI default generic host loads trusted local config and reads actual workspace', async t => {
  const temp=await mkdtemp(join(tmpdir(),'agentprolog-installed-'));
  t.after(()=>rm(temp,{recursive:true,force:true}));
  const project=join(temp,'project'); await mkdir(join(project,'.agentprolog'),{recursive:true});
  await writeFile(join(project,'input.txt'),'READ_MARKER: installed CLI synthetic input\n');
  await writeFile(join(project,'.agentprolog/config.pl'),`:- module(test_installed_profile,[agentprolog_config/1]).\n:- use_module(${quote(support)}).\nagentprolog_config(C) :- configuration(${quote(project)},read,C).\n`);
  const install=join(temp,'install');
  execFileSync('npm',['install','--ignore-scripts','--no-audit','--no-fund','--prefix',install,join(repo,'packages/conversation-ui')],{encoding:'utf8'});
  const launcher=join(temp,'host');
  const shellQuote=value=>`'${value.replaceAll("'","'\\''")}'`;
  const swipl=process.env.SWIPL ?? 'swipl';
  await writeFile(launcher,`#!/bin/sh\nexec ${shellQuote(swipl)} -q -p ${shellQuote(`library=${runtime}/prolog`)} -s ${shellQuote(join(repo,'prolog/agentprolog_session.pl'))} -- "$@"\n`);
  await chmod(launcher,0o700);
  const args=['--project',project,'--state',join(temp,'state'),'--trust-project',
    ...['workspace_read','workspace_create','workspace_modify','workspace_write','expert_echo','workflow_next','workflow_handoff','memory_remember','memory_recall','rsi_echo','context_experiment_demo','learn_demo','workspace_test','workspace_patch','workspace_list','workspace_search'].flatMap(name=>['--allow-tool',name]),'--allow-context','peek'];
  const child=spawn(join(install,'node_modules/.bin/agentProlog'),args,{cwd:project,
    env:{...process.env,AGENTPROLOG_SESSION:launcher,AGENTPROLOG_SIDECAR:''},stdio:['pipe','pipe','pipe']});
  t.after(()=>{if(child.exitCode===null)child.kill('SIGKILL');});
  let output='',stderr='',submitted=false,quitting=false;
  child.stderr.on('data',data=>stderr+=data);
  child.stdout.on('data',data=>{
    output+=data;
    if(!submitted && output.includes('Connection: connected')) {
      submitted=true; child.stdin.write('Read the harmless synthetic input file\n');
    }
    if(!quitting && output.includes('Run outcome: complete') && output.includes('Observed actual fixture input: READ_MARKER')) {
      quitting=true; child.stdin.end('/inspect\n/quit\n');
    }
  });
  const timer=setTimeout(()=>child.kill('SIGKILL'),15000);
  const [code]=await once(child,'exit');clearTimeout(timer);
  assert.equal(code,0,`${stderr}\n${output}`); assert.equal(quitting,true);
  assert.match(output,/workspace_read/);assert.match(output,/installed CLI synthetic input/);
  assert.ok((output.match(/Run outcome: complete/g)??[]).length>=2,'/inspect must render the canonical completed view');
  console.log('Installed CLI native interaction: objective → workspace_read → context_peek → answer → /inspect → /quit');
});

async function fileAppears(path) {
  for(let i=0;i<500;i++) { try { await access(path); return; } catch { await new Promise(r=>setTimeout(r,10)); } }
  assert.fail(`Native fixture did not enter active model handler: ${path}`);
}
test('cancel immediately after admission prevents later model completion', async t => {
  const { c, project, stderr } = await setup(t,'slow');
  await c.command('session.turn',{objective:'Cancel this synthetic run immediately'});
  await c.command('session.cancel'); await until(c,()=>terminal(c),stderr);
  assert.equal(terminal(c),'cancelled');
  await new Promise(resolve=>setTimeout(resolve,2200));
  await assert.rejects(access(join(project,'model-completed')));
});

for (const mode of ['cancel','crash']) test(`native pending approval ${mode} never writes and reconnects honestly`, async t => {
  const {c,project,stderr}=await setup(t,'write');
  await c.command('session.turn',{objective:'Request bounded fixture creation'});
  await until(c,()=>approval(c)||terminal(c),stderr); assert.ok(approval(c),render(c.view));
  if(mode==='cancel') { await c.command('session.cancel'); await until(c,()=>terminal(c),stderr); }
  else { const exited=once(c.child,'exit'); c.child.kill('SIGKILL'); await exited; }
  await c.connect(); await until(c,()=>c.ready,stderr);
  assert.equal(terminal(c),mode==='cancel'?'cancelled':'interrupted');
  assert.equal(approval(c),undefined);
  await assert.rejects(access(join(project,'created.txt')));
});

test('opt-in canonical projection delivers prior user and assistant across process restart', async t => {
  const { c, stderr, state } = await setup(t,'history');
  await c.command('session.turn',{objective:'FIRST_TURN_MARKER'});
  await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'complete',render(c.view));
  const firstRun=c.view.state.run.run_id;
  await c.close(); await c.connect(); await until(c,()=>c.ready,stderr);
  await c.command('session.turn',{objective:'What was the marker?'});
  await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'complete',render(c.view));
  assert.notEqual(c.view.state.run.run_id,firstRun);
  const saved=JSON.parse(await readFile(join(state,'session.json'),'utf8'));
  assert.equal(saved.history.length,2);
  assert.equal(saved.history[0].user,'FIRST_TURN_MARKER');
});

test('production provider transport receives role-preserving history over loopback HTTP', async t => {
  const requests=[];
  const server=createServer(async (req,res) => {
    let raw=''; for await (const part of req) raw+=part;
    requests.push(JSON.parse(raw));
    res.writeHead(200,{'content-type':'application/json'});
    res.end(JSON.stringify({id:'loopback',model:'test/model',
      choices:[{index:0,message:{role:'assistant',content:'HTTP answer'},finish_reason:'stop'}],
      usage:{prompt_tokens:5,completion_tokens:2,total_tokens:7}}));
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(()=>new Promise(resolve=>server.close(resolve)));
  const endpoint=`http://127.0.0.1:${server.address().port}/chat/completions`;
  const {c,stderr}=await setup(t,`loopback(${quote(endpoint)})`);
  await c.command('session.turn',{objective:'HTTP_FIRST_MARKER'});
  await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'complete',render(c.view));
  await c.close(); await c.connect(); await until(c,()=>c.ready,stderr);
  await c.command('session.turn',{objective:'HTTP follow-up'});
  await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'complete',render(c.view));
  assert.equal(requests.length,2);
  const messages=requests[1].messages;
  assert.ok(messages.some(m=>m.role==='user'&&m.content==='HTTP_FIRST_MARKER'));
  assert.ok(messages.some(m=>m.role==='assistant'&&m.content==='HTTP answer'));
  assert.ok(messages.some(m=>m.role==='user'&&m.content.includes('HTTP follow-up')));
  assert.ok(!messages.some(m=>m.role==='system'&&m.content.includes('HTTP_FIRST_MARKER')));
});

test('native /ask invokes configured expert with zero model calls and reports evidence', async t => {
  const {c,stderr}=await setup(t,'expert');
  await c.command('session.turn',{objective:'/ask echo INERT_QUESTION'});
  await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'complete',render(c.view));
  assert.match(render(c.view),/symbolic_fixture/);
  assert.match(render(c.view),/INERT_QUESTION/);
  assert.equal(c.view.state.usage.model_calls,0);
  assert.ok(c.view.state.tools.some(tool=>tool.name==='expert_echo'));
});

test('native /next and /handoff read private journal without changing it', async t => {
  const {c,stderr,project}=await setup(t,'workflow');
  const path=join(project,'..','journal','task-workflow.pl');
  const before=await readFile(path,'utf8');
  for (const objective of ['/next','/handoff']) {
    await c.command('session.turn',{objective});
    await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'complete',render(c.view));
    assert.match(render(c.view),/READY_FIXTURE/);
    assert.equal(c.view.state.usage.model_calls,0);
    assert.equal(await readFile(path,'utf8'),before);
  }
});

test('native /remember needs approval and persists only inert unverified text', async t => {
  const {c,stderr,project}=await setup(t,'memory');const path=join(project,'..','notes','memory-notes.json');
  await c.command('session.turn',{objective:'/remember :- halt.  literal note'});
  await until(c,()=>approval(c)||terminal(c),stderr); assert.ok(approval(c),render(c.view));
  await assert.rejects(access(path));
  await c.command('approval.decide',{approval_id:approval(c).id,decision:'allow_once'});
  await until(c,()=>terminal(c),stderr); assert.equal(terminal(c),'complete',render(c.view));
  const data=JSON.parse(await readFile(path,'utf8'));
  assert.equal(data.notes[0].text,':- halt.  literal note');assert.equal(data.notes[0].status,'unverified_note');
  await c.command('session.turn',{objective:'/remember denied note'});
  await until(c,()=>approval(c)||terminal(c),stderr);assert.ok(approval(c),render(c.view));
  await c.command('approval.decide',{approval_id:approval(c).id,decision:'deny'});
  await until(c,()=>terminal(c),stderr);assert.notEqual(terminal(c),'complete');
  assert.deepEqual(JSON.parse(await readFile(path,'utf8')),data);
});

for (const how of ['cancel','crash']) test(`pending /remember ${how} never writes or resumes on reconnect`, async t => {
  const {c,stderr,project}=await setup(t,'memory');const path=join(project,'..','notes','memory-notes.json');
  await c.command('session.turn',{objective:'/remember must not write'});
  await until(c,()=>approval(c)||terminal(c),stderr);assert.ok(approval(c),render(c.view));
  if (how==='cancel') {
    await c.command('session.cancel');await until(c,()=>terminal(c),stderr);
    await c.close();
  } else { const fault=once(c,'fault');c.child.kill('SIGKILL');await fault; }
  await c.connect();await until(c,()=>c.ready,stderr);
  await assert.rejects(access(path));assert.notEqual(terminal(c),'complete');
});

test('expired /remember approval cannot perform a late write', async t => {
  const {c,stderr,project}=await setup(t,'memory_fast');
  const path=join(project,'..','notes','memory-notes.json');
  await c.command('session.turn',{objective:'/remember expires'});
  await until(c,()=>approval(c)||terminal(c),stderr);assert.ok(approval(c),render(c.view));
  const id=approval(c).id;
  await until(c,()=>terminal(c),stderr);assert.notEqual(terminal(c),'complete');
  await assert.rejects(access(path));
  try { await c.command('approval.decide',{approval_id:id,decision:'allow_once'}); } catch {}
  await new Promise(r=>setTimeout(r,200));await assert.rejects(access(path));
});

for (const command of ['/army','/swarm']) test(`native ${command} uses actual supervised children`, async t => {
  const {c,stderr}=await setup(t,'army');
  await c.command('session.turn',{objective:`${command} reader,reviewer compare`});
  await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'complete',render(c.view));
  assert.equal(c.view.state.subagents.length,2);assert.equal(c.view.state.usage.model_calls,2);
  assert.match(render(c.view),/CANONICAL_CHILD_RESULT/);
  if(command==='/swarm') {assert.match(render(c.view),/not a swarm/);assert.match(render(c.view),/issues\/568/);}
});
test('cancelling /army cancels active canonical child and skips remaining profiles', async t => {
  const {c,stderr,project}=await setup(t,'army');
  await c.command('session.turn',{objective:'/army reader,reviewer SLOW_CHILD'});
  await fileAppears(join(project,'child-started'));
  await c.command('session.cancel');await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'cancelled');
  await new Promise(r=>setTimeout(r,2200));await assert.rejects(access(join(project,'child-finished')));
  assert.equal(c.view.state.subagents.length,1);
});

test('army preserves prior usage after cancelling a later child', async t => {
  const {c,stderr,project}=await setup(t,'army');
  await c.command('session.turn',{objective:'/army fast,reader,reviewer SLOW_CHILD'});
  await fileAppears(join(project,'child-started'));
  await c.command('session.cancel');await until(c,()=>terminal(c),stderr);
  assert.equal(terminal(c),'cancelled');
  assert.equal(c.view.state.usage.model_calls,1);
  assert.equal(c.view.state.usage.total_tokens,2);
  assert.equal(c.view.state.subagents.length,2);
  await new Promise(r=>setTimeout(r,2200));await assert.rejects(access(join(project,'child-finished')));
});

test('remember without text recalls approved notes without approval or model', async t => {
 const {c,stderr}=await setup(t,'memory');
 await c.command('session.turn',{objective:'/remember'});
 await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'complete');assert.match(render(c.view),/No private notes saved/);
 await c.command('session.turn',{objective:'/remember :- throw(untrusted).'});
 await until(c,()=>approval(c)||terminal(c),stderr);assert.ok(approval(c));
 await c.command('approval.decide',{approval_id:approval(c).id,decision:'allow_once'});
 await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'complete');
 await c.command('session.turn',{objective:'/remember\u00a0'});
 await until(c,()=>approval(c)||terminal(c),stderr);assert.equal(terminal(c),'complete',render(c.view));
 assert.ok(!approval(c));assert.match(render(c.view),/throw\(untrusted\)/);
 assert.match(render(c.view),/unverified_note/);assert.equal(c.view.state.usage.model_calls,0);
});

test('private memory never reaches history-enabled production provider across restart', async t => {
 const requests=[];
 const server=createServer(async(req,res)=>{
  let raw='';for await(const part of req)raw+=part;requests.push(JSON.parse(raw));
  res.writeHead(200,{'content-type':'application/json'});
  res.end(JSON.stringify({id:'memory-spy',model:'test/model',choices:[{index:0,message:{role:'assistant',content:'PUBLIC_REPLY'},finish_reason:'stop'}],usage:{prompt_tokens:1,completion_tokens:1,total_tokens:2}}));
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>new Promise(resolve=>server.close(resolve)));
 const endpoint=`http://127.0.0.1:${server.address().port}/chat/completions`;
 const {c,stderr,state}=await setup(t,`memory_loopback(${quote(endpoint)})`);
 await c.command('session.turn',{objective:'/remember PRIVATE_NOTE_MARKER'});
 await until(c,()=>approval(c)||terminal(c),stderr);assert.ok(approval(c));
 await c.command('approval.decide',{approval_id:approval(c).id,decision:'allow_once'});
 await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'complete');
 await c.command('session.turn',{objective:'/remember'});
 await until(c,()=>terminal(c),stderr);assert.match(render(c.view),/PRIVATE_NOTE_MARKER/);
 assert.equal(requests.length,0);
 await c.command('session.turn',{objective:'PUBLIC_FIRST'});await until(c,()=>terminal(c),stderr);
 assert.equal(terminal(c),'complete');assert.equal(requests.length,1);
 await c.close();await c.connect();await until(c,()=>c.ready,stderr);
 await c.command('session.turn',{objective:'PUBLIC_SECOND'});await until(c,()=>terminal(c),stderr);
 assert.equal(terminal(c),'complete');assert.equal(requests.length,2);
 for(const request of requests)assert.doesNotMatch(JSON.stringify(request),/PRIVATE_NOTE_MARKER|unverified_note|\/remember/);
 assert.ok(requests[1].messages.some(m=>m.role==='user'&&m.content==='PUBLIC_FIRST'));
});

test('rsi evaluates real symbolic experts against fixed paired cases without promotion',async t=>{
 const {c,stderr}=await setup(t,'rsi');
 await c.command('session.turn',{objective:'/rsi echo'});await until(c,()=>terminal(c),stderr);
 assert.equal(terminal(c),'complete',render(c.view));assert.match(render(c.view),/delta:1/);
 assert.match(render(c.view),/decision:hold/);assert.match(render(c.view),/no_promotion_interface/);
 assert.equal(c.view.state.usage.model_calls,0);
 await c.command('session.turn',{objective:'/rsi'});await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'failed');
 await c.command('session.turn',{objective:'/rsi unknown'});await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'failed');
});

test('sleep uses canonical warm derivation through production provider and stays unverified',async t=>{
 const requests=[];
 const summary={summary:'SYNTHETIC_WARM_PREVIEW',decisions:[],facts:['Unverified suggestion'],unresolved:['Needs evidence'],entities:[],topics:[],files:[],symbols:[]};
 const server=createServer(async(req,res)=>{
  let raw='';for await(const part of req)raw+=part;requests.push(JSON.parse(raw));
  const content=requests.length===1?'SOURCE_ASSISTANT':JSON.stringify({mode:'direct',answer:JSON.stringify(summary)});
  res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({id:'sleep-spy',model:'test/model',choices:[{index:0,message:{role:'assistant',content},finish_reason:'stop'}],usage:{prompt_tokens:3,completion_tokens:3,total_tokens:6}}));
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>new Promise(resolve=>server.close(resolve)));
 const {c,stderr}=await setup(t,`sleep_loopback(${quote(`http://127.0.0.1:${server.address().port}/chat/completions`)})`);
 await c.command('session.turn',{objective:'/sleep'});await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'failed');assert.equal(requests.length,0);
 await c.command('session.turn',{objective:'SOURCE_USER'});await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'complete');
 await c.command('session.turn',{objective:'/sleep'});await until(c,()=>terminal(c),stderr);
 assert.equal(terminal(c),'complete',render(c.view));assert.equal(requests.length,2);
 assert.match(render(c.view),/SYNTHETIC_WARM_PREVIEW/);assert.match(render(c.view),/status:unverified/);
 assert.match(render(c.view),/SOURCE_USER/);assert.match(render(c.view),/SOURCE_ASSISTANT/);
 assert.match(render(c.view),/not_published/);assert.equal(c.view.state.usage.model_calls,1);
 await c.close();await c.connect();await until(c,()=>c.ready,stderr);
 await c.command('session.turn',{objective:'AFTER_SLEEP'});await until(c,()=>terminal(c),stderr);
 assert.doesNotMatch(JSON.stringify(requests[2]),/SYNTHETIC_WARM_PREVIEW|Unverified suggestion/);
});

test('rsi-context measures real project packing without model or adoption',async t=>{
 const {c,stderr}=await setup(t,'context_experiment');
 await c.command('session.turn',{objective:'/rsi-context demo'});await until(c,()=>terminal(c),stderr);
 assert.equal(terminal(c),'complete',render(c.view));assert.match(render(c.view),/delta:9/);
 assert.match(render(c.view),/configured_utility_not_accuracy/);assert.match(render(c.view),/decision:hold/);
 assert.match(render(c.view),/sha256/);assert.equal(c.view.state.usage.model_calls,0);
 await c.command('session.turn',{objective:'/rsi-context'});await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'failed');
});

test('learn selects finite symbolic recipe on discovery and evaluates held-out fixtures',async t=>{
 const {c,stderr}=await setup(t,'learn');
 await c.command('session.turn',{objective:'/learn demo'});await until(c,()=>terminal(c),stderr);
 assert.equal(terminal(c),'complete',render(c.view));assert.match(render(c.view),/primitive:trim_lower/);
 assert.match(render(c.view),/status:evaluated_proposal/);assert.match(render(c.view),/decision:hold/);
 assert.match(render(c.view),/origin_labels_not_independence_proof/);assert.equal(c.view.state.usage.model_calls,0);
 await c.command('session.turn',{objective:'/learn'});await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'failed');
});

for(const command of ['/army','/swarm']) test(`${command} task list runs five distinct jobs on repeated profile`,async t=>{
 const {c,stderr}=await setup(t,'army');
 const tasks=Array.from({length:5},(_,i)=>({id:`job${i}`,profile:'reader',question:`independent question ${i}`}));
 await c.command('session.turn',{objective:`${command} tasks ${JSON.stringify(tasks)}`});
 await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'complete',render(c.view));
 assert.equal(c.view.state.subagents.length,5);assert.equal(c.view.state.usage.model_calls,5);
 if(command==='/swarm')assert.match(render(c.view),/not a swarm/);
});
test('army task list cancellation preserves earlier usage and skips remaining jobs',async t=>{
 const {c,stderr,project}=await setup(t,'army');
 const tasks=[{id:'first',profile:'fast',question:'first task'},{id:'second',profile:'reader',question:'SLOW_CHILD'},{id:'third',profile:'reader',question:'must not start'}];
 await c.command('session.turn',{objective:`/army tasks ${JSON.stringify(tasks)}`});
 await fileAppears(join(project,'child-started'));await c.command('session.cancel');await until(c,()=>terminal(c),stderr);
 assert.equal(terminal(c),'cancelled');assert.equal(c.view.state.subagents.length,2);assert.equal(c.view.state.usage.model_calls,1);
 await new Promise(r=>setTimeout(r,2200));await assert.rejects(access(join(project,'child-finished')));
});

test('configured test runner needs process approval and exposes actual opaque result',async t=>{
 const {c,stderr,project}=await setup(t,'runner');await c.command('session.turn',{objective:'Run configured tests'});
 await until(c,()=>approval(c)||terminal(c),stderr);assert.ok(approval(c),render(c.view));
 await assert.rejects(access(join(project,'runner-started')));
 await c.command('approval.decide',{approval_id:approval(c).id,decision:'allow_once'});
 await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'complete',render(c.view));
 assert.equal(await readFile(join(project,'runner-started'),'utf8'),'started');
 const tool=c.view.state.tools.find(x=>x.name==='workspace_test');assert.equal(tool.output.exit_code,0);assert.equal(tool.output.counts.passed,1);
 assert.match(render(c.view),/Observed test-runner receipt/);
});
test('denied test runner never starts project code',async t=>{
 const {c,stderr,project}=await setup(t,'runner');await c.command('session.turn',{objective:'Run configured tests'});
 await until(c,()=>approval(c)||terminal(c),stderr);assert.ok(approval(c));
 await c.command('approval.decide',{approval_id:approval(c).id,decision:'deny'});
 await until(c,()=>terminal(c),stderr);await assert.rejects(access(join(project,'runner-started')));
});
test('cancelling approved test runner kills process group before late effect',async t=>{
 const {c,stderr,project}=await setup(t,'runner_slow');await c.command('session.turn',{objective:'Run configured tests'});
 await until(c,()=>approval(c)||terminal(c),stderr);assert.ok(approval(c));
 await c.command('approval.decide',{approval_id:approval(c).id,decision:'allow_once'});
 await fileAppears(join(project,'runner-started'));await c.command('session.cancel');await until(c,()=>terminal(c),stderr);
 assert.equal(terminal(c),'cancelled');await new Promise(r=>setTimeout(r,2200));await assert.rejects(access(join(project,'runner-late')));
});

test('composed repair executes failing tests, approved patch, then passing tests',async t=>{
 const {c,stderr,project}=await setup(t,'repair');
 await c.command('session.turn',{objective:'Repair the sum function and verify it'});
 const seen=new Set();
 for(let i=0;i<3;i++) {
  await until(c,()=>approval(c)&&!seen.has(approval(c).id)||terminal(c),stderr);
  const pending=approval(c);assert.ok(pending,render(c.view));seen.add(pending.id);
  if(i<2) assert.match(await readFile(join(project,'sum.mjs'),'utf8'),/a-b/);
  await c.command('approval.decide',{approval_id:pending.id,decision:'allow_once'});
 }
 await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'complete',render(c.view));
 const tests=c.view.state.tools.filter(x=>x.name==='workspace_test'&&x.output);
 assert.equal(tests.length,2);assert.notEqual(tests[0].output.exit_code,0);assert.equal(tests[0].output.counts.failed,1);
 assert.equal(tests[1].output.exit_code,0);assert.equal(tests[1].output.counts.passed,1);
 assert.equal(tests[0].output.evidence_current,true);assert.equal(tests[1].output.evidence_current,true);
 assert.notEqual(tests[0].output.evidence,tests[1].output.evidence);
 assert.match(await readFile(join(project,'sum.mjs'),'utf8'),/a\+b/);
 assert.equal(seen.size,3);assert.match(render(c.view),/Scripted repair completed/);
});

test('projected production SSE streams visible text before completion and preserves history',async t=>{
 const requests=[];let release;
 const server=createServer(async(req,res)=>{
  let raw='';for await(const part of req)raw+=part;requests.push(JSON.parse(raw));
  res.useChunkedEncodingByDefault=false;res.shouldKeepAlive=false;
  res.writeHead(200,{'content-type':'text/event-stream','connection':'close'});
  const chunk=delta=>res.write(`data: ${JSON.stringify({id:'sse',model:'test/model',choices:[{index:0,delta,finish_reason:null}]})}\n\n`);
  chunk({role:'assistant',reasoning:'PRIVATE_STREAM_MARKER'});chunk({content:'Visible first '});
  await new Promise(resolve=>{release=resolve;});
  chunk({content:'second'});
  res.write(`data: ${JSON.stringify({id:'sse',model:'test/model',choices:[{index:0,delta:{},finish_reason:'stop'}],usage:{prompt_tokens:5,completion_tokens:3,total_tokens:8}})}\n\n`);
  res.end('data: [DONE]\n\n');
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{release?.();server.closeAllConnections();server.close();});
 const {c,stderr}=await setup(t,`stream_loopback(${quote(`http://127.0.0.1:${server.address().port}/chat/completions`)})`);
 for(const objective of ['STREAM_FIRST','follow-up']) {
  await c.command('session.turn',{objective});
  await until(c,()=>c.view.state.messages.some(m=>m.role==='assistant'&&m.status==='streaming'&&m.text==='Visible first ')||terminal(c),stderr);
  assert.ok(!terminal(c),render(c.view)+stderr());assert.doesNotMatch(render(c.view),/PRIVATE_STREAM_MARKER/);
  release();await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'complete',render(c.view)+stderr());
  assert.ok(c.view.state.messages.some(m=>m.role==='assistant'&&m.text==='Visible first second'));
  if(objective==='STREAM_FIRST'){await c.close();await c.connect();await until(c,()=>c.ready,stderr);}
 }
 assert.equal(requests.length,2);assert.equal(requests[0].stream,true);
 assert.ok(requests[1].messages.some(m=>m.role==='user'&&m.content==='STREAM_FIRST'));
 assert.ok(requests[1].messages.some(m=>m.role==='assistant'&&m.content==='Visible first second'));
 assert.ok(!requests[1].messages.some(m=>m.role==='system'&&m.content.includes('STREAM_FIRST')));
});

test('projected SSE cancellation stops visible updates across restart',async t=>{
 let response;
 const server=createServer(async(req,res)=>{for await(const _ of req){}response=res;res.useChunkedEncodingByDefault=false;res.shouldKeepAlive=false;res.writeHead(200,{'content-type':'text/event-stream','connection':'close'});res.write('data: {"id":"cancel","model":"test/model","choices":[{"index":0,"delta":{"content":"PARTIAL_ONLY"},"finish_reason":null}]}\n\n');});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{response?.destroy();server.closeAllConnections();server.close();});
 const {c,stderr,state}=await setup(t,`stream_loopback(${quote(`http://127.0.0.1:${server.address().port}/sse`)})`);
 await c.command('session.turn',{objective:'cancel stream'});
 await until(c,()=>c.view.state.messages.some(m=>m.text==='PARTIAL_ONLY')||terminal(c),stderr);assert.ok(!terminal(c),render(c.view));
 await c.command('session.cancel');await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'cancelled');
 response.end('data: {"choices":[{"index":0,"delta":{"content":"LATE_MARKER"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
 await new Promise(r=>setTimeout(r,100));assert.doesNotMatch(render(c.view),/LATE_MARKER/);
 // Canonical transcript may retain partial visible text; history must not add a completed assistant turn.
 await c.close();await c.connect();await until(c,()=>c.ready,stderr);assert.equal(terminal(c),'cancelled');
});

test('explicit image reaches production provider but bytes never enter durable history or receipts',async t=>{
 // Transport boundary fixture, not a decodable full-size picture.
 const bytes=Buffer.alloc(256*1024,65);Buffer.from('89504e470d0a1a0a','hex').copy(bytes);
 const image={name:'max.png',mime:'image/png',data:bytes.toString('base64')};
 const requests=[];const server=createServer(async(req,res)=>{let raw='';for await(const part of req)raw+=part;requests.push(JSON.parse(raw));res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({id:'image',model:'test/model',choices:[{index:0,message:{role:'assistant',content:'IMAGE_ACK'},finish_reason:'stop'}],usage:{prompt_tokens:20,completion_tokens:2,total_tokens:22}}));});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{server.closeAllConnections();server.close();});
 const {c,stderr,state}=await setup(t,`image_loopback(${quote(`http://127.0.0.1:${server.address().port}/chat/completions`)})`);
 assert.ok(c.descriptor.capabilities.includes('image_input'));
 for(const objective of [' /ask echo hello','\u00a0/ask echo hello','\u000b/ask echo hello','\u00a0']){
  await assert.rejects(c.command('session.turn',{objective,images:[image]}),{code:'image_requires_plain_objective'});
 }
 assert.equal(requests.length,0);
 assert.ok(!c.view.state.run);
 const oversized={...image,data:Buffer.concat([bytes,Buffer.from('x')]).toString('base64')};
 await assert.rejects(c.command('session.turn',{objective:'too large',images:[oversized]}));
 assert.equal(requests.length,0);

 await c.command('session.turn',{objective:'Describe my explicit image',images:[image]});await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'complete',render(c.view)+stderr());
 const parts=requests[0].messages.flatMap(m=>Array.isArray(m.content)?m.content:[]);
 assert.equal(parts.find(x=>x.type==='image_url').image_url.url,`data:image/png;base64,${image.data}`);
 assert.ok(requests[0].messages.some(m=>m.role==='user'&&m.content.includes?.('Describe my explicit image')));
 let saved=await readFile(join(state,'session.json'),'utf8');assert.ok(!saved.includes(image.data));assert.ok(saved.includes('payload_digest'));assert.ok(saved.includes('reattach'));
 await assert.rejects(c.command('session.resume'),{code:'reattach_image_before_resume'});
 await c.close();await c.connect();await until(c,()=>c.ready,stderr);
 await c.command('session.turn',{objective:'What did you see?'});await until(c,()=>terminal(c),stderr);assert.equal(terminal(c),'complete',render(c.view));
 assert.ok(!JSON.stringify(requests[1]).includes(image.data));assert.ok(JSON.stringify(requests[1]).includes('reattach'));
 saved=await readFile(join(state,'session.json'),'utf8');assert.ok(!saved.includes(image.data));
});
test('image payload on a session without opt-in is rejected before any model call',async t=>{
 const {c}=await setup(t,'hello');await assert.rejects(c.command('session.turn',{objective:'image',images:[{name:'x.png',mime:'image/png',data:'iVBORw0KGgo='}]}));
 assert.ok(!c.view.state.run);
});
