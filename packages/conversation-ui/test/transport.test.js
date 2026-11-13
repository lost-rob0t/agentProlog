import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { Client } from '../src/client.js';
import { readFileSync } from 'node:fs';
const fixture = fileURLToPath(new URL('./fixtures/transport.mjs', import.meta.url));
for (const scenario of ['gap', 'malformed', 'oversized']) {
  test(`adversarial child ${scenario}: fail closed and terminate`, async t => {
    const c = new Client({ command: process.execPath, args: [fixture, scenario] });
    t.after(() => c.close()); const fault = once(c, 'fault');
    await c.connect().catch(error => assert.ok(error)); await fault;
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
  t.after(() => c.close()); const fault = once(c, 'fault');
  await assert.rejects(c.connect(), { code: 'snapshot_timeout' });
  const [error] = await fault; assert.equal(error.code, 'snapshot_timeout'); assert.equal(c.ready, false);
});

test('connect is not ready until a separately delivered canonical snapshot', async t => {
  const frames = readFileSync(new URL('./fixtures/session.ndjson', import.meta.url), 'utf8').trim().split('\n').map(JSON.parse);
  const snapshot = frames.find(f => f.kind === 'snapshot');
  const script = `const snapshot=${JSON.stringify(snapshot)};
    require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
      const f=JSON.parse(line); if(f.kind==='release') console.log(JSON.stringify(snapshot));
      else console.log(JSON.stringify({protocol:f.protocol,kind:'result',session_id:snapshot.session_id,
        request_id:f.request_id,status:'ok',payload:{}}));});`;
  const c = new Client({ command: process.execPath, args: ['-e', script] });
  t.after(() => c.close()); let settled = false;
  const result = once(c, 'result'); const connecting = c.connect().then(value => { settled = true; return value; });
  await result; await new Promise(setImmediate);
  assert.equal(c.ready, false); assert.equal(settled, false);
  c.child.stdin.write('{"kind":"release"}\n'); await connecting;
  assert.equal(c.ready, true);
});
