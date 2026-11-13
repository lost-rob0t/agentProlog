// Positive checker fixture, never supplied to the model or used as live evidence.
import { createServer as httpServer } from 'node:http';
export function createServer() {
  const todos = new Map(); let next = 0;
  return httpServer(async (req, res) => {
    const send = (status, value) => {
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(value === undefined ? '' : JSON.stringify(value));
    };
    if (req.url === '/') { res.end('<!doctype html><html><input><script>/* /api/todos */</script></html>'); return; }
    const id = req.url.split('/')[3];
    if (req.method === 'GET') { send(200, [...todos.values()]); return; }
    let body;
    try { let data = ''; for await (const chunk of req) data += chunk; body = JSON.parse(data || '{}'); }
    catch { send(400, {}); return; }
    if (req.method !== 'POST' && !todos.has(id)) { send(404, {}); return; }
    if (req.method === 'DELETE') { todos.delete(id); send(204); return; }
    if ((req.method === 'POST' || 'title' in body) && (typeof body.title !== 'string' || !body.title.trim())) { send(400, {}); return; }
    if ('completed' in body && typeof body.completed !== 'boolean') { send(400, {}); return; }
    if (req.method === 'POST') {
      const todo = { id: String(++next), title: body.title, completed: false };
      todos.set(todo.id, todo); send(201, todo);
    } else { Object.assign(todos.get(id), body); send(200, todos.get(id)); }
  });
}
