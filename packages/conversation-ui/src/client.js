import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { StringDecoder } from 'node:string_decoder';
import { MAX_BYTES, PROTOCOL, Projection, ProtocolError, requireValue, object, id, validateEnvelope } from './projection.js';

// No shell, provider, tool executor, or local agent loop. Only canonical frames.
export class Client extends EventEmitter {
  constructor({ command, args = [], timeoutMs = 15000, requiredCapabilities = [] }) {
    super(); this.executable = command; this.args = args; this.timeoutMs = timeoutMs;
    this.requiredCapabilities = requiredCapabilities;
    this.view = new Projection(); this.pending = new Map(); this.connected = false;
    this.ready = false; this.generation = 0; this.descriptor = null;
  }
  connect() {
    if (this.connecting) return this.connecting;
    const closed = this.close();
    const generation = this.generation;
    const attempt = this.connectAfterClose(closed, generation);
    this.connecting = attempt;
    const clear = () => { if (this.connecting === attempt) this.connecting = null; };
    attempt.then(clear, clear);
    return attempt;
  }
  async connectAfterClose(closed, generation) {
    await closed;
    requireValue(generation === this.generation, 'connection_superseded');
    this.ready = false; this.negotiated = false; this.descriptor = null;
    const child = spawn(this.executable, this.args, { stdio: ['pipe', 'pipe', 'pipe'], shell: false });
    this.child = child; this.connected = true;
    let buffer = ''; const decoder = new StringDecoder('utf8');
    const fail = error => { if (generation === this.generation) this.fail(error); };
    child.on('error', fail);
    child.on('exit', (code, signal) => fail(new ProtocolError('disconnected', `Sidecar exited (${signal ?? code}); state is stale. Reconnect for a canonical checkpoint.`)));
    child.stdin.on('error', fail);
    child.stderr.on('data', data => { if (generation === this.generation) this.emit('diagnostic', data.toString().slice(0, 4096)); });
    child.stdout.on('data', data => {
      if (generation !== this.generation || !this.connected) return;
      try {
        buffer += decoder.write(data);
        let newline;
        while (generation === this.generation && this.connected && (newline = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
          requireValue(Buffer.byteLength(line) <= MAX_BYTES, 'frame_too_large');
          requireValue(line.trim(), 'empty_frame');
          this.receive(JSON.parse(line));
        }
        requireValue(Buffer.byteLength(buffer) <= MAX_BYTES, 'frame_too_large');
      } catch (error) { fail(error); }
    });
    const result = await this.request({ kind: 'negotiate', payload: {
      protocol_versions: [PROTOCOL], required_capabilities: this.requiredCapabilities,
      optional_capabilities: [], ...(this.view.cursor === null ? {} : { resume_from: this.view.cursor }),
    } });
    if (!this.ready && generation === this.generation && this.connected) {
      this.snapshotTimer = setTimeout(() => fail(new ProtocolError('snapshot_timeout', 'Runtime negotiated but supplied no canonical snapshot.')), this.timeoutMs);
    }
    return result;
  }
  receive(frame) {
    validateEnvelope(frame);
    if (frame.kind === 'result' || frame.kind === 'error') {
      if (frame.kind === 'error' && frame.request_id === undefined) {
        requireValue(id(frame.code) && typeof frame.message === 'string', 'invalid_error');
        throw new ProtocolError(frame.code, frame.message);
      }
      requireValue(id(frame.request_id), 'invalid_request_id');
      const request = this.pending.get(frame.request_id);
      requireValue(request, 'unknown_request');
      requireValue(!request.sessionId || request.sessionId === frame.session_id, 'correlation_mismatch');
      if (frame.kind === 'result') requireValue(['ok', 'rejected'].includes(frame.status) && object(frame.payload), 'invalid_result');
      else requireValue(id(frame.code) && typeof frame.message === 'string', 'invalid_error');
      if (request.kind === 'negotiate' && frame.kind === 'result' && frame.status === 'ok') {
        requireValue((frame.payload.protocol === undefined || frame.payload.protocol === PROTOCOL), 'negotiation_mismatch');
        const advertised = frame.payload.capabilities ?? frame.payload.required_capabilities ?? [];
        requireValue(Array.isArray(advertised) && advertised.every(id), 'invalid_capabilities');
        requireValue(this.requiredCapabilities.every(capability => advertised.includes(capability)), 'required_capability_missing');
      }
      this.pending.delete(frame.request_id); clearTimeout(request.timer);
      if (frame.kind === 'error' || frame.status === 'rejected') {
        request.reject(new ProtocolError(frame.code ?? frame.payload.code ?? 'rejected', frame.message ?? JSON.stringify(frame.payload)));
      } else {
        if (request.kind === 'negotiate') {
          requireValue((frame.payload.protocol === undefined || frame.payload.protocol === PROTOCOL), 'negotiation_mismatch');
          this.negotiated = true; this.descriptor = frame.payload;
          this.expectedSession = frame.session_id;
        }
        request.resolve(frame);
      }
      this.emit('result', frame); return;
    }
    requireValue(this.negotiated, 'not_negotiated');
    if (frame.kind === 'snapshot') {
      requireValue(frame.session_id === this.expectedSession, 'session_mismatch');
      this.view.snapshot(frame); this.ready = true; clearTimeout(this.snapshotTimer);
    } else if (frame.kind === 'event') {
      requireValue(this.ready, 'snapshot_required');
      if (!this.view.event(frame)) return;
    } else throw new ProtocolError('unexpected_frame');
    this.emit('view', this.view);
  }
  request(frame) {
    requireValue(this.connected, 'disconnected');
    const request_id = randomUUID();
    const wire = JSON.stringify({ protocol: PROTOCOL, ...frame, request_id }) + '\n';
    requireValue(Buffer.byteLength(wire) <= MAX_BYTES, 'frame_too_large');
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        // Outcome may be uncertain: do not retry a mutation automatically.
        this.fail(new ProtocolError('request_timeout', `${frame.kind} timed out; inspect after reconnect before retrying.`));
      }, this.timeoutMs);
      this.pending.set(request_id, { resolve, reject, timer, kind: frame.kind, sessionId: frame.session_id });
      try { this.child.stdin.write(wire); } catch (error) { this.fail(error); }
    });
  }
  command(command, payload = {}) {
    requireValue(this.ready && this.connected, 'snapshot_required');
    requireValue(id(command) && object(payload), 'invalid_command');
    if (command === 'approval.decide' || command === 'question.answer') {
      const approval = command === 'approval.decide';
      const item = this.view.state[approval ? 'approvals' : 'questions'].find(row => row.id === payload[approval ? 'approval_id' : 'question_id']);
      requireValue(item?.status === 'pending', 'stale_decision');
      if (approval) requireValue(Array.isArray(item.choices) && item.choices.includes(payload.decision), 'decision_not_offered');
    }
    return this.request({ kind: 'command', session_id: this.view.sessionId, command, payload });
  }
  fail(error) {
    this.connected = false; this.ready = false; clearTimeout(this.snapshotTimer);
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(error); }
    this.pending.clear(); this.emit('fault', error);
    const child = this.child;
    if (child?.pid && child.exitCode === null && child.signalCode === null) {
      child.kill('SIGTERM');
      const timer = setTimeout(() => child.kill('SIGKILL'), 1000);
      timer.unref(); child.once('exit', () => clearTimeout(timer));
    }
  }
  async close() {
    const child = this.child;
    ++this.generation; this.connected = false; this.ready = false; clearTimeout(this.snapshotTimer);
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(new ProtocolError('disconnected')); }
    this.pending.clear(); this.child = null;
    if (!child || !child.pid || child.exitCode !== null || child.signalCode !== null) return;
    await new Promise(resolve => {
      const timer = setTimeout(() => child.kill('SIGKILL'), 1000);
      child.once('exit', () => { clearTimeout(timer); resolve(); });
      child.once('error', () => { clearTimeout(timer); resolve(); });
      child.kill('SIGTERM');
    });
  }
}
