import { ProtocolError } from "./errors.js";

/**
 * Wire protocol between the DSH plugin process and the persistent Prolog
 * sidecar. One UTF-8 NDJSON frame per line over the sidecar's stdio.
 *
 * Derived from the merged persistent NDJSON/SWI bridge substrate (PR #3/#8),
 * extended with the canonical reasoning-mode operations.
 */
export const PROTOCOL_VERSION = 1;

const BASE_OPERATIONS: ReadonlySet<string> = new Set([
  "runtime.describe",
  "session.start",
  "session.mode",
  "session.turn",
  "session.cancel",
  "session.inspect",
  "skill.load",
  "skill.list",
  "skill.reset",
]);

const EXPERIMENT_OPERATIONS: ReadonlySet<string> = new Set([
  "experiment.start",
  "experiment.cancel",
  "experiment.inspect",
  "experiment.population",
  "experiment.lineage",
]);

export interface BridgeCapabilities {
  readonly conversation?: boolean;
  readonly cancellation?: boolean;
  readonly agent_factory?: boolean;
  readonly evolution?: boolean;
  readonly modes?: boolean;
  readonly [key: string]: unknown;
}

export interface RequestFrame {
  readonly version: typeof PROTOCOL_VERSION;
  readonly request_id: string;
  readonly session_id: string;
  readonly operation: string;
  readonly payload: Record<string, unknown>;
}

export interface ErrorDetail {
  readonly code?: string;
  readonly message?: string;
  readonly [key: string]: unknown;
}

export interface ResponseFrame {
  readonly version: number;
  readonly request_id: string;
  readonly session_id: string;
  readonly status: "ok" | "error" | "cancelled";
  readonly payload: Record<string, unknown>;
  readonly error?: ErrorDetail;
}

export interface RuntimeEventFrame {
  readonly version: number;
  readonly session_id: string;
  readonly run_id: string;
  readonly event: string;
  readonly sequence: number;
  readonly parent_run_id?: string;
  readonly subagent_run_id?: string;
  readonly [key: string]: unknown;
}

export type InboundFrame = ResponseFrame | RuntimeEventFrame;

export function isResponseFrame(frame: InboundFrame): frame is ResponseFrame {
  return typeof (frame as ResponseFrame).request_id === "string";
}

export class ProtocolValidationError extends ProtocolError {
  constructor(code: string, message: string) {
    super(code, message);
    this.name = "ProtocolValidationError";
  }
}

function requireString(frame: object, key: string): void {
  const value = (frame as Record<string, unknown>)[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new ProtocolValidationError("malformed_frame", `${key} must be a non-empty string`);
  }
}

export function validateRequest(frame: RequestFrame, capabilities: BridgeCapabilities = {}): RequestFrame {
  if (frame === null || typeof frame !== "object" || Array.isArray(frame)) {
    throw new ProtocolValidationError("malformed_frame", "request must be an object");
  }
  if (frame.version !== PROTOCOL_VERSION) {
    throw new ProtocolValidationError("protocol_mismatch", `unsupported protocol version: ${String(frame.version)}`);
  }
  requireString(frame, "request_id");
  requireString(frame, "session_id");
  requireString(frame, "operation");

  if (BASE_OPERATIONS.has(frame.operation)) return frame;
  if (EXPERIMENT_OPERATIONS.has(frame.operation)) {
    if (capabilities.evolution !== true) {
      throw new ProtocolValidationError("capability_unavailable", "evolution API is not available");
    }
    return frame;
  }
  throw new ProtocolValidationError("unknown_operation", `operation is not allow-listed: ${frame.operation}`);
}

export function validateRuntimeEvent(frame: RuntimeEventFrame): RuntimeEventFrame {
  if (frame === null || typeof frame !== "object" || Array.isArray(frame)) {
    throw new ProtocolValidationError("malformed_frame", "event must be an object");
  }
  if (frame.version !== PROTOCOL_VERSION) {
    throw new ProtocolValidationError("protocol_mismatch", `unsupported protocol version: ${String(frame.version)}`);
  }
  requireString(frame, "session_id");
  requireString(frame, "run_id");
  requireString(frame, "event");
  if (!Number.isSafeInteger(frame.sequence) || frame.sequence < 0) {
    throw new ProtocolValidationError("malformed_frame", "sequence must be a non-negative safe integer");
  }
  if (frame.parent_run_id !== undefined && typeof frame.parent_run_id !== "string") {
    throw new ProtocolValidationError("malformed_frame", "parent_run_id must be a string");
  }
  if (frame.subagent_run_id !== undefined && typeof frame.subagent_run_id !== "string") {
    throw new ProtocolValidationError("malformed_frame", "subagent_run_id must be a string");
  }
  return frame;
}
