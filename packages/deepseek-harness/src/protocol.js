export const PROTOCOL_VERSION = 1;

const BASE_OPERATIONS = new Set([
  "runtime.describe",
  "session.start",
  "session.turn",
  "session.cancel",
  "session.inspect",
]);

const EXPERIMENT_OPERATIONS = new Set([
  "experiment.start",
  "experiment.cancel",
  "experiment.inspect",
  "experiment.population",
  "experiment.lineage",
]);

export class ProtocolError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "ProtocolError";
    this.code = code;
  }
}

function requireString(frame, key) {
  if (typeof frame[key] !== "string" || frame[key].length === 0) {
    throw new ProtocolError("malformed_frame", `${key} must be a non-empty string`);
  }
}

export function validateRequest(frame, capabilities = {}) {
  if (!frame || typeof frame !== "object" || Array.isArray(frame)) {
    throw new ProtocolError("malformed_frame", "request must be an object");
  }
  if (frame.version !== PROTOCOL_VERSION) {
    throw new ProtocolError("protocol_mismatch", `unsupported protocol version: ${frame.version}`);
  }
  requireString(frame, "request_id");
  requireString(frame, "session_id");
  requireString(frame, "operation");

  if (BASE_OPERATIONS.has(frame.operation)) return frame;
  if (EXPERIMENT_OPERATIONS.has(frame.operation)) {
    if (capabilities.evolution !== true) {
      throw new ProtocolError("capability_unavailable", "evolution API is not available");
    }
    return frame;
  }
  throw new ProtocolError("unknown_operation", `operation is not allow-listed: ${frame.operation}`);
}

export function validateRuntimeEvent(frame) {
  if (!frame || typeof frame !== "object" || Array.isArray(frame)) {
    throw new ProtocolError("malformed_frame", "event must be an object");
  }
  if (frame.version !== PROTOCOL_VERSION) {
    throw new ProtocolError("protocol_mismatch", `unsupported protocol version: ${frame.version}`);
  }
  requireString(frame, "session_id");
  requireString(frame, "run_id");
  requireString(frame, "event");
  if (!Number.isSafeInteger(frame.sequence) || frame.sequence < 0) {
    throw new ProtocolError("malformed_frame", "sequence must be a non-negative safe integer");
  }
  if (frame.parent_run_id !== undefined && typeof frame.parent_run_id !== "string") {
    throw new ProtocolError("malformed_frame", "parent_run_id must be a string");
  }
  if (frame.subagent_run_id !== undefined && typeof frame.subagent_run_id !== "string") {
    throw new ProtocolError("malformed_frame", "subagent_run_id must be a string");
  }
  return frame;
}
