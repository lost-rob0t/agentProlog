#!/usr/bin/env node
import { checkpoint, connectionHelp, parse, report, session } from './session-options.mjs';

function pending(state) {
  return { approvals: state.approvals.filter(row => row.status === 'pending'),
    questions: state.questions.filter(row => row.status === 'pending') };
}

function watch(client, waitMs, previousRun) {
  let finish;
  const promise = new Promise(resolve => { finish = resolve; });
  const inspect = () => {
    const state = client.view.state, blocked = pending(state);
    if (blocked.approvals.length || blocked.questions.length) finish({ status: 'blocked', ...blocked });
    else if (state.status === 'finished' && state.run?.run_id !== previousRun && state.run?.outcome) {
      finish({ status: 'finished', outcome: state.run.outcome });
    }
  };
  const fault = error => finish({ status: 'error', code: error.code ?? 'transport_error', outcome_uncertain: true });
  client.on('view', inspect); client.on('fault', fault);
  const timer = setTimeout(() => finish({ status: 'timeout', outcome_uncertain: true }), waitMs);
  return { promise, interrupt: signal => finish({ status: 'cancelled', signal, outcome_uncertain: true }),
    dispose() { clearTimeout(timer); client.off('view', inspect); client.off('fault', fault); } };
}

async function cancel(client) {
  if (!client.connected || !client.ready) return 'unavailable';
  let timer;
  try {
    return await Promise.race([
      client.command('session.cancel').then(() => 'acknowledged'),
      new Promise(resolve => { timer = setTimeout(() => resolve('unconfirmed'), 1000); }),
    ]);
  } catch { return 'unconfirmed'; }
  finally { clearTimeout(timer); }
}

const input = parse(process.argv.slice(2), true);
if (input === null) {
  console.log(`Usage: node examples/scripts/submit-task.mjs [options]
${connectionHelp}
  --objective TEXT       One nonblank objective, at most 16000 characters
  --wait-ms N            Wait after connect, 1..300000 (default 30000)
No approval or question is answered. Blocked/deadline/signal outcomes request
cancellation with a 1000ms grace, then close. No automatic mutation retries.`);
} else if (input) {
  const client = session(input);
  let signal, waiter, submitted = false;
  const interrupt = name => {
    signal = name;
    if (waiter) waiter.interrupt(name);
    else void client.close();
  };
  const onInt = () => interrupt('SIGINT'), onTerm = () => interrupt('SIGTERM');
  process.once('SIGINT', onInt); process.once('SIGTERM', onTerm);
  try {
    await client.connect();
    const state = client.view.state, blocked = pending(state);
    if (signal) throw new Error('interrupted');
    if (state.status === 'running' || blocked.approvals.length || blocked.questions.length) {
      report({ status: 'busy', submitted: false, ...blocked, ...checkpoint(client) }, 3);
    } else {
      waiter = watch(client, input.waitMs, state.run?.run_id);
      submitted = true;
      const accepted = client.command('session.turn', { objective: input.objective });
      const outcome = await Promise.race([waiter.promise, accepted.then(() => waiter.promise)]);
      waiter.dispose();
      const observed = checkpoint(client);
      if (['blocked', 'timeout', 'cancelled'].includes(outcome.status)) outcome.cancellation = await cancel(client);
      if (signal) { outcome.status = 'cancelled'; outcome.signal = signal; }
      const code = outcome.status === 'finished' ? (outcome.outcome.status === 'complete' ? 0 : 1)
        : outcome.status === 'blocked' ? 3 : outcome.status === 'timeout' ? 4
          : outcome.status === 'cancelled' ? (outcome.signal === 'SIGINT' ? 130 : 143) : 1;
      report({ ...outcome, submitted, ...observed }, code);
    }
  } catch (error) {
    const cancellation = submitted ? await cancel(client) : 'not_requested';
    report({ status: signal ? 'cancelled' : 'error', code: signal ?? error.code ?? 'session_error',
      submitted, outcome_uncertain: submitted, cancellation, ...checkpoint(client) },
    signal === 'SIGINT' ? 130 : signal === 'SIGTERM' ? 143 : 1);
  } finally {
    waiter?.dispose(); await client.close();
    process.off('SIGINT', onInt); process.off('SIGTERM', onTerm);
  }
}
