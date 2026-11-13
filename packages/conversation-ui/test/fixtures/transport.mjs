// Adversarial transport test double; never counted as native runtime evidence.
import { createInterface } from 'node:readline';
import { readFileSync } from 'node:fs';
const frames = readFileSync(new URL('./session.ndjson', import.meta.url), 'utf8').trim().split('\n').map(JSON.parse);
const scenario = process.argv[2];
const send = frame => process.stdout.write(JSON.stringify(frame) + '\n');
if (scenario === 'ignore-sigterm') process.on('SIGTERM', () => {});
createInterface({ input: process.stdin }).on('line', line => {
  const f = JSON.parse(line);
  if (scenario === 'timeout') return;
  if (f.kind === 'negotiate') {
    send({ protocol: f.protocol, kind: 'result', session_id: frames[0].session_id,
      request_id: f.request_id, status: 'ok', payload: { protocol: f.protocol } });
    send(frames[0]); send(frames[1]);
    if (scenario === 'duplicate') { send(frames[1]); send(frames[2]); }
    if (scenario === 'gap') send(frames[3]);
    if (scenario === 'malformed') process.stdout.write('{broken\n');
    if (scenario === 'oversized') process.stdout.write('x'.repeat(1024 * 1024 + 1));
  }
});
