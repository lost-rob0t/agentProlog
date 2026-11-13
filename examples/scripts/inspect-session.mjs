#!/usr/bin/env node
import { checkpoint, connectionHelp, parse, report, session } from './session-options.mjs';

const input = parse(process.argv.slice(2));
if (input === null) {
  console.log(`Usage: node examples/scripts/inspect-session.mjs [options]\n${connectionHelp}
Connect to the canonical native host, print one JSON checkpoint, and close.
Starting a host opens durable state; this is not an offline/read-only file viewer.`);
} else if (input) {
  const client = session(input);
  let signal;
  const interrupt = name => { signal = name; void client.close(); };
  const onInt = () => interrupt('SIGINT'), onTerm = () => interrupt('SIGTERM');
  process.once('SIGINT', onInt); process.once('SIGTERM', onTerm);
  try {
    await client.connect();
    report({ status: 'inspected', descriptor: client.descriptor, ...checkpoint(client) });
  } catch (error) {
    report({ status: signal ? 'cancelled' : 'error', code: signal ?? error.code ?? 'connection_error' },
      signal === 'SIGINT' ? 130 : signal === 'SIGTERM' ? 143 : 1);
  } finally {
    await client.close();
    process.off('SIGINT', onInt); process.off('SIGTERM', onTerm);
  }
}
