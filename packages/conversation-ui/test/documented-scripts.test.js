import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm, chmod } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const script = name => join(root, 'examples/scripts', name);
const transport = fileURLToPath(new URL('./fixtures/transport.mjs', import.meta.url));
const snapshot = JSON.parse((await readFile(new URL('./fixtures/session.ndjson', import.meta.url), 'utf8')).split('\n')[0]);
const cleanEnv = { PATH: process.env.PATH }; // Never pass provider credentials to test children.

function run(command, args, cwd) {
  return new Promise(resolve => {
    execFile(command, args, { cwd, env: cleanEnv, timeout: 8000, killSignal: 'SIGKILL' },
      (error, stdout, stderr) => resolve({ code: error?.code ?? 0, stdout, stderr }));
  });
}

async function workspace(t) {
  const directory = await mkdtemp(join(tmpdir(), 'documented-scripts-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const project = join(directory, 'project with spaces'), config = join(directory, 'operator config.pl');
  await mkdir(project); await writeFile(config, '% Test double never executes this file.\n');
  return { directory, project, config, state: join(directory, 'state'), log: join(directory, 'commands.ndjson') };
}

function nativeArgs(w, prefix) {
  return ['--executable', process.execPath, ...prefix.flatMap(arg => ['--executable-arg', arg]),
    '--project', w.project, '--state', w.state, '--config', w.config, '--request-timeout-ms', '500'];
}

async function mockHost(w) {
  const path = join(w.directory, 'mock host.mjs');
  await writeFile(path, `import { createInterface } from 'node:readline';
import { appendFileSync } from 'node:fs';
const [scenario, log, ...args] = process.argv.slice(2);
const snapshot = ${JSON.stringify(snapshot)};
const send = frame => console.log(JSON.stringify(frame));
appendFileSync(log, JSON.stringify({args, pid: process.pid}) + '\\n');
if (scenario === 'busy') { snapshot.state.status = 'running'; snapshot.state.run = {run_id:'old'}; }
if (scenario === 'previous') { snapshot.state.status = 'finished'; snapshot.state.run = {run_id:'old',outcome:{status:'complete'}}; }
let seq = 0;
const event = (event_type,payload) => send({protocol:snapshot.protocol,session_id:snapshot.session_id,
 kind:'event',seq:++seq,event_id:'event_'+seq,event_type,payload});
const result = f => send({protocol:f.protocol,kind:'result',session_id:snapshot.session_id,
 request_id:f.request_id,status:'ok',payload:{accepted:true}});
createInterface({input:process.stdin}).on('line', line => {
 const f = JSON.parse(line); appendFileSync(log, JSON.stringify(f)+'\\n');
 if (f.kind === 'negotiate') { if (scenario === 'silence') return; result(f); send(snapshot); return; }
 if (f.command === 'session.cancel') {
   if (scenario === 'cancel-silence') return;
   result(f); event('run_finished',{outcome:{status:'cancelled'}}); return;
 }
 if (f.command !== 'session.turn') throw Error('Unexpected command');
 if (scenario === 'rejected') { send({protocol:f.protocol,kind:'error',session_id:snapshot.session_id,
   request_id:f.request_id,code:'permission_denied',message:'rejected by fixture'}); return; }
 event('run_started',{run_id:'new',task:f.payload.objective});
 if (scenario === 'blocked') event('approval_required',{approval_id:'approval',choices:['allow_once','deny']});
 else if (scenario === 'question') event('question_required',{question_id:'question',prompt:'Choose',choices:['a','b']});
 else if (scenario === 'fault') { console.log('{malformed'); return; }
 else if (scenario === 'complete') event('run_finished',{outcome:{status:'complete'}});
  else if (scenario === 'failed') event('run_finished',{outcome:{status:'budget_exceeded'}});
  else if (scenario === 'signal-on-turn') { result(f); process.kill(process.ppid,'SIGINT'); return; }
 result(f);
});
`);
  return path;
}

for (const name of ['inspect-session.mjs', 'submit-task.mjs']) {
  test(`${name}: help needs no runtime; invalid arguments fail before spawn`, async t => {
    const w = await workspace(t);
    const help = await run(process.execPath, [script(name), '--help'], w.directory);
    assert.equal(help.code, 0); assert.match(help.stdout, /--executable/);
    for (const args of [[], ['--json'], ['--executable'], ['--state', 'x', '--state', 'y']]) {
      const output = await run(process.execPath, [script(name), ...args], w.directory);
      assert.equal(output.code, 2); assert.equal(JSON.parse(output.stdout).status, 'invalid_arguments');
    }
  });
}

test('numeric limits, path types, and nonblank objectives are validated', async t => {
  const w = await workspace(t), host = await mockHost(w);
  const base = nativeArgs(w, [host, 'complete', w.log]);
  for (const args of [
    [...base, '--objective', '   '],
    [...base, '--objective', 'test', '--wait-ms', 'NaN'],
    [...base, '--objective', 'test', '--wait-ms', '300001'],
    [...base, '--objective', 'test', '--request-timeout-ms', '0'],
    [...base.filter((_, i) => i < base.length - 2), '--request-timeout-ms', '1.5', '--objective', 'test'],
    [...base, '--objective', 'x'.repeat(16001)],
  ]) {
    const output = await run(process.execPath, [script('submit-task.mjs'), ...args], w.directory);
    assert.equal(output.code, 2, output.stdout); assert.equal(JSON.parse(output.stdout).status, 'invalid_arguments');
  }
  const args = nativeArgs(w, [host, 'complete', w.log]);
  args[args.indexOf('--project') + 1] = w.config;
  const invalid = await run(process.execPath, [script('inspect-session.mjs'), ...args], w.directory);
  assert.equal(invalid.code, 2); assert.match(invalid.stdout, /project must be a directory/);
  await assert.rejects(readFile(w.log), { code: 'ENOENT' });
});

test('inspection uses the real Client against the existing transport fixture from another cwd', async t => {
  const w = await workspace(t);
  const output = await run(process.execPath,
    [script('inspect-session.mjs'), ...nativeArgs(w, [transport, 'duplicate'])], w.directory);
  assert.equal(output.code, 0, output.stderr);
  const value = JSON.parse(output.stdout);
  assert.equal(value.status, 'inspected'); assert.equal(value.session_id, 'fixture_session_1');
  assert.ok(value.at_seq >= 0); assert.equal(value.descriptor.accepted, undefined);
});

for (const [scenario, expected, code] of [
  ['complete', 'finished', 0], ['failed', 'finished', 1], ['blocked', 'blocked', 3],
  ['question', 'blocked', 3], ['previous', 'timeout', 4], ['stall', 'timeout', 4],
  ['busy', 'busy', 3], ['rejected', 'error', 1], ['fault', 'error', 1], ['silence', 'error', 1],
  ['cancel-silence', 'timeout', 4],
  ['signal-on-turn', 'cancelled', 130],
]) {
  test(`task ${scenario}: canonical outcome, exact native arguments, no approvals or retries`, async t => {
    const w = await workspace(t), host = await mockHost(w);
    const output = await run(process.execPath, [script('submit-task.mjs'),
      ...nativeArgs(w, [host, scenario, w.log]), '--objective', 'Inspect only; do not grant authority',
      '--wait-ms', '150'], w.directory);
    assert.equal(output.code, code, output.stderr + output.stdout);
    const value = JSON.parse(output.stdout); assert.equal(value.status, expected);
    const log = (await readFile(w.log, 'utf8')).trim().split('\n').map(JSON.parse);
    assert.deepEqual(log[0].args, [w.state, w.project, '--config', w.config]);
    assert.ok(log.filter(f => f.command === 'session.turn').length <= 1);
    assert.ok(log.every(f => !['approval.decide', 'question.answer', 'session.resume'].includes(f.command)));
    assert.throws(() => process.kill(log[0].pid, 0), { code: 'ESRCH' }, 'sidecar must be closed');
    if (['blocked', 'question', 'previous', 'stall', 'signal-on-turn'].includes(scenario)) {
      assert.equal(value.cancellation, 'acknowledged');
      assert.equal(log.filter(f => f.command === 'session.cancel').length, 1);
    }
    if (scenario === 'blocked') assert.equal(value.approvals[0].id, 'approval');
    if (scenario === 'question') assert.equal(value.questions[0].id, 'question');
    if (scenario === 'busy') assert.equal(log.filter(f => f.command).length, 0);
    if (scenario === 'cancel-silence') assert.equal(value.cancellation, 'unconfirmed');
  });
}

test('SIGINT during cancellation cleanup wins over the earlier timeout outcome', async t => {
  const w = await workspace(t);
  const args = [...nativeArgs(w, []), '--objective', 'Wait for the deadline', '--wait-ms', '1'];
  const code = `import { Client } from ${JSON.stringify(new URL('../src/client.js',import.meta.url).href)};
    Client.prototype.connect = async function () {
      this.connected = true; this.ready = true;
      this.view.state = ${JSON.stringify(snapshot.state)};
    };
    Client.prototype.command = async function (name) {
      if (name === 'session.cancel') process.emit('SIGINT');
      return {payload:{accepted:true}};
    };
    Client.prototype.close = async function () {};
    process.argv = [process.execPath,${JSON.stringify(script('submit-task.mjs'))},...${JSON.stringify(args)}];
    await import(${JSON.stringify(new URL('../../../examples/scripts/submit-task.mjs',import.meta.url).href)});`;
  const output = await run(process.execPath, ['--input-type=module','-e',code],w.directory);
  assert.equal(output.code,130,output.stderr+output.stdout);
  const value=JSON.parse(output.stdout);
  assert.equal(value.status,'cancelled'); assert.equal(value.signal,'SIGINT');
  assert.equal(value.cancellation,'acknowledged');
});

test('shell import wrapper validates inputs, quotes paths, and invokes inert loader, not consult', async t => {
  const w = await workspace(t), path = script('import-and-check-skill.sh');
  const help = await run('bash', [path, '--help'], w.directory);
  assert.equal(help.code, 0); assert.match(help.stdout, /load_skill_units/);
  for (const args of [[], ['--output'], ['--json'], ['--output', 'one', '--output', 'two']]) {
    const output = await run('bash', [path, ...args], w.directory); assert.equal(output.code, 2);
  }
  const importer = join(w.directory, 'mock importer.mjs'), swi = join(w.directory, 'mock swipl.mjs');
  const imported = join(w.directory, "imported ' skill.pl");
  for (const [file, operation] of [[importer, `writeFileSync(process.argv[3], 'inert fixture');`], [swi, '']]) {
    await writeFile(file, `#!${process.execPath}\nimport {appendFileSync,writeFileSync} from 'node:fs';
appendFileSync(${JSON.stringify(w.log)},JSON.stringify(process.argv.slice(2))+'\\n');${operation}\n`);
    await chmod(file, 0o700);
  }
  const args = [path, '--importer', importer, '--swipl', swi, '--source', w.project, '--output', imported];
  const output = await run('bash', args, w.directory); assert.equal(output.code, 0, output.stderr);
  const log = (await readFile(w.log, 'utf8')).trim().split('\n').map(JSON.parse);
  assert.deepEqual(log, [[w.project, imported], ['-q', '-s', script('check-skill.pl'), '--', imported]]);
  const loader = await readFile(script('check-skill.pl'), 'utf8');
  assert.match(loader, /load_skill_units\(\[Path\], \[_\|_\]\)/);
  const again = await run('bash', args, w.directory); assert.equal(again.code, 2);
  assert.equal(await readFile(imported, 'utf8'), 'inert fixture');
});
