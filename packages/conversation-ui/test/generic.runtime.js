// Full generic host process with mocked model I/O, real native tools and files.
import test from 'node:test';
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
    ...['workspace_read','workspace_create','workspace_modify','workspace_write'].flatMap(name => ['--allow-tool',name]), '--allow-context', 'peek'];
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
    ...['workspace_read','workspace_create','workspace_modify','workspace_write'].flatMap(name=>['--allow-tool',name]),'--allow-context','peek'];
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
