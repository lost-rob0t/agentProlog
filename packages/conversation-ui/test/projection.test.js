import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { Projection, PROTOCOL } from '../src/projection.js';
import { render, safe } from '../src/render.js';
const frames = readFileSync(new URL('./fixtures/session.ndjson', import.meta.url), 'utf8').trim().split('\n').map(JSON.parse);
const initial = () => { const p = new Projection(); p.snapshot(frames[0]); return p; };
test('canonical golden: all event types, generic tools, usage, uncertain effects', () => {
  const p = initial(); frames.slice(1).forEach(f => p.event(f));
  assert.equal(p.cursor, 24); assert.equal(p.state.messages[0].text, 'I will inspect the authority path.');
  assert.equal(p.state.tools[2].name, 'mystery_linter');
  assert.equal(p.state.approvals[0].status, 'resolved');
  assert.equal(p.state.questions[0].status, 'answered');
  assert.equal(p.state.usage.output_tokens, 340);
  assert.equal(p.state.indeterminate_effects.length, 1);
  assert.match(render(p), /does not establish publication/);
});
test('replay duplicates ignored; gaps and foreign sessions fail atomically', () => {
  const p = initial(); p.event(frames[1]);
  assert.equal(p.event(frames[1]), false);
  assert.throws(() => p.event(frames[3]), { code: 'sequence_gap' });
  assert.throws(() => p.event({ ...frames[2], session_id: 'foreign' }), { code: 'session_mismatch' });
  assert.equal(p.cursor, 1);
});
test('older canonical checkpoint replaces stale view', () => {
  const p = initial(); frames.slice(1).forEach(f => p.event(f));
  p.snapshot(frames[0]); assert.equal(p.cursor, 0); assert.equal(p.state.messages.length, 0);
  frames.slice(1).forEach(f => p.event(f)); assert.equal(p.cursor, 24);
});
test('malformed payload leaves cursor and projection untouched', () => {
  const p = initial(); p.event(frames[1]); p.event(frames[2]);
  assert.throws(() => p.event({ ...frames[3], payload: { message_id: 'msg_1', delta: {} } }), { code: 'invalid_delta' });
  assert.equal(p.cursor, 2); assert.equal(p.state.messages[0].text, '');
});
test('unknown required extensions fail closed', () => {
  const p = initial();
  assert.throws(() => p.event({ ...frames[1], event_type: 'new_authority', extension: { namespace: 'x', required: true } }), { code: 'unsupported_extension' });
});
test('snapshot collections and identifiers bounded', () => {
  const f = structuredClone(frames[0]); f.state.traces = Array(257).fill({});
  assert.throws(() => new Projection().snapshot(f), { code: 'collection_too_large' });
  assert.throws(() => new Projection().snapshot({ ...frames[0], protocol: 'other' }), { code: 'protocol_mismatch' });
});
test('terminal output strips ANSI, OSC and control characters', () => {
  assert.equal(safe('\x1b[31mhello\x1b[0m\x1b]52;c;secret\x07\rworld'), 'helloworld');
});
test('product UI boundary: no research tools, provider SDKs or runtime execution', () => {
  const root = new URL('../src/', import.meta.url);
  const source = readdirSync(root).filter(f => f.endsWith('.js')).map(f => readFileSync(new URL(f, root), 'utf8')).join('\n');
  assert.doesNotMatch(source, /(?:openrouter|openai|anthropic|playwright|puppeteer|scrapy|osint|autodig|fetch\(|execSync\(|shell:\s*true)/i);
  assert.equal(PROTOCOL, 'prolog_agent_ui_v1');
});
