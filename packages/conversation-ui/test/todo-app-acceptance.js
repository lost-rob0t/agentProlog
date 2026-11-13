// Explicitly opted-in real-model coding acceptance; never runs in default CI.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, access, appendFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { randomUUID } from 'node:crypto';
import { Client } from '../src/client.js';
import { verifyTodoApp } from './todo-app-proof.js';

assert.equal(process.env.AGENTPROLOG_TODO_LIVE, '1', 'Explicit real-model opt-in required');
const provider = process.env.AGENTPROLOG_TODO_PROVIDER;
assert.ok(['openrouter', 'zai_coding'].includes(provider), 'Select an authorized provider explicitly; no fallback');
const credential = provider === 'openrouter' ? 'OPENROUTER_API_KEY' : 'ZAI_API_KEY';
assert.ok(process.env[credential], 'Existing authorized credential required');
const model = process.env.AGENTPROLOG_TODO_MODEL ?? (provider === 'openrouter' ? 'openai/gpt-4.1-mini' : 'glm-5.3-flash');
const runtime = process.env.PROLOG_RLM_SOURCE; assert.ok(runtime);
const targetCost = Number(process.env.AGENTPROLOG_TODO_MAX_COST ?? '0.04');
assert.ok(targetCost > 0 && targetCost <= 0.10);
const repo = fileURLToPath(new URL('../../../', import.meta.url));
const directory = process.env.AGENTPROLOG_TODO_ARTIFACT_DIR
  ? resolve(process.env.AGENTPROLOG_TODO_ARTIFACT_DIR)
  : await mkdtemp('/tmp/opencode/agentprolog-todo-');
const workspace = join(directory, 'workspace'), state = join(directory, `state-${randomUUID()}`);
await mkdir(workspace, { recursive: true }); await mkdir(join(workspace, '.agentprolog'), { recursive: true });
const quote = value => `'${value.replaceAll("'", "''")}'`;
const constructor = provider === 'openrouter'
  ? `rlm_chain:openrouter_provider(${quote(model)},Provider)`
  : `rlm_chain:zai_coding_provider(chat_completions,${quote(model)},Provider)`;
await writeFile(join(workspace, '.agentprolog/config.pl'), `
:- module(todo_acceptance_project,[agentprolog_config/1]).
:- use_module(${quote(join(repo, 'prolog/agentprolog_workspace_tools.pl'))}).
:- use_module(${quote(join(repo, 'prolog/agentprolog_check_tool.pl'))}).
:- use_module(library(rlm_chain),[]).
agentprolog_config(_{profile:todo_app,tools:Tools,
  capabilities:[tool(workspace_read),tool(workspace_create),tool(workspace_write),tool(workspace_check),context(peek)],
  runtime_options:[provider(Provider),provider_name(${provider}),prompt_compile_mode(all_tools),planner_max_tokens(6000)],
  budget:_{max_model_calls:16,max_iterations:24,max_cost_usd:${targetCost},max_total_tokens:65536,max_output_bytes:131072}}) :-
  workspace_tools(${quote(workspace)},FileTools),
  syntax_check_tool(${quote(workspace)},${quote(process.execPath)},Check),append(FileTools,[Check],Tools),${constructor}.
`);
const operatorConfig = join(directory, 'operator.pl');
await writeFile(operatorConfig, `:- module(todo_acceptance_operator,[agentprolog_options/1]).
agentprolog_options([package(${quote(join(repo, 'examples/packs/coding'))}),agent(builder),trusted_project(true),
  allowed_capabilities([tool(workspace_read),tool(workspace_create),tool(workspace_write),tool(workspace_check),context(peek)]),
  budget_ceiling(_{max_model_calls:16,max_iterations:24,max_total_tokens:65536})]).\n`);
