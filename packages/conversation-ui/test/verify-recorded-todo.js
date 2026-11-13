// Re-run acceptance on the actual model-produced artifact without another paid call.
import assert from 'node:assert/strict';
import { readdir, readFile, stat, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { verifyTodoApp } from './todo-app-proof.js';

const directory = resolve(process.argv[2]);
const candidates = await Promise.all((await readdir(directory)).filter(n => n.startsWith('state'))
  .map(async name => { const path = join(directory, name, 'session.json'); return { path, time: (await stat(path)).mtimeMs }; }));
assert.ok(candidates.length); candidates.sort((a, b) => b.time - a.time);
const state = JSON.parse(await readFile(candidates[0].path, 'utf8'));
assert.equal(state.phase, 'complete');
assert.equal(state.view.run.outcome.status, 'complete');
const route = state.view.traces.find(t => t.kind === 'provider_route');
assert.equal(route?.provider, 'openrouter');
assert.equal(route?.selected_model, 'openai/gpt-4.1-mini');
const mutation = [...state.view.tools].reverse().find(t =>
  ['workspace_create', 'workspace_write', 'workspace_modify'].includes(t.name) && t.arguments.path === 'app.mjs');
assert.equal(mutation?.outcome.status, 'ok');
const workspace = join(directory, 'workspace');
const code = await readFile(join(workspace, 'app.mjs'));
const digest = createHash('sha256').update(code).digest('hex');
assert.equal(mutation.output.sha256, digest, 'The app must still match the actual native mutation observation');
assert.ok(state.view.tools.some(t => t.name === 'workspace_check' && t.output.exit_code === 0 && t.outcome.status === 'ok'));
const checks = await verifyTodoApp(workspace);
const evidence = { status: 'passed', model_io: 'recorded_real_provider_run',
  provider: route.provider, selected_model: route.selected_model, app_sha256: digest,
  generation_config_binding: state.config_binding, generation_usage: state.view.usage,
  checkpoint: candidates[0].path, checked_at: new Date().toISOString(), workspace, checks };
await writeFile(join(directory, 'evidence.json'), JSON.stringify(evidence, null, 2));
console.log(JSON.stringify(evidence, null, 2));
