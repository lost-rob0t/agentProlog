import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Client } from '../src/client.js';
import { PROTOCOL } from '../src/projection.js';
const frames = readFileSync(new URL('./fixtures/session.ndjson', import.meta.url), 'utf8').trim().split('\n').map(JSON.parse);
function client(t) {
  const c = new Client({ command: process.execPath, timeoutMs: 30 });
  c.connected = true; c.child = { stdin: { write() {} }, kill() {} };
  t.after(() => { c.fail(new Error('test cleanup')); c.child = null; }); return c;
}
test('negotiation before snapshot; results require matching request and session', async t => {
  const c = client(t), p = c.request({ kind: 'negotiate', payload: {} });
  const request_id = [...c.pending.keys()][0];
  c.receive({ protocol: PROTOCOL, kind: 'result', request_id, session_id: frames[0].session_id, status: 'ok', payload: { protocol: PROTOCOL } });
  await p; c.receive(frames[0]); assert.equal(c.ready, true);
  const request = c.command('session.cancel'); const rid = [...c.pending.keys()][0];
  const reply = { protocol: PROTOCOL, kind: 'result', request_id: rid, session_id: 'wrong', status: 'ok', payload: {} };
  assert.throws(() => c.receive(reply), { code: 'correlation_mismatch' });
  c.receive({ ...reply, session_id: frames[0].session_id }); await request;
});
test('stale approvals and unoffered choices rejected before transmission', t => {
  const c = client(t); c.view.snapshot(frames[0]); c.ready = true;
  frames.slice(1, 11).forEach(f => c.view.event(f));
  assert.throws(() => c.command('approval.decide', { approval_id: 'approval_1', decision: 'arbitrary' }), { code: 'decision_not_offered' });
  c.view.event(frames[11]);
  assert.throws(() => c.command('approval.decide', { approval_id: 'approval_1', decision: 'allow_once' }), { code: 'stale_decision' });
  assert.equal(c.pending.size, 0);
});
test('timeout marks state disconnected and never retries uncertain commands', async t => {
  const c = client(t); let writes = 0; c.child.stdin.write = () => writes++;
  const p = c.request({ kind: 'negotiate' });
  await assert.rejects(p, { code: 'request_timeout' });
  assert.equal(c.connected, false); assert.equal(c.ready, false); assert.equal(writes, 1);
});
test('malformed negotiation keeps request available for fail-closed rejection', async t => {
  const c = client(t), p = c.request({ kind: 'negotiate' });
  const request_id = [...c.pending.keys()][0];
  assert.throws(() => c.receive({ protocol: PROTOCOL, kind: 'result', session_id: 's', request_id, status: 'ok', payload: { protocol: 'wrong' } }), { code: 'negotiation_mismatch' });
  c.fail(new Error('bad negotiation')); await assert.rejects(p, /bad negotiation/);
});
test('missing executable rejects connect and close does not hang', async () => {
  const c = new Client({ command: '/definitely/missing/agentprolog-runtime' });
  await assert.rejects(c.connect(), { code: 'ENOENT' });
  await c.close(); assert.equal(c.connected, false);
});
test('required capabilities must be confirmed by negotiated runtime data', async t => {
  const c = client(t); c.requiredCapabilities = ['approvals'];
  const p = c.request({ kind: 'negotiate' }); const request_id = [...c.pending.keys()][0];
  const reply = { protocol: PROTOCOL, kind: 'result', session_id: 's', request_id, status: 'ok', payload: { capabilities: ['usage'] } };
  assert.throws(() => c.receive(reply), { code: 'required_capability_missing' });
  assert.equal(c.negotiated, undefined);
  c.receive({ ...reply, payload: { capabilities: ['approvals'] } });
  await p; assert.equal(c.negotiated, true);
});
test('synchronous pipe write failure rejects and clears pending mutation', async t => {
  const c = client(t); c.child.stdin.write = () => { throw new Error('broken write'); };
  await assert.rejects(c.request({ kind: 'command', session_id: 's' }), /broken write/);
  assert.equal(c.pending.size, 0); assert.equal(c.connected, false);
});
test('unsolicited canonical errors retain structured runtime failure', t => {
  const c = client(t);
  assert.throws(() => c.receive({ protocol: PROTOCOL, kind: 'error', session_id: 's', code: 'runtime_failed', message: 'Runtime failed', details: {} }), { code: 'runtime_failed' });
});
