import { ProtocolError } from "./errors.js";
import type {
  BridgeCapabilities,
  InboundFrame,
  RequestFrame,
  ResponseFrame,
  RuntimeEventFrame,
} from "./protocol.js";
import { isResponseFrame, validateRequest, validateRuntimeEvent } from "./protocol.js";

interface Pending {
  resolve: (frame: ResponseFrame) => void;
  reject: (error: Error) => void;
  sessionId: string;
}

/**
 * Correlation layer over the NDJSON transport: matches responses to pending
 * requests, rejects non-ok and cancelled statuses, and forwards validated
 * runtime events to the listener.
 */
export class Bridge {
  capabilities: BridgeCapabilities;
  private readonly send: (frame: RequestFrame) => void;
  private readonly pending = new Map<string, Pending>();
  private readonly lastSequence = new Map<string, number>();
  private accepting = true;

  constructor({ send, capabilities = {} }: { send: (frame: RequestFrame) => void; capabilities?: BridgeCapabilities }) {
    this.send = send;
    this.capabilities = capabilities;
  }

  request(frame: RequestFrame): Promise<ResponseFrame> {
    if (!this.accepting) {
      return Promise.reject(new ProtocolError("bridge_disposed", "bridge is not accepting requests"));
    }
    validateRequest(frame, this.capabilities);
    if (this.pending.has(frame.request_id)) {
      return Promise.reject(new ProtocolError("duplicate_request", `duplicate request_id: ${frame.request_id}`));
    }
    return new Promise<ResponseFrame>((resolve, reject) => {
      this.pending.set(frame.request_id, { resolve, reject, sessionId: frame.session_id });
      try {
        this.send(frame);
      } catch (error) {
        this.pending.delete(frame.request_id);
        reject(error instanceof Error ? error : new ProtocolError("bridge_send_failed", String(error)));
      }
    });
  }

  receive(frame: InboundFrame): { type: "event"; value: RuntimeEventFrame } | { type: "response"; value: ResponseFrame } {
    if (isResponseFrame(frame)) return { type: "response", value: this.receiveResponse(frame) };
    const event = validateRuntimeEvent(frame);
    const previous = this.lastSequence.get(event.run_id);
    if (previous !== undefined && event.sequence <= previous) {
      throw new ProtocolError("out_of_order_event", `non-monotonic sequence for run ${event.run_id}`);
    }
    this.lastSequence.set(event.run_id, event.sequence);
    return { type: "event", value: event };
  }

  private receiveResponse(frame: ResponseFrame): ResponseFrame {
    const pending = this.pending.get(frame.request_id);
    if (!pending) throw new ProtocolError("unknown_request", `unknown request_id: ${frame.request_id}`);
    if (frame.session_id !== pending.sessionId) {
      throw new ProtocolError("correlation_mismatch", "response session_id does not match request");
    }
    this.pending.delete(frame.request_id);
    if (frame.status === "ok") {
      pending.resolve(frame);
    } else {
      const error = new ProtocolError(`runtime_${frame.status}`, frame.error?.message ?? frame.status);
      if (typeof frame.error?.code === "string") error.runtimeCode = frame.error.code;
      pending.reject(error);
    }
    return frame;
  }

  dispose(reason = "bridge disposed"): void {
    this.accepting = false;
    const error = new ProtocolError("bridge_disposed", reason);
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
}
