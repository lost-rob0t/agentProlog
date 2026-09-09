import { randomUUID } from "node:crypto";

import type { Context } from "@deepseek-ai/cordis";
import { Inbox, agentEvents, type AgentEventDispatch, type AgentOptions } from "@deepseek-ai/dsh-agent";
import { createAssistantMessage } from "@deepseek-ai/dsh-llm";
import { createScope } from "@deepseek-ai/dsh-scope";
import type { AgentCancelCause, Session, SessionId, TurnEndCancelCause, UserMessage } from "@deepseek-ai/dsh-session";

import { executeTurnViaBridge, type AdapterOptions } from "./adapters.js";
import { ProtocolError } from "./errors.js";
import type { Bridge } from "./bridge.js";
import { PROTOCOL_VERSION } from "./protocol.js";
import type { ModeRouter } from "./router.js";

function requestId(prefix: string): string {
  return `${prefix}-${randomUUID()}`;
}

function textFromUserMessage(message: UserMessage): string {
  if (message.role !== "user" || !Array.isArray(message.content)) {
    throw new ProtocolError("invalid_user_message", "AgentProlog requires a DSH user message");
  }
  const text = message.content
    .filter(block => block?.type === "text" && typeof (block as { text?: unknown }).text === "string")
    .map(block => (block as { text: string }).text)
    .join("");
  if (!text.trim()) {
    throw new ProtocolError("unsupported_user_content", "the first AgentProlog slice accepts non-empty text input only");
  }
  return text;
}

function failureRecord(error: unknown): { code: string; message: string } {
  const protocol = error as { code?: unknown };
  return {
    code: typeof protocol?.code === "string" ? protocol.code : "PROLOG_RLM_ERROR",
    message: error instanceof Error ? error.message : String(error),
  };
}

type TurnEndReason =
  | { kind: "completed" }
  | { kind: "aborted"; reason: TurnEndCancelCause }
  | { kind: "error"; error: { code: string; message: string } };

/**
 * DSH Agent whose canonical execution is the Prolog-RLM sidecar. One DSH user
 * turn maps to exactly one canonical Prolog-RLM trajectory; the requested
 * reasoning mode is resolved by the ModeRouter at turn start, so a mode set
 * between turns applies from the next turn without recreating the agent.
 */
export class PrologBackedAgent {
  readonly id: SessionId;
  readonly session: Session;
  readonly inbox: Inbox;
  readonly scope: ReturnType<typeof createScope>;
  readonly ctx: Context;
  readonly options: AgentOptions;
  private readonly dispatch: AgentEventDispatch;
  private readonly bridge: Bridge;
  private readonly router: ModeRouter;
  private readonly turnOptions: AdapterOptions;
  private agentStatus: "idle" | "running" = "idle";
  private lastTurn: number;
  private activity: Promise<void> = Promise.resolve();
  private cancelCause: unknown;

  constructor(
    ctx: Context,
    id: string,
    turnOptions: AdapterOptions | undefined,
    session: Session,
    bridge: Bridge,
    router: ModeRouter,
  ) {
    this.id = id as SessionId;
    this.turnOptions = turnOptions ?? {};
    this.session = session;
    this.bridge = bridge;
    this.router = router;
    this.options = {
      ...(this.turnOptions.provider === undefined ? {} : { provider: this.turnOptions.provider }),
      ...(this.turnOptions.model === undefined || this.turnOptions.model === null ? {} : { model: this.turnOptions.model }),
    };
    this.inbox = new Inbox(session, {
      inserted: message => this.dispatch.emit("agent/inbox/inserted", { message }),
      discarded: message => this.dispatch.emit("agent/inbox/discarded", { message }),
      claimed: (message, turn) => this.dispatch.emit("agent/inbox/claimed", { message, turn }),
    });
    this.scope = createScope(ctx, this);
    this.ctx = this.scope.ctx.extend({ agent: this });
    this.dispatch = agentEvents(ctx, this);
    this.lastTurn = session.snapshotEvents().findLast(event => event.type === "turn/start")?.data?.turn ?? 0;
  }

