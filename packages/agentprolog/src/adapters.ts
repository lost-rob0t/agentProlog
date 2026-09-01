import { ProtocolError } from "./errors.js";
import type { AgentPrologMode } from "./modes.js";
import type { Bridge } from "./bridge.js";
import { PROTOCOL_VERSION, type ResponseFrame } from "./protocol.js";
import type { TurnOutcome } from "./router.js";
import type { TokenUsage } from "@deepseek-ai/dsh-llm";

export interface AdapterOptions {
  readonly provider?: string;
  readonly model?: string | null;
  /** Explicit recursion ceiling for symbolic-recursive turns (>= 1). */
  readonly maxRecursionDepth?: number;
}

export interface TurnExecution {
  readonly sessionId: string;
  readonly text: string;
  readonly mode: AgentPrologMode;
  readonly options: AdapterOptions;
}

let requestCounter = 0;

function requestId(prefix: string): string {
  requestCounter += 1;
  return `${prefix}-${Date.now().toString(36)}-${requestCounter}`;
}

/**
 * Mode adapters: the typed boundary between agentProlog and the Prolog-RLM
 * sidecar. Each adapter shapes the canonical turn request for one reasoning
 * mode and classifies the structured failure modes; none of them scrape
 * terminal output or invent their own execution loop. Recursion ceilings,
 * budgets, and iteration caps are owned by the Prolog runtime and enforced
 * there; the adapter only forwards explicit ceilings and classifies replies.
 */
export async function executeTurnViaBridge(
  bridge: Bridge,
  execution: TurnExecution,
): Promise<TurnOutcome> {
  const payload: Record<string, unknown> = {
    text: execution.text,
    mode: execution.mode,
  };
  if (execution.options.provider !== undefined) payload.provider = execution.options.provider;
  if (execution.options.model !== undefined) payload.model = execution.options.model;
  if (execution.mode === "symbolic-recursive") {
    const depth = execution.options.maxRecursionDepth;
    if (depth !== undefined && (!Number.isSafeInteger(depth) || depth < 1)) {
      throw new ProtocolError("invalid_recursion_depth", "maxRecursionDepth must be a positive integer");
    }
    if (depth !== undefined) payload.max_recursion_depth = depth;
  }

  let response: ResponseFrame;
  try {
    response = (await bridge.request({
      version: PROTOCOL_VERSION,
      request_id: requestId("turn"),
      session_id: execution.sessionId,
      operation: "session.turn",
      payload,
    })) as unknown as ResponseFrame;
  } catch (error) {
    if (error instanceof ProtocolError && error.code === "runtime_cancelled") throw error;
    throw new TurnExecutionError(error instanceof ProtocolError ? error : new ProtocolError("turn_failed", String(error)));
  }
  return outcomeFromResponse(response, execution.mode);
}

function outcomeFromResponse(response: ResponseFrame, mode: AgentPrologMode): TurnOutcome {
  if (response.status !== "ok") {
    throw new TurnExecutionError(
      new ProtocolError(
        response.status === "cancelled" ? "runtime_cancelled" : `runtime_${response.status}`,
        response.error?.message ?? response.status,
      ),
    );
  }
  const payload = response.payload ?? {};
  const text = payload.text;
  if (typeof text !== "string" || text.length === 0) {
    throw new TurnExecutionError(new ProtocolError("invalid_turn_response", "Prolog turn returned no assistant text"));
  }
  const provider = typeof payload.provider === "string" ? payload.provider : "unknown";
  const model = typeof payload.model === "string" ? payload.model : null;
  const usage = isRecord(payload.usage) ? (payload.usage as unknown as TokenUsage) : undefined;
  const meta = isRecord(payload.meta) ? payload.meta : undefined;
  return { text, provider, model, usage, mode, meta };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Structured turn failure carrying the bridge-level error as cause. */
export class TurnExecutionError extends ProtocolError {
  readonly cause: ProtocolError;

  constructor(cause: ProtocolError) {
    super(cause.runtimeCode ?? cause.code, cause.message);
    this.name = "TurnExecutionError";
    this.cause = cause;
  }
}
