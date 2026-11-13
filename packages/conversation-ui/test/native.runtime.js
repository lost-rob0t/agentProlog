// This lane executes the official SWI-Prolog fixture. It does not claim model,
// tool execution, profile authorization, or publication lifecycle coverage.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { resolve } from 'node:path';
import { Client } from '../src/client.js';
import { PROTOCOL } from '../src/projection.js';
import { render } from '../src/render.js';
const root = process.env.PROLOG_RLM_SOURCE;
assert.ok(root, 'PROLOG_RLM_SOURCE must point to the exact pinned upstream source');
const swipl = process.env.SWIPL ?? 'swipl';
const fixture = resolve(root, 'test/support/prolog_agent_ui_fixture.pl');
// Upstream's hyphenated launcher initializes main/0 but only defines main/1.
// Invoke the official module's exported server loop without changing upstream.
const args = ['-q', '-s', fixture, '-g', 'ui_fixture_server_loop(user_input,user_output)', '-t', 'halt'];
const until = async (client, predicate) => {
  if (predicate()) return;
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { cleanup(); reject(new Error('native fixture timeout')); }, 5000);
    function check() { if (predicate()) { cleanup(); resolve(); } }
    function fail(e) { cleanup(); reject(e); }
    function cleanup() { clearTimeout(timer); client.off('view', check); client.off('fault', fail); }
    client.on('view', check); client.on('fault', fail);
  });
};
test('official native fixture projection equals canonical Prolog snapshot', async t => {
  const c = new Client({ command: swipl, args }); t.after(() => c.close());
  await c.connect(); await until(c, () => c.view.cursor === 24);
  const goal = `use_module('${root}/test/support/prolog_agent_ui_fixture.pl'),use_module(library(http/json)),ui_fixture_snapshot_at(24,S),json_write_dict(current_output,S,[width(0)]),halt`;
  const canonical = JSON.parse(execFileSync(swipl, ['-q', '-g', goal], { encoding: 'utf8' }));
  // Fixture optional extension spelling changed after its golden artifact; the
  // runtime snapshot comparison, rather than the copied golden, is authoritative.
  assert.deepEqual(c.view.state, canonical.state);
  assert.match(render(c.view), /mystery_linter/);
  assert.match(render(c.view), /transport_lost_after_dispatch/);
  console.log(render(c.view));
  const response = await c.command('session.cancel');
  assert.equal(response.payload.accepted, true);
  await until(c, () => c.view.cursor === 25);
  assert.equal(c.view.state.run.outcome, 'cancelled');
});
test('native crash invalidates readiness; reconnect replaces stale canonical state', async t => {
  const c = new Client({ command: swipl, args }); t.after(() => c.close());
  await c.connect(); await until(c, () => c.view.cursor === 24);
  const disconnected = once(c, 'fault'); c.child.kill('SIGKILL'); await disconnected;
  assert.equal(c.ready, false); assert.equal(c.connected, false);
  assert.throws(() => c.command('session.cancel'), { code: 'snapshot_required' });
  assert.match(render(c.view, false), /state is stale/);
  await c.connect(); await until(c, () => c.view.cursor === 24);
  assert.equal(c.connected, true);
  assert.equal(c.view.state.messages[0].text, 'I will inspect the authority path.');
});
test('official fixture rejects malformed wire input with structured error', async () => {
  const output = execFileSync(swipl, args, { input: 'not-json\n', encoding: 'utf8' });
  const frame = JSON.parse(output); assert.equal(frame.kind, 'error'); assert.equal(frame.protocol, PROTOCOL);
});
test('actual executable CLI renders native session and exits cleanly', async () => {
  const child = spawn(process.execPath, [resolve('src/cli.js'), '--sidecar', swipl, ...args.flatMap(x => ['--sidecar-arg', x])]);
  let output = '', error = '', quitting = false;
  child.stderr.on('data', b => error += b);
  child.stdout.on('data', b => {
    output += b;
    if (!quitting && output.includes('cursor 24')) { quitting = true; child.stdin.end('/inspect\n/quit\n'); }
  });
  const timer = setTimeout(() => child.kill('SIGKILL'), 8000);
  const [code] = await once(child, 'exit'); clearTimeout(timer);
  assert.equal(code, 0, error); assert.match(output, /Usage \/ budgets/); assert.match(output, /mystery_linter/);
});
