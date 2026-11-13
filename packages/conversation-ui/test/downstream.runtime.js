// Real downstream fixture adapter + native Prolog-RLM. No live providers/tools.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { once } from 'node:events';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { Client } from '../src/client.js';
import { render } from '../src/render.js';
const root = process.env.AGENTPROLOG_HARNESS_ROOT;
const runtime = process.env.PROLOG_RLM_SOURCE;
assert.ok(root && runtime, 'Set AGENTPROLOG_HARNESS_ROOT and PROLOG_RLM_SOURCE to pinned source checkouts');
const pins = JSON.parse(readFileSync(new URL('./integration-pins.json', import.meta.url)));
for (const [path, expected] of [[root, pins.downstream.commit], [runtime, pins.runtime.commit]]) {
  assert.equal(execFileSync('git', ['-C', path, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(), expected, 'Integration source must match recorded immutable pin');
}
async function setup(t) {
  const directory = await mkdtemp(join(tmpdir(), 'agentprolog-downstream-'));
  const client = new Client({ command: process.env.SWIPL ?? 'swipl', args: ['-q', '-p', `library=${runtime}/prolog`,
    '-s', resolve(root, 'tests/support/research_session_fixture.pl'), '--', directory] });
  let diagnostics = '';
  client.on('diagnostic', x => diagnostics += x);
  t.after(async () => { await client.close(); await rm(directory, { recursive: true, force: true }); });
  await client.connect(); await until(client, () => client.ready, () => diagnostics);
  return { client, directory, diagnostics: () => diagnostics };
}
async function until(client, predicate, diagnostics = () => '') {
  if (predicate()) return;
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { cleanup(); reject(new Error(`Downstream timeout\n${render(client.view)}\n${diagnostics()}`)); }, 25000);
    function check() { if (predicate()) { cleanup(); resolve(); } }
    function fail(e) { cleanup(); reject(e); }
    function cleanup() { clearTimeout(timer); client.off('view', check); client.off('fault', fail); }
    client.on('view', check); client.on('fault', fail);
  });
}
const pending = c => c.view.state.approvals.find(a => a.status === 'pending');
const outcome = c => c.view.state.run?.outcome?.status;
async function turn(c, objective, diagnostics) {
  await c.command('session.turn', { objective });
  await until(c, () => pending(c) || outcome(c), diagnostics);
}
test('native turn → typed fixture tool → report, approve, durable reconnect and stale decision', async t => {
  const { client: c, diagnostics } = await setup(t);
  await c.command('session.create'); await c.command('session.select');
  await turn(c, 'synthetic', diagnostics);
  assert.ok(pending(c), `Expected approval, got ${JSON.stringify(c.view.state.run)}\n${diagnostics()}`);
  assert.match(render(c.view), /seven fictional signals/);
  assert.match(render(c.view), /https:\/\/example.invalid\/synthetic-source/);
  const run = c.view.state.run;
  assert.ok(run.run_id && run.investigation_id);
  assert.equal(outcome(c), undefined);
  const approval = pending(c).id;
  await c.command('approval.decide', { approval_id: approval, decision: 'allow_once' });
  await until(c, () => outcome(c) === 'complete');
  assert.equal(c.view.state.run.outcome.published, false);
  const report = c.view.state.traces.find(x => x.kind === 'report');
  assert.ok(report.document); assert.equal(report.document.schemaVersion, '0.10.1');
  assert.equal(report.published, false); assert.match(report.content, /seven fictional signals/);
  console.log(render(c.view));
  const session = c.view.sessionId, cursor = c.view.cursor;
  await c.connect(); await until(c, () => c.ready);
  assert.equal(c.view.sessionId, session); assert.equal(c.view.cursor, cursor);
  assert.equal(outcome(c), 'complete');
  assert.throws(() => c.command('approval.decide', { approval_id: approval, decision: 'allow_once' }), { code: 'stale_decision' });
  await assert.rejects(c.command('publish'), { code: 'unsupported_command' });
});
test('native reject is terminal rejected and creates no accepted report', async t => {
  const { client: c, diagnostics } = await setup(t);
  await turn(c, 'synthetic', diagnostics); assert.ok(pending(c), diagnostics());
  await c.command('approval.decide', { approval_id: pending(c).id, decision: 'deny' });
  await until(c, () => outcome(c) === 'rejected');
  assert.equal(c.view.state.traces.some(x => x.kind === 'report'), false);
});
test('native cancel interrupts tool; crash becomes interrupted; explicit new turn recovers', async t => {
  const { client: c, directory, diagnostics } = await setup(t);
  await c.command('session.turn', { objective: 'cancel' });
  await until(c, () => c.view.state.tools.length > 0, diagnostics);
  await c.command('session.cancel'); await until(c, () => outcome(c) === 'cancelled');
  await assert.rejects(access(join(directory, 'cancel')));
  await c.command('session.turn', { objective: 'crash' });
  await until(c, () => c.view.state.tools.length > 0, diagnostics);
  const fault = once(c, 'fault'); c.child.kill('SIGKILL'); await fault;
  await c.connect(); await until(c, () => c.ready);
  assert.equal(outcome(c), 'interrupted');
  await assert.rejects(access(join(directory, 'crash')));
  await turn(c, 'synthetic', diagnostics); assert.ok(pending(c), diagnostics());
});
test('native budgets, timeout and false completion fail honestly', async t => {
  const { client: c, diagnostics } = await setup(t);
  for (const objective of ['budget', 'timeout', 'false-complete']) {
    await turn(c, objective, diagnostics); assert.equal(outcome(c), 'failed');
    assert.equal(pending(c), undefined); assert.match(render(c.view), /Run outcome: failed/);
  }
});
test('native question answer resumes into canonical approval', async t => {
  const { client: c, diagnostics } = await setup(t);
  await c.command('session.turn', { objective: '' });
  await until(c, () => c.view.state.questions.some(q => q.status === 'pending'), diagnostics);
  const q = c.view.state.questions.find(q => q.status === 'pending');
  await c.command('question.answer', { question_id: q.id, answer: 'synthetic' });
  await until(c, () => pending(c) || outcome(c), diagnostics);
  assert.ok(pending(c), diagnostics());
});