  get status(): "idle" | "running" {
    return this.agentStatus;
  }

  private setStatus(status: "idle" | "running"): void {
    if (status === this.agentStatus) return;
    this.agentStatus = status;
    this.dispatch.emit("agent/status", { status });
  }

  send(message: UserMessage, target: "next-turn" | "next-step", wakeup: boolean): void {
    if (target !== "next-turn") {
      throw new ProtocolError("unsupported_agent_operation", `AgentProlog does not yet support inbox target ${target}`);
    }
    this.inbox.append("next-turn", message);
    if (wakeup) this.wake();
  }

  followup(message: UserMessage): void {
    this.inbox.append("next-turn", message);
    this.wake();
  }

  steer(message: UserMessage): never {
    throw new ProtocolError("unsupported_agent_operation", `steer is not implemented in the core AgentProlog slice (message ${String(message.id)} rejected)`);
  }

  inject(message: UserMessage): never {
    throw new ProtocolError("unsupported_agent_operation", `inject is not implemented in the core AgentProlog slice (message ${String(message.id)} rejected)`);
  }

  runMaintenance<T>(_task: (signal: AbortSignal) => Promise<T>): Promise<T> {
    return Promise.reject(new ProtocolError("unsupported_agent_operation", "maintenance is not implemented in the core AgentProlog slice"));
  }

  cancel(cause: AgentCancelCause = { kind: "user" }, options: { keepInbox?: boolean } = {}): void {
    this.cancelCause = cause;
    if (!options.keepInbox) this.inbox.clear();
    if (this.status !== "running") return;
    void this.bridge.request({
      version: PROTOCOL_VERSION,
      request_id: requestId("cancel"),
      session_id: this.id,
      operation: "session.cancel",
      payload: { cause },
    }).catch(error => this.dispatch.emit("agent/error", {
      turn: this.lastTurn,
      step: 1,
      error,
    }));
  }

  async whenIdle(): Promise<void> {
    let current: Promise<void>;
    do {
      current = this.activity;
      await current;
    } while (current !== this.activity);
  }

  private wake(): void {
    if (this.status === "running") return;
    this.setStatus("running");
    this.activity = this.drain().finally(() => {
      this.setStatus("idle");
    });
  }

  private async drain(): Promise<void> {
    while (this.inbox.hasPending) {
      const turn = this.lastTurn + 1;
      const claimed = this.inbox.claim("next-turn", turn);
      if (claimed.length !== 1) {
        const error = new ProtocolError(
          "unsupported_message_batch",
          `the core AgentProlog slice requires exactly one user message per turn; got ${claimed.length}`,
        );
        this.dispatch.emit("agent/error", { turn, step: 0, error });
        return;
      }
      await this.runTurn(claimed[0]!, turn);
      this.lastTurn = turn;
    }
  }

  private async runTurn(userMessage: UserMessage, turn: number): Promise<void> {
    const step = 1;
    this.cancelCause = undefined;
    this.session.append("turn/start", { turn });
    this.session.append("step/start", { turn, step });
    this.session.append("user/message", userMessage, { surfaceOp: "append" });

    let reason: TurnEndReason | undefined;
    try {
      const text = textFromUserMessage(userMessage);
      // One authoritative backend decision per turn, resolved from the
      // router's session-scoped mode state.
      const response = await this.router.executeTurn({ sessionId: this.id, text });
      const assistantText = response.text;
      if (typeof assistantText !== "string" || assistantText.length === 0) {
        throw new ProtocolError("invalid_turn_response", "Prolog turn returned no assistant text");
      }
      const assistant = createAssistantMessage({
        content: [{ type: "text", text: assistantText }],
        source: {
          provider: response.provider,
          model: response.model ?? this.turnOptions.model ?? "unknown",
        },
      });
      this.session.append("assistant/message", {
        turn,
        step,
        message: assistant,
        ...(response.usage === undefined ? {} : { usage: response.usage }),
      }, { surfaceOp: "append" });
      reason = { kind: "completed" };
    } catch (error) {
      if (this.cancelCause !== undefined || (error instanceof ProtocolError && error.code === "runtime_cancelled")) {
        reason = {
          kind: "aborted",
          reason: (this.cancelCause ?? { kind: "user" }) as TurnEndCancelCause,
        };
      } else {
        const failure = failureRecord(error);
        reason = { kind: "error", error: failure };
        this.dispatch.emit("agent/error", { turn, step, error });
      }
    } finally {
      this.session.append("step/end", { turn, step });
      this.session.append("turn/end", {
        turn,
        reason:
          reason ??
          { kind: "error", error: { code: "turn_unsettled", message: "turn ended without a settlement reason" } },
      });
    }
  }

