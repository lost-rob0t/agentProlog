// Presentation-only reduction of the public prolog_agent_ui_v1 semantic events.
// Canonical checkpoints always replace this disposable projection on reconnect.
export const PROTOCOL = 'prolog_agent_ui_v1';
export const MAX_BYTES = 1024 * 1024;
const lists = ['messages', 'tools', 'approvals', 'questions', 'subagents',
  'verification', 'traces', 'indeterminate_effects', 'extensions'];
export class ProtocolError extends Error {
  constructor(code, message = code) { super(message); this.code = code; }
}
export function requireValue(ok, code) { if (!ok) throw new ProtocolError(code); }
export const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
export const id = value => typeof value === 'string' && value.length > 0 && value.length <= 200;
const string = value => typeof value === 'string';
function bounded(value) {
  if (Array.isArray(value)) {
    requireValue(value.length <= 256, 'collection_too_large');
    value.forEach(bounded);
  } else if (object(value)) Object.values(value).forEach(bounded);
}
export function validateEnvelope(frame) {
  requireValue(object(frame), 'expected_object');
  requireValue(frame.protocol === PROTOCOL, 'protocol_mismatch');
  requireValue(id(frame.session_id), 'invalid_session_id');
  requireValue(Buffer.byteLength(JSON.stringify(frame)) <= MAX_BYTES, 'frame_too_large');
}
function checkState(state) {
  requireValue(object(state) && string(state.status) && object(state.usage), 'invalid_snapshot_state');
  requireValue(state.run === null || object(state.run), 'invalid_run');
  for (const field of lists) requireValue(Array.isArray(state[field]), `invalid_${field}`);
  for (const field of lists.slice(0, 5)) {
    const seen = new Set();
    for (const item of state[field]) {
      requireValue(object(item) && id(item.id) && !seen.has(item.id), 'invalid_entity');
      seen.add(item.id);
    }
  }
  for (const m of state.messages) requireValue(string(m.text) && string(m.role), 'invalid_message');
  bounded(state);
  requireValue(Buffer.byteLength(JSON.stringify(state)) <= MAX_BYTES, 'snapshot_too_large');
}
function upsert(state, field, item) {
  const i = state[field].findIndex(row => row.id === item.id);
  if (i < 0) state[field].push(item); else state[field][i] = item;
}
function update(state, field, key, fields) {
  const item = state[field].find(row => row.id === key);
  requireValue(item, 'replay_missing_entity');
  Object.assign(item, fields);
}
function append(state, field, item) { state[field] = [...state[field], item].slice(-256); }
export class Projection {
  constructor() { this.sessionId = null; this.cursor = null; this.state = null; }
  snapshot(frame) {
    validateEnvelope(frame);
    requireValue(frame.kind === 'snapshot' && id(frame.snapshot_id), 'invalid_snapshot');
    requireValue(Number.isSafeInteger(frame.at_seq) && frame.at_seq >= 0, 'invalid_cursor');
    checkState(frame.state);
    this.state = structuredClone(frame.state);
    this.sessionId = frame.session_id;
    this.cursor = frame.at_seq;
  }
  event(frame) {
    validateEnvelope(frame);
    requireValue(frame.kind === 'event' && id(frame.event_id) && object(frame.payload), 'invalid_event');
    requireValue(this.state && frame.session_id === this.sessionId, 'session_mismatch');
    requireValue(Number.isSafeInteger(frame.seq) && frame.seq > 0, 'invalid_sequence');
    if (frame.seq <= this.cursor) return false;
    requireValue(frame.seq === this.cursor + 1, 'sequence_gap');
    const s = structuredClone(this.state), p = frame.payload;
    const key = name => { requireValue(id(p[name]), `invalid_${name}`); return p[name]; };
    const field = name => { requireValue(Object.hasOwn(p, name), `missing_${name}`); return p[name]; };
    switch (frame.event_type) {
      case 'run_started': s.status = 'running'; s.run = p; break;
      case 'run_finished': s.status = 'finished'; s.run = { ...s.run, ...p }; break;
      case 'message_started':
        requireValue(string(p.role), 'invalid_role');
        upsert(s, 'messages', { id: key('message_id'), role: p.role, text: '', status: 'streaming' }); break;
      case 'text_delta': {
        requireValue(string(p.delta), 'invalid_delta');
        const m = s.messages.find(row => row.id === key('message_id'));
        requireValue(m, 'replay_missing_entity'); m.text += p.delta; break;
      }
      case 'message_completed': update(s, 'messages', key('message_id'), { status: 'complete' }); break;
      case 'tool_started': upsert(s, 'tools', { ...p, id: key('tool_id'), status: 'running' }); break;
      case 'tool_output': update(s, 'tools', key('tool_id'), { output: field('output') }); break;
      case 'tool_finished': update(s, 'tools', key('tool_id'), { status: 'finished', outcome: field('outcome') }); break;
      case 'approval_required': upsert(s, 'approvals', { ...p, id: key('approval_id'), status: 'pending' }); break;
      case 'approval_resolved': update(s, 'approvals', key('approval_id'), { ...p, status: 'resolved' }); break;
      case 'question_required': upsert(s, 'questions', { ...p, id: key('question_id'), status: 'pending' }); break;
      case 'question_answered': update(s, 'questions', key('question_id'), { ...p, status: 'answered' }); break;
      case 'subagent_started': upsert(s, 'subagents', { ...p, id: key('subagent_id'), status: 'running' }); break;
      case 'subagent_finished': update(s, 'subagents', key('subagent_id'), { ...p, status: 'finished' }); break;
      case 'usage': s.usage = p; break;
      case 'verification': append(s, 'verification', p); break;
      case 'trace': append(s, 'traces', p); break;
      case 'effect_indeterminate': append(s, 'indeterminate_effects', p); break;
      default:
        requireValue(object(frame.extension) && id(frame.extension.namespace) && frame.extension.required === false,
          'unsupported_extension');
        append(s, 'extensions', { event_type: frame.event_type, extension: frame.extension, payload: p });
    }
    checkState(s);
    this.state = s; this.cursor = frame.seq; return true;
  }
}
