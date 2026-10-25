// Manual, bounded real-model gate. Never runs as part of unit/default CI tests.
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { Client } from '../src/client.js';

if (process.env.AGENTPROLOG_LIVE_ACCEPTANCE !== '1' || !process.env.ZAI_API_KEY) {
  throw new Error('Live acceptance requires explicit opt-in and existing ZAI_API_KEY. No model call made.');
}
const runtime = process.env.PROLOG_RLM_SOURCE;
assert.ok(runtime, 'PROLOG_RLM_SOURCE must identify the coordinated provider/runtime checkout');
const directory = await mkdtemp(join(tmpdir(), 'agentprolog-live-'));
const workspace = join(directory, 'workspace');
const { mkdir } = await import('node:fs/promises');
await mkdir(workspace);
await writeFile(join(workspace, 'input.txt'), 'Synthetic task marker: ALPHA\n');
const client = new Client({ command: process.env.SWIPL ?? 'swipl', args: ['-q', '-p', `library=${runtime}/prolog`,
  '-s', resolve('test/support/live_workspace_profile.pl'), '--', join(directory, 'state'), workspace] });
const start = Date.now(); let timer, fault;
client.on('fault', error => { fault = error.code ?? 'runtime_failure'; });
// Never print raw provider diagnostics or frames in a credential-bearing job.
try {
  await client.connect();
  await client.command('session.turn', { objective:
    'Use only the supplied workspace tools on synthetic files. Read input.txt and inspect its retained context. '+
    'Create result.txt containing exactly ALPHA. Modify that same file by replacing ALPHA with BETA using workspace_modify and the actual SHA-256. '+
    'Then overwrite that same file with exactly GAMMA using workspace_write and its current SHA-256. Finally read it back and inspect the result context. '+
    'Use context_peek to inspect opaque tool-result references when needed. Do not claim success until all four actual filesystem operations succeeded. '+
    'Do not access any other file or network service. End with a concise statement of the verified final bytes.' });
  const decisions = new Set();
  await new Promise((resolvePromise, reject) => {
    const check = async () => {
      try {
        if (fault) throw new Error(`Runtime disconnected: ${fault}`);
        for (const a of client.view.state?.approvals ?? []) {
          if (a.status === 'pending' && !decisions.has(a.id)) {
            assert.ok(a.choices.includes('allow_once'), 'Runtime approval must offer allow_once');
            decisions.add(a.id);
            // The trusted fixture registry exposes only bounded tools in this temp workspace.
            await client.command('approval.decide', { approval_id: a.id, decision: 'allow_once' });
          }
        }
        const outcome = client.view.state?.run?.outcome?.status;
        if (outcome) {
          assert.equal(outcome, 'complete', `Native acceptance ended ${outcome}`);
          clearTimeout(timer); client.off('view', check); resolvePromise();
        }
      } catch (error) { clearTimeout(timer); client.off('view', check); reject(error); }
    };
    timer = setTimeout(() => reject(new Error('Live acceptance exceeded 150-second outer limit')), 150000);
    client.on('view', check); void check();
  });
  assert.equal(await readFile(join(workspace, 'result.txt'), 'utf8'), 'GAMMA');
  for (const name of ['workspace_read', 'workspace_create', 'workspace_modify', 'workspace_write']) {
    assert.ok(client.view.state.tools.some(t => t.name === name && t.status === 'finished'), `Missing actual tool result: ${name}`);
  }
  const route = client.view.state.traces.find(t => t.kind === 'provider_route');
  const evidence = { status: 'passed', configured_provider: 'zai_coding', requested_model: 'glm-5.3-flash',
    actual_provider: route?.provider ?? null, selected_model: route?.selected_model ?? null,
    agent_commit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
    runtime_commit: execFileSync('git', ['-C', runtime, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
    elapsed_ms: Date.now() - start, usage: Object.fromEntries(Object.entries(client.view.state.usage)
      .filter(([key, value]) => ['input_tokens','output_tokens','prompt_tokens','completion_tokens','total_tokens','cost','cost_usd'].includes(key) && typeof value === 'number')),
    approvals: decisions.size, actual_final_bytes: 'GAMMA', tool_names: [...new Set(client.view.state.tools.map(t => t.name))] };
  console.log(JSON.stringify(evidence, null, 2));
} catch (error) {
  // Deliberately omit raw provider error text or content from authenticated output.
  console.error(JSON.stringify({ status: 'failed', code: error.code ?? 'acceptance_failed', elapsed_ms: Date.now() - start }));
  process.exitCode = 1;
} finally { clearTimeout(timer); await client.close(); await rm(directory, { recursive: true, force: true }); }
