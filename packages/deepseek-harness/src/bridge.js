import { ProtocolError, validateRequest, validateRuntimeEvent } from "./protocol.js";

export class Bridge {
  constructor({ send, capabilities = {} }) {
    this.send = send;
    this.capabilities = capabilities;
    this.pending = new Map();
    this.lastSequence = new Map();
    this.accepting = true;
  }

  request(frame) {
    if (!this.accepting) {
      return Promise.reject(new ProtocolError("bridge_disposed", "bridge is not accepting requests"));
    }
    validateRequest(frame, this.capabilities);
    if (this.pending.has(frame.request_id)) {
      return Promise.reject(new ProtocolError("duplicate_request", `duplicate request_id: ${frame.request_id}`));
    }
    return new Promise((resolve, reject) => {
      this.pending.set(frame.request_id, { resolve, reject, sessionId: frame.session_id });
      try {
        this.send(frame);
      } catch (error) {
        this.pending.delete(frame.request_id);
        reject(error);
      }
    });
  }

  receive(frame) {
    if (frame?.request_id) return this.#receiveResponse(frame);
    const event = validateRuntimeEvent(frame);
    const previous = this.lastSequence.get(event.run_id);
    if (previous !== undefined && event.sequence <= previous) {
      throw new ProtocolError("out_of_order_event", `non-monotonic sequence for run ${event.run_id}`);
    }
    this.lastSequence.set(event.run_id, event.sequence);
    return { type: "event", value: event };
  }

  #receiveResponse(frame) {
    const pending = this.pending.get(frame.request_id);
    if (!pending) throw new ProtocolError("unknown_request", `unknown request_id: ${frame.request_id}`);
    if (frame.session_id !== pending.sessionId) {
      throw new ProtocolError("correlation_mismatch", "response session_id does not match request");
    }
    this.pending.delete(frame.request_id);
    if (frame.status === "ok") pending.resolve(frame);
    else pending.reject(new ProtocolError(`runtime_${frame.status}`, frame.error?.message ?? frame.status));
    return { type: "response", value: frame };
  }

  dispose(reason = "bridge disposed") {
    this.accepting = false;
    const error = new ProtocolError("bridge_disposed", reason);
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
}
