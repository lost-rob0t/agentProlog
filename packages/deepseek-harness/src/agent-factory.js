import { randomUUID } from "node:crypto";
import { Inbox, agentEvents } from "@deepseek-ai/dsh-agent";
import { createAssistantMessage } from "@deepseek-ai/dsh-llm";
import { createScope } from "@deepseek-ai/dsh-scope";
import { PROTOCOL_VERSION, ProtocolError } from "./protocol.js";

function requestId(prefix) {
  return `${prefix}-${randomUUID()}`;
}

function textFromUserMessage(message) {
  if (!message || message.role !== "user" || !Array.isArray(message.content)) {
    throw new ProtocolError("invalid_user_message", "AgentProlog requires a DSH user message");
  }
  const text = message.content
    .filter(block => block?.type === "text" && typeof block.text === "string")
    .map(block => block.text)
    .join("");
  if (!text.trim()) {
    throw new ProtocolError("unsupported_user_content", "the first AgentProlog slice accepts non-empty text input only");
  }
  return text;
}

function failureRecord(error) {
  return {
    code: typeof error?.code === "string" ? error.code : "PROLOG_RLM_ERROR",
    message: error instanceof Error ? error.message : String(error),
  };
}

export class PrologBackedAgent {
  constructor(ctx, id, options, session, bridge) {
    this.id = id;
    this.options = options ?? {};
    this.session = session;
    this.bridge = bridge;
    this.inbox = new Inbox(session, {
      inserted: message => this.dispatch.emit("agent/inbox/inserted", { message }),
      discarded: message => this.dispatch.emit("agent/inbox/discarded", { message }),
      claimed: (message, turn) => this.dispatch.emit("agent/inbox/claimed", { message, turn }),
    });
    this.scope = createScope(ctx, this);
    this.ctx = this.scope.ctx.extend({ agent: this });
    this.dispatch = agentEvents(ctx, this);
    this._status = "idle";
    this._lastTurn = session.events.findLast?.(event => event.type === "turn/start")?.data?.turn ?? 0;
    this._activity = Promise.resolve();
    this._cancelCause = undefined;
  }

  get status() {
    return this._status;
  }

  _setStatus(status) {
    if (status === this._status) return;
    this._status = status;
    this.dispatch.emit("agent/status", { status });
  }

  send(message, target, wakeup) {
    if (target !== "next-turn") {
      throw new ProtocolError("unsupported_agent_operation", `AgentProlog does not yet support inbox target ${target}`);
    }
    this.inbox.splice("next-turn", this.inbox.nextTurn.length, 0, [message]);
    if (wakeup) this._wake();
  }

  followup(message) {
    this.send(message, "next-turn", true);
  }

  steer() {
    throw new ProtocolError("unsupported_agent_operation", "steer is not implemented in the #184 core slice");
  }

  inject() {
    throw new ProtocolError("unsupported_agent_operation", "inject is not implemented in the #184 core slice");
  }

  runMaintenance() {
    return Promise.reject(new ProtocolError("unsupported_agent_operation", "maintenance is not implemented in the #184 core slice"));
  }

  cancel(cause = { kind: "user" }, options = {}) {
    this._cancelCause = cause;
    if (!options.keepInbox) this.inbox.clear();
    if (this.status !== "running") return;
    void this.bridge.request({
      version: PROTOCOL_VERSION,
      request_id: requestId("cancel"),
      session_id: this.id,
      operation: "session.cancel",
      payload: { cause },
    }).catch(error => this.dispatch.emit("agent/error", {
      turn: this._lastTurn,
      step: 1,
      error,
    }));
  }

  async whenIdle() {
    let activity;
    do {
      await (activity = this._activity);
    } while (activity !== this._activity);
  }

  _wake() {
    if (this.status === "running") return;
    this._setStatus("running");
    this._activity = this._drain().finally(() => {
      this._setStatus("idle");
    });
  }

  async _drain() {
    while (this.inbox.hasPending) {
      const turn = this._lastTurn + 1;
      const claimed = this.inbox.claim("next-turn", turn);
      if (claimed.length !== 1) {
        const error = new ProtocolError(
          "unsupported_message_batch",
          `the #184 core slice requires exactly one user message per turn; got ${claimed.length}`,
        );
        this.dispatch.emit("agent/error", { turn, step: 0, error });
        return;
      }
      await this._runTurn(claimed[0], turn);
      this._lastTurn = turn;
    }
  }

  async _runTurn(userMessage, turn) {
    const step = 1;
    this._cancelCause = undefined;
    this.session.append("turn/start", { turn });
    this.session.append("step/start", { turn, step });
    this.session.append("user/message", userMessage, { surfaceOp: "append" });

    let reason;
    try {
      const text = textFromUserMessage(userMessage);
      const response = await this.bridge.request({
        version: PROTOCOL_VERSION,
        request_id: requestId("turn"),
        session_id: this.id,
        operation: "session.turn",
        payload: {
          text,
          provider: this.options.provider ?? "openrouter",
          model: this.options.model ?? null,
        },
      });
      const assistantText = response.payload?.text;
      if (typeof assistantText !== "string" || assistantText.length === 0) {
        throw new ProtocolError("invalid_turn_response", "Prolog turn returned no assistant text");
      }
      const assistant = createAssistantMessage({
        content: [{ type: "text", text: assistantText }],
        source: {
          provider: response.payload?.provider ?? "openrouter",
          model: response.payload?.model ?? this.options.model ?? "unknown",
        },
      });
      this.session.append("assistant/message", {
        turn,
        step,
        message: assistant,
        ...(response.payload?.usage === undefined ? {} : { usage: response.payload.usage }),
      }, { surfaceOp: "append" });
      reason = { kind: "completed" };
    } catch (error) {
      if (this._cancelCause !== undefined || error?.code === "runtime_cancelled") {
        reason = { kind: "aborted", reason: this._cancelCause ?? { kind: "user" } };
      } else {
        const failure = failureRecord(error);
        reason = { kind: "error", error: failure };
        this.dispatch.emit("agent/error", { turn, step, error });
      }
    } finally {
      this.session.append("step/end", { turn, step });
      this.session.append("turn/end", { turn, reason });
    }
  }

  async dispose() {
    this.cancel({ kind: "disposed" });
    await this.whenIdle();
    await this.scope.dispose();
  }
}

export class PrologAgentFactory {
  constructor(ctx, bridge) {
    this.ctx = ctx;
    this.bridge = bridge;
  }

  async createAgent(ownerCtx, options) {
    const id = options.sessionId;
    if (!id) throw new ProtocolError("session_id_required", "DSH createAgent requires sessionId");

    const session = this.ctx.sessions.prepare(id, {
      ...(options.seed === undefined ? {} : { seed: options.seed }),
      ...(options.meta === undefined ? {} : { meta: options.meta }),
    });
    const agent = new PrologBackedAgent(this.ctx, id, options.agentOptions ?? {}, session, this.bridge);
    let detachSession;
    let detachAgent;
    let disposed;

    const dispose = () => (disposed ??= (async () => {
      try {
        await agent.dispose();
      } finally {
        try { detachAgent?.(); }
        finally { detachSession?.(); }
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
      ownerCtx.effect(() => () => dispose(), `agentProlog.lifecycle(${id})`);
      return { agent, dispose };
    } catch (error) {
      await dispose();
      throw error;
    }
  }

  async resume() {
    throw new ProtocolError("resume_not_implemented", "session resume is outside the #184 first core slice");
  }
}
