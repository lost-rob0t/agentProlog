import { ProtocolError } from "./errors.js";
import { DEFAULT_MODE, parseMode, type AgentPrologMode } from "./modes.js";
import type { TokenUsage } from "@deepseek-ai/dsh-llm";

export interface TurnRequest {
  readonly sessionId: string;
  readonly text: string;
}

export interface TurnOutcome {
  readonly text: string;
  readonly provider: string;
  readonly model: string | null;
  readonly usage?: TokenUsage;
  readonly meta?: Record<string, unknown>;
  readonly mode: AgentPrologMode;
}

export interface ModeChangeEvent {
  readonly sessionId: string;
  readonly from: AgentPrologMode;
  readonly to: AgentPrologMode;
}

export interface TurnRecord {
  readonly sessionId: string;
  readonly mode: AgentPrologMode;
  readonly backend: "direct" | "symbolic" | "symbolic-recursive";
  readonly durationMs: number;
  readonly cancelled: boolean;
  readonly error?: string;
}

export interface ModeRouterOptions {
  readonly defaultMode?: AgentPrologMode;
  readonly onModeChange?: (event: ModeChangeEvent) => void;
  readonly onTurnSettled?: (record: TurnRecord) => void;
  readonly execute: (request: TurnRequest, mode: AgentPrologMode) => Promise<TurnOutcome>;
}

/**
 * The ONE authoritative mode router.
 *
 * Owns per-session mode state and is the single place that decides which
 * execution backend handles a turn. The instance is owned by the plugin
 * (one per composed profile); state is keyed by session id, so concurrent
 * sessions never leak modes into each other. There is deliberately no
 * process-global singleton.
 */
export class ModeRouter {
  private readonly modes = new Map<string, AgentPrologMode>();
  private readonly defaultMode: AgentPrologMode;
  private readonly onModeChange: ((event: ModeChangeEvent) => void) | undefined;
  private readonly onTurnSettled: ((record: TurnRecord) => void) | undefined;
  private readonly executeFn: (request: TurnRequest, mode: AgentPrologMode) => Promise<TurnOutcome>;

  constructor(options: ModeRouterOptions) {
    this.defaultMode = options.defaultMode ?? DEFAULT_MODE;
    this.onModeChange = options.onModeChange;
    this.onTurnSettled = options.onTurnSettled;
    this.executeFn = options.execute;
  }

  /** Effective mode for a session (explicit selection or the default). */
  resolveMode(sessionId: string): AgentPrologMode {
    if (typeof sessionId !== "string" || sessionId.length === 0) {
      throw new ProtocolError("malformed_frame", "sessionId must be a non-empty string");
    }
    return this.modes.get(sessionId) ?? this.defaultMode;
  }

  /** Alias kept for readability at call sites that only inspect. */
  currentMode(sessionId: string): AgentPrologMode {
    return this.resolveMode(sessionId);
  }

  /**
   * Set the mode for exactly one session. Validates through the closed mode
   * set; unknown values are rejected, never coerced.
   */
  setMode(sessionId: string, mode: AgentPrologMode): AgentPrologMode {
    const parsed = parseMode(mode);
    if (typeof sessionId !== "string" || sessionId.length === 0) {
      throw new ProtocolError("malformed_frame", "sessionId must be a non-empty string");
    }
    const previous = this.resolveMode(sessionId);
    this.modes.set(sessionId, parsed);
    if (previous !== parsed) {
      this.onModeChange?.({ sessionId, from: previous, to: parsed });
    }
    return parsed;
  }

  /** Execute one turn through the backend selected by the session's mode. */
  async executeTurn(request: TurnRequest): Promise<TurnOutcome> {
    if (typeof request.text !== "string" || request.text.trim().length === 0) {
      throw new ProtocolError("malformed_frame", "turn text must be a non-empty string");
    }
    const mode = this.resolveMode(request.sessionId);
    const startedAt = Date.now();
    try {
      const outcome = await this.executeFn(request, mode);
      this.onTurnSettled?.({
        sessionId: request.sessionId,
        mode,
        backend: mode,
        durationMs: Date.now() - startedAt,
        cancelled: false,
      });
      return outcome;
    } catch (error) {
      const cancelled = error instanceof ProtocolError && error.code === "runtime_cancelled";
      this.onTurnSettled?.({
        sessionId: request.sessionId,
        mode,
        backend: mode,
        durationMs: Date.now() - startedAt,
        cancelled,
        error: error instanceof Error ? error.message : String(error),
      });
      throw error;
    }
  }

  /** Drop per-session mode state (called on agent disposal). */
  forgetSession(sessionId: string): void {
    this.modes.delete(sessionId);
  }
}