  async dispose(): Promise<void> {
    this.cancel({ kind: "disposed" });
    await this.whenIdle();
    this.router.forgetSession(this.id);
    await this.scope.dispose();
  }
}

/**
 * DSH AgentFactory backed by the Prolog-RLM runtime. Exactly one factory is
 * registered per profile; the stock agent-loop must be disabled by the
 * profile patch (AgentRegistry.setFactory fails while it is mounted, which is
 * the intended fail-closed composition guarantee).
 */
export class PrologAgentFactory {
  private readonly ctx: Context;
  private readonly bridge: Bridge;
  private readonly router: ModeRouter;
  private readonly prepareSession: (id: string, options: { seed?: unknown; meta?: Record<string, unknown> }) => Session;
  private readonly turnOptions: AdapterOptions;

  constructor(
    ctx: Context,
    bridge: Bridge,
    router: ModeRouter,
    services: {
      prepareSession: PrologAgentFactory["prepareSession"];
    },
    options: { readonly turn?: AdapterOptions } = {},
  ) {
    this.ctx = ctx;
    this.bridge = bridge;
    this.router = router;
    this.prepareSession = services.prepareSession;
    this.turnOptions = options.turn ?? {};
  }

  async createAgent(ownerCtx: Context, options: {
    sessionId: string;
    seed?: unknown;
    meta?: Record<string, unknown>;
    agentOptions?: { readonly turn?: AdapterOptions };
    setup?: (agentCtx: Context) => Promise<{ commit(): void } | undefined> | { commit(): void } | undefined;
  }): Promise<{ agent: PrologBackedAgent; dispose: () => Promise<void> }> {
    const id = options.sessionId as SessionId;
    if (!id) throw new ProtocolError("session_id_required", "DSH createAgent requires sessionId");

    const session = this.prepareSession(id, {
      ...(options.seed === undefined ? {} : { seed: options.seed }),
      ...(options.meta === undefined ? {} : { meta: options.meta }),
    });
    const turnOptions = options.agentOptions?.turn ?? this.turnOptions;
    const agent = new PrologBackedAgent(this.ctx, id, turnOptions, session, this.bridge, this.router);
    let detachSession: (() => void) | undefined;
    let detachAgent: (() => void) | undefined;
    let disposed: Promise<void> | undefined;

    const dispose = (): Promise<void> => (disposed ??= (async () => {
      try {
        await agent.dispose();
      } finally {
        try {
          detachAgent?.();
        } finally {
          detachSession?.();
        }
      }
    })());

    try {
      const setupCommit = await options.setup?.(agent.ctx);
      setupCommit?.commit();
      await this.bridge.request({
        version: PROTOCOL_VERSION,
        request_id: requestId("session-start"),
        session_id: id,
        operation: "session.start",
        payload: { ...(options.meta?.cwd === undefined ? {} : { cwd: options.meta.cwd }) },
      });

      detachSession = agent.ctx.sessions.enter(session);
      detachAgent = this.ctx.agents.enter(agent, ownerCtx.agent);
      agent.ctx.sessions.announce(session);
      this.ctx.agents.announce(agent);
      ownerCtx.effect(() => () => void dispose(), `agentProlog.lifecycle(${id})`);
      return { agent, dispose };
    } catch (error) {
      await dispose();
      throw error;
    }
  }

  resume(): never {
    throw new ProtocolError("resume_not_implemented", "session resume is outside the core AgentProlog slice");
  }
}