const requirements = `Build a dependency-free Node.js HTTP CRUD todo app in one file app.mjs.
Export createServer() returning a node:http Server; importing the module must not listen automatically.
When run as node app.mjs, listen on process.env.PORT or 3000 on 127.0.0.1.
GET / serves a usable HTML todo interface with input, list, add, edit, complete and delete controls.
The browser uses fetch against these real endpoints:
GET /api/todos -> 200 JSON array, initially [];
POST /api/todos {title:string} -> 201 {id, title, completed:false}; unique IDs, reject blank/nonstring titles with 400;
PATCH /api/todos/:id {title?:string,completed?:boolean} -> 200 updated todo, validate values (400), unknown ID (404);
DELETE /api/todos/:id -> 204 empty body, unknown ID -> 404.
Edits/deletes must affect subsequent GET responses and preserve other todos. JSON error responses.
Use an in-memory collection. No external dependencies, network services, secrets or shell commands.
Do not create any other file. The implementation will be started and independently HTTP-tested.
`;
await writeFile(join(workspace, 'requirements.txt'), requirements);
const args = ['-q', '-p', `library=${runtime}/prolog`, '-s', join(repo, 'prolog/agentprolog_session.pl'), '--',
  state, workspace, '--config', operatorConfig];
const client = new Client({ command: process.env.SWIPL ?? 'swipl', args });
let fault, phase = 'connect', timer;
const decisions = new Set(), started = Date.now();
client.on('fault', error => { fault = error.code ?? 'runtime_failure'; });
try {
  const initialObjective =
    'Read requirements.txt with workspace_read and inspect its result context with context_peek. ' +
    'Implement that complete CRUD todo application now by creating app.mjs with workspace_create. ' +
    'Use only the supplied workspace tools. Do not merely describe code or claim tests ran. ' +
    'Read the created app back with workspace_read to confirm the actual file exists. ' +
    'Run workspace_check on app.mjs and inspect its result context; if exit_code is nonzero, repair the source and check again. ' +
    'If needed inspect opaque results with context_peek using selector type item, index 0. ' +
    'Then finish concisely; an independent host will execute the HTTP acceptance tests.';
  const repairObjective = (feedback, sourceHash) =>
    'Repair the existing app.mjs; it already exists, so DO NOT use workspace_create. ' +
    'Read requirements.txt and app.mjs using workspace_read and inspect their result contexts. ' +
    'The original requirements are unchanged and are reproduced here verbatim:\n' + requirements +
    '\nIn particular, app.mjs MUST export createServer() and MUST NOT listen automatically when imported. ' +
    'The node:http import should be aliased if the exported function is also named createServer. ' +
    'An independent verifier observed: ' + feedback.slice(0, 2500) +
    '\nThe independent host observed the current source SHA-256: ' + sourceHash + '. ' +
    'Use workspace_write with this actual expected_sha256 to replace the whole file with the repaired source. Do not use workspace_modify. ' +
    'Avoid nested backticks in the embedded browser script; use ordinary string concatenation where needed. ' +
    'Run workspace_check, inspect its result context, and fix errors until exit_code is 0. ' +
    'Finally read back the file, but do not repeatedly inspect its entire content after every operation. ' +
    'Do not claim the HTTP tests passed; the host will run them.';
  let objective = initialObjective, checks, observedCost = 0, attempts = 0;
  if (await access(join(workspace, 'app.mjs')).then(() => true, () => false)) {
    let feedback = 'The host requested a fresh verification of the existing implementation.';
    try { await verifyTodoApp(workspace); } catch (error) { feedback = error.message; }
    objective = repairObjective(feedback, createHash('sha256').update(await readFile(join(workspace, 'app.mjs'))).digest('hex'));
  }
  for (; attempts < 3; attempts++) {
  fault = undefined;
  await client.connect(); phase = attempts ? 'repair' : 'generation';
  await client.command('session.turn', { objective });
  await new Promise((resolveRun, reject) => {
    let checking = false;
    const check = async () => {
      if (checking) return; checking = true;
      try {
        if (fault) throw new Error(fault);
        for (const a of client.view.state?.approvals ?? []) {
          const decisionKey = `${attempts}:${a.id}`;
          if (a.status !== 'pending' || decisions.has(decisionKey)) continue;
          assert.ok(a.choices.includes('allow_once'));
          assert.equal(a.diff?.operation?.args?.path, 'app.mjs', 'Only the generated app may be mutated');
          decisions.add(decisionKey);
          await client.command('approval.decide', { approval_id: a.id, decision: 'allow_once' });
        }
        const outcome = client.view.state?.run?.outcome;
        if (outcome) {
          await appendFile(join(directory, 'attempts.ndjson'), JSON.stringify({time:new Date().toISOString(),
            status:outcome.status,usage:client.view.state.usage,attempt:attempts+1}) + '\n');
          if (outcome.status !== 'complete') {
            const cost = client.view.state.usage;
            if (cost.cost_known === true) observedCost += cost.cost_usd;
            throw new Error(JSON.stringify({outcome, verification: client.view.state.verification}));
          }
          clearTimeout(timer); client.off('view', check); resolveRun();
        }
      } catch (error) { clearTimeout(timer); client.off('view', check); reject(error); }
      finally { checking = false; }
    };
    timer = setTimeout(() => reject(new Error('todo_generation_timeout')), 150000);
    client.on('view', check); void check();
  });
  const usage = client.view.state.usage;
  assert.equal(usage.cost_known, true, 'Unknown provider cost forbids automatic repair calls');
  observedCost += usage.cost_usd;
  assert.ok(observedCost <= targetCost, 'Cumulative generation/repair target exhausted');
  await client.close(); phase = 'independent_http_verification';
  try { checks = await verifyTodoApp(workspace); break; }
  catch (error) {
    if (attempts === 2 || observedCost > targetCost / 2) throw error;
    objective = repairObjective(error.message, createHash('sha256').update(await readFile(join(workspace, 'app.mjs'))).digest('hex'));
  }
  }
  const route = client.view.state.traces.find(t => t.kind === 'provider_route');
  assert.equal(route?.provider, provider); assert.equal(route?.selected_model, model);
  const tools = client.view.state.tools;
  const create = [...tools].reverse().find(t => ['workspace_create','workspace_write','workspace_modify'].includes(t.name) && t.arguments.path === 'app.mjs');
  assert.equal(create?.outcome?.status, 'ok', 'Actual app creation or repair required');
  const code = await readFile(join(workspace, 'app.mjs'), 'utf8');
  assert.equal(create.output.sha256, createHash('sha256').update(code).digest('hex'));
  assert.ok(tools.some(t => t.name === 'workspace_check' && t.output?.exit_code === 0 && t.outcome?.status === 'ok'));
  assert.ok(tools.some(t => t.name === 'workspace_read' && t.arguments.path === 'app.mjs' && t.outcome?.status === 'ok'));
  // Close the credential-bearing generation process before running generated code.
  const evidence = { status: 'passed', provider: route.provider, selected_model: route.selected_model,
    agent: 'builder', config: 'Prolog', skill: 'build-todo', package: 'agentprolog_coding',
    agent_commit: execFileSync('git', ['-C', repo, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
    runtime_commit: execFileSync('git', ['-C', runtime, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
    app_sha256: createHash('sha256').update(code).digest('hex'),
    elapsed_ms: Date.now() - started, attempts: attempts + 1, observed_cost_usd: observedCost, approvals: decisions.size, checks,
    usage: client.view.state.usage, workspace };
  await writeFile(join(directory, 'evidence.json'), JSON.stringify(evidence, null, 2));
  console.log(JSON.stringify(evidence, null, 2));
} catch (error) {
  // Errors here are local assertion messages or already-sanitized session outcomes,
  // never raw provider payloads. Keep the workspace for diagnosis and bounded repair.
  console.error(JSON.stringify({ status: 'failed', phase, reason: error.message, workspace, elapsed_ms: Date.now() - started }));
  process.exitCode = 1;
} finally { clearTimeout(timer); await client.close(); }
