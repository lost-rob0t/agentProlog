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
