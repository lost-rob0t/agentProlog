import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';

// Independent black-box acceptance. No model messages or claims are consulted.
// Node's permission model denies access outside the workspace and subprocesses.
// This is not an OS sandbox; loopback HTTP remains available for the tests.
export async function verifyTodoApp(workspace) {
  try {
    execFileSync(process.execPath, ['--check', resolve(workspace, 'app.mjs')], {
      cwd: workspace, env: {}, stdio: ['ignore', 'pipe', 'pipe'], timeout: 5000,
    });
  } catch (error) {
    throw new Error(`todo_app_syntax_failed: ${String(error.stderr ?? '').slice(0, 2000)}`);
  }
  const program = `import { pathToFileURL } from 'node:url';
    const { createServer } = await import(pathToFileURL(process.argv[1]));
    const server = createServer(); server.listen(0, '127.0.0.1', () =>
      console.log('AGENTPROLOG_PORT=' + server.address().port));`;
  const child = spawn(process.execPath, ['--permission', `--allow-fs-read=${workspace}`,
    `--allow-fs-write=${workspace}`, '--max-old-space-size=128',
    '--input-type=module', '-e', program, resolve(workspace, 'app.mjs')], {
    cwd: workspace, env: { PATH: process.env.PATH ?? '', HOME: workspace, NODE_ENV: 'test' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stderr = '', output = '';
  child.stderr.on('data', b => { stderr = (stderr + b).slice(-4096); });
  const exit = once(child, 'exit');
  try {
    const port = await new Promise((resolvePort, reject) => {
      const timer = setTimeout(() => reject(new Error('todo_app_start_timeout')), 5000);
      const failed = () => { clearTimeout(timer); reject(new Error(`todo_app_start_failed: ${stderr.slice(-2000)}`)); };
      child.once('error', failed); child.once('exit', failed);
      child.stdout.on('data', b => {
        output = (output + b).slice(-4096);
        const match = output.match(/AGENTPROLOG_PORT=(\d+)/);
        if (match) { clearTimeout(timer); child.off('exit', failed); resolvePort(Number(match[1])); }
      });
    });
    const base = `http://127.0.0.1:${port}`;
    const request = (path, method = 'GET', body) => fetch(base + path, {
      method, headers: { 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(2000),
    });
    const page = await request('/'); assert.equal(page.status, 200);
    const html = await page.text(); assert.match(html, /<html|<!doctype/i);
    assert.match(html, /<input/i); assert.match(html, /<script/i); assert.match(html, /\/api\/todos/);
    const initial = await request('/api/todos'); assert.equal(initial.status, 200);
    assert.deepEqual(await initial.json(), []);
    const title = `todo-${randomUUID()}`;
    const created = await request('/api/todos', 'POST', { title }); assert.equal(created.status, 201);
    const todo = await created.json(); assert.ok(todo.id !== undefined); assert.equal(todo.title, title);
    assert.equal(todo.completed, false);
    const second = await request('/api/todos', 'POST', { title: 'keep me' }); assert.equal(second.status, 201);
    const other = await second.json(); assert.notEqual(String(other.id), String(todo.id));
    const listed = await request('/api/todos'); assert.equal(listed.status, 200);
    const entries = await listed.json(); assert.equal(entries.length, 2);
    assert.ok(entries.some(t => t.id === todo.id && t.title === title));
    const path = `/api/todos/${encodeURIComponent(todo.id)}`;
    const patched = await request(path, 'PATCH', { title: title + '-edited', completed: true });
    assert.equal(patched.status, 200); const updated = await patched.json();
    assert.equal(updated.id, todo.id); assert.equal(updated.title, title + '-edited'); assert.equal(updated.completed, true);
    const afterPatch = await (await request('/api/todos')).json();
    assert.deepEqual(afterPatch.find(t => t.id === todo.id), updated);
    assert.equal((await request('/api/todos', 'POST', { title: '   ' })).status, 400);
    assert.equal((await request(path, 'PATCH', { completed: 'yes' })).status, 400);
    assert.equal((await request('/api/todos/missing', 'PATCH', { completed: true })).status, 404);
    const removed = await request(path, 'DELETE'); assert.equal(removed.status, 204);
    assert.equal((await request(path, 'DELETE')).status, 404);
    const remaining = await (await request('/api/todos')).json();
    assert.deepEqual(remaining, [other]);
    return { html: true, create: true, list: true, update: true, delete: true, validation: true, isolation: true };
  } finally {
    child.kill('SIGKILL'); await exit;
    // Never expose generated-program output to a credential-bearing caller.
    void stderr;
  }
}
