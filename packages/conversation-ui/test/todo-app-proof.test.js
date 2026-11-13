import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, copyFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { verifyTodoApp } from './todo-app-proof.js';

test('a functional server passes actual HTTP CRUD acceptance', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'todo-proof-'));
  try {
    await copyFile(new URL('./fixtures/todo-app.mjs', import.meta.url), join(dir, 'app.mjs'));
    const result = await verifyTodoApp(dir);
    assert.equal(result.create, true); assert.equal(result.update, true); assert.equal(result.delete, true);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('a static mock cannot pass CRUD app acceptance', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'todo-proof-'));
  try {
    await writeFile(join(dir, 'app.mjs'), `import { createServer as server } from 'node:http';
      export function createServer() { return server((q,s) => {s.writeHead(200, {'content-type':'text/html'});
      s.end('<html><input><script>/* /api/todos */</script>');}); }`);
    await assert.rejects(verifyTodoApp(dir));
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('a generated module that cannot start fails closed', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'todo-proof-'));
  try {
    await writeFile(join(dir, 'app.mjs'), 'export const broken = true;');
    await assert.rejects(verifyTodoApp(dir), /todo_app_start_failed/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
