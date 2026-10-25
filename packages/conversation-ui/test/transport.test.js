import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { Client } from '../src/client.js';
const fixture = fileURLToPath(new URL('./fixtures/transport.mjs', import.meta.url));
for (const scenario of ['gap', 'malformed', 'oversized']) {
  test(`adversarial child ${scenario}: fail closed and terminate`, async t => {
    const c = new Client({ command: process.execPath, args: [fixture, scenario] });
    t.after(() => c.close()); const fault = once(c, 'fault');
    await c.connect(); await fault;
    assert.equal(c.connected, false); assert.equal(c.ready, false);
    assert.throws(() => c.command('session.cancel'), { code: 'snapshot_required' });
  });
}
test('duplicate process events are ignored without losing the next event', async t => {
  const c = new Client({ command: process.execPath, args: [fixture, 'duplicate'] });
  t.after(() => c.close());
  const atTwo = new Promise(resolve => c.on('view', v => { if (v.cursor === 2) resolve(); }));
  await c.connect(); await atTwo;
  assert.equal(c.connected, true); assert.equal(c.view.state.messages.length, 1);
});
test('shutdown escalates when child ignores SIGTERM', async () => {
  const c = new Client({ command: process.execPath, args: [fixture, 'ignore-sigterm'] });
  await c.connect(); const child = c.child; await c.close();
  assert.equal(child.signalCode, 'SIGKILL');
});
test('concurrent connect callers share one child and close supersedes pending startup', async () => {
  const c = new Client({ command: process.execPath, args: [fixture, 'duplicate'] });
  const a = c.connect(), b = c.connect(); assert.equal(a, b);
  await a; const child = c.child; await c.close(); assert.notEqual(child.signalCode, null);
  const pending = c.connect(); await c.close();
  await assert.rejects(pending, { code: 'connection_superseded' });
  assert.equal(c.child, null); assert.equal(c.connected, false);
});
test('negotiation without canonical snapshot times out and terminates child', async t => {
  const script = `require('node:readline').createInterface({input:process.stdin}).on('line',line=>{const f=JSON.parse(line);console.log(JSON.stringify({protocol:f.protocol,kind:'result',session_id:'s',request_id:f.request_id,status:'ok',payload:{}}));});`;
  const c = new Client({ command: process.execPath, args: ['-e', script], timeoutMs: 200 });
  t.after(() => c.close()); const fault = once(c, 'fault'); await c.connect();
  const [error] = await fault; assert.equal(error.code, 'snapshot_timeout'); assert.equal(c.ready, false);
});
