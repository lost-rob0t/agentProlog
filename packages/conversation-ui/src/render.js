// Strip terminal control sequences, including OSC hyperlinks and clipboard escapes.
export function safe(value) {
  return String(value).replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, '')
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '').replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, '');
}
const json = value => safe(JSON.stringify(value, null, 2));
export function render(view, connected = true) {
  if (!view.state) return 'AgentProlog — waiting for a canonical snapshot';
  const s = view.state;
  const lines = [`AgentProlog | ${safe(view.sessionId)} | cursor ${view.cursor}`, 
    `Connection: ${connected ? 'connected' : 'DISCONNECTED — displayed state is stale'}`,
    `Run: ${safe(s.status)} ${json(s.run)}`,
    'A finished chat turn does not establish publication or investigation completion.'];
  for (const m of s.messages) lines.push(`\n${safe(m.role)} [${safe(m.status)}]\n${safe(m.text)}`);
  for (const [label, key] of [['Tools', 'tools'], ['Approvals', 'approvals'], ['Questions', 'questions'],
    ['Subagents', 'subagents'], ['Verification', 'verification'], ['Uncertain effects', 'indeterminate_effects'],
    ['Evidence / artifacts / extensions', 'extensions'], ['Trace references', 'traces']]) {
    if (s[key].length) lines.push(`\n${label}\n${json(s[key])}`);
  }
  lines.push(`\nUsage / budgets\n${json(s.usage)}`);
  return lines.join('\n');
}
