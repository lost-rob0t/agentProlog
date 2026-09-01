import { describe, expect, it } from "vitest";

import { Context } from "@deepseek-ai/cordis";
import { createUserMessage } from "@deepseek-ai/dsh-llm";

import { PrologAgentFactory } from "../src/agent-factory.js";
import { executeTurnViaBridge } from "../src/adapters.js";
import { Bridge } from "../src/bridge.js";
import { PROTOCOL_VERSION, type RequestFrame } from "../src/protocol.js";
import { ModeRouter } from "../src/router.js";
import { makeFakeSession, type FakeSession } from "./fakes.js";

interface Harness {
  readonly ctx: Context;
  readonly factory: PrologAgentFactory;
  readonly router: ModeRouter;
  readonly sent: RequestFrame[];
  readonly sessions: Map<string, FakeSession>;
  respondTo: (requestId: string, overrides: Partial<{ status: string; text: string; error: { code: string; message: string } }>) => void;
  respondLast: (overrides: Partial<{ status: string; text: string; error: { code: string; message: string } }>) => void;
}

function makeHarness(): Harness {
  const ctx = new Context() as Context;
  // Stand-in DSH service surfaces (registration/lifecycle plumbing only —
  // the behavior under test is the factory/agent/router/sidecar protocol).
  const entered: Array<() => void> = [];
  ctx.provide("agents", {
    enter: () => {
      const remove = () => undefined;
      entered.push(remove);
      return remove;
    },
    announce: () => undefined,
    setFactory: () => () => undefined,
  });
  ctx.provide("sessions", {
    enter: () => () => undefined,
    announce: () => undefined,
  });

  const sent: RequestFrame[] = [];
  const respondTo: Harness["respondTo"] = (requestId, overrides) => {
    bridge.receive({
      version: PROTOCOL_VERSION,
      request_id: requestId,
      session_id: sent.find(frame => frame.request_id === requestId)?.session_id ?? "s1",
      status: (overrides.status ?? "ok") as never,
      payload: { text: overrides.text ?? "symbolic reply" },
      ...(overrides.error === undefined ? {} : { error: overrides.error }),
    } as never);
  };
  const bridge = new Bridge({
    send: frame => {
      sent.push(frame);
      // Lifecycle operations settle immediately, mirroring the real sidecar;
      // turn responses are driven by the tests.
      if (frame.operation === "session.start" || frame.operation === "session.cancel") {
        queueMicrotask(() =>
          respondTo(frame.request_id, {
            text: "unused",
            ...(frame.operation === "session.cancel" ? { error: { code: "cancelled", message: "unused" } } : {}),
          }),
        );
      }
    },
  });
  const sessions = new Map<string, FakeSession>();
  const router = new ModeRouter({
    execute: (request, mode) =>
      // Route through the real adapter so the test exercises the same
      // payload shaping and error classification as production.
      executeTurnViaBridge(bridge, {
        sessionId: request.sessionId,
        text: request.text,
        mode,
        options: {},
      }),
  });
  const factory = new PrologAgentFactory(ctx, bridge, router, {
    prepareSession: (id, options) => {
      const session = makeFakeSession(id);
      session.options = options;
      sessions.set(id, session);
      return session as never;
    },
  });

  return {
    ctx,
    factory,
    router,
    sent,
    sessions,
    respondTo,
    respondLast(overrides) {
      const last = sent[sent.length - 1]!;
      respondTo(last.request_id, overrides);
    },
  };
}

function userMessage(text: string): ReturnType<typeof createUserMessage> {
  return createUserMessage({ content: [{ type: "text", text }], source: { kind: "user" } });
}

function eventTypes(session: FakeSession): string[] {
  return session.events.map(event => event.type);
}

function lastOperation(sent: RequestFrame[]): string {
  return sent[sent.length - 1]!.operation;
}

describe("PrologAgentFactory (mode-aware, headless)", () => {
  it("creates an agent and starts a sidecar session per DSH session", async () => {
    const harness = makeHarness();
    const { agent } = await harness.factory.createAgent(harness.ctx as never, { sessionId: "s1" });
    expect(lastOperation(harness.sent)).toBe("session.start");
    expect(harness.sent[0]).toMatchObject({ operation: "session.start", session_id: "s1" });
    expect(agent.id).toBe("s1");
  });

  it("a direct turn maps one DSH user message to one canonical trajectory", async () => {
    const harness = makeHarness();
    const { agent } = await harness.factory.createAgent(harness.ctx as never, { sessionId: "s1" });
    agent.followup(userMessage("hello directly"));

    const turnRequest = harness.sent.find(frame => frame.operation === "session.turn")!;
    expect(turnRequest.payload).toMatchObject({ mode: "direct", text: "hello directly" });
    harness.respondTo(turnRequest.request_id, { text: "direct answer" });
    await agent.whenIdle();

    const session = harness.sessions.get("s1")!;
    expect(eventTypes(session).filter(type => type !== "agent/inbox/spliced")).toEqual([
      "turn/start",
      "step/start",
      "user/message",
      "assistant/message",
      "step/end",
      "turn/end",
    ]);
    const turnEnd = session.events.at(-1)?.data as { reason: { kind: string } };
    expect(turnEnd.reason.kind).toBe("completed");
  });

  it("the router's session mode selects the backend in the canonical payload", async () => {
    const harness = makeHarness();
    const { agent } = await harness.factory.createAgent(harness.ctx as never, { sessionId: "s1" });
    harness.router.setMode("s1", "symbolic-recursive");

    agent.followup(userMessage("decompose this"));
    const turnRequest = harness.sent.find(frame => frame.operation === "session.turn")!;
    expect(turnRequest.payload).toMatchObject({ mode: "symbolic-recursive" });
    harness.respondTo(turnRequest.request_id, { text: "recursive answer" });
    await agent.whenIdle();
  });

  it("cancellation propagates to the sidecar and settles the turn as aborted", async () => {
    const harness = makeHarness();
    const { agent } = await harness.factory.createAgent(harness.ctx as never, { sessionId: "s1" });

    agent.followup(userMessage("long running"));
    expect(lastOperation(harness.sent)).toBe("session.turn");
    const turnRequestId = harness.sent.find(frame => frame.operation === "session.turn")!.request_id;

    agent.cancel({ kind: "user" });
    expect(lastOperation(harness.sent)).toBe("session.cancel");
    const cancelRequestId = harness.sent.at(-1)!.request_id;
    harness.respondTo(cancelRequestId, { text: "unused" });
    harness.respondTo(turnRequestId, { status: "cancelled", error: { code: "cancelled", message: "cancelled" } });
    await agent.whenIdle();

    const session = harness.sessions.get("s1")!;
    const turnEnd = session.events.at(-1)?.data as { reason: { kind: string } };
    expect(turnEnd.reason.kind).toBe("aborted");
  });

  it("structured turn failures settle as error, never as silent success", async () => {
    const harness = makeHarness();
    const { agent } = await harness.factory.createAgent(harness.ctx as never, { sessionId: "s1" });
    agent.followup(userMessage("this will fail"));
    const turnRequest = harness.sent.find(frame => frame.operation === "session.turn")!;
    harness.respondTo(turnRequest.request_id, {
      status: "error",
      error: { code: "budget_exhausted", message: "iteration ceiling reached" },
    });
    await agent.whenIdle();

    const session = harness.sessions.get("s1")!;
    const turnEnd = session.events.at(-1)?.data as { reason: { kind: string; error?: { code: string } } };
    expect(turnEnd.reason.kind).toBe("error");
    expect(turnEnd.reason.error?.code).toBe("budget_exhausted");
  });

  it("per-agent mode state never leaks between agents", async () => {
    const harness = makeHarness();
    const first = (await harness.factory.createAgent(harness.ctx as never, { sessionId: "s1" })).agent;
    const second = (await harness.factory.createAgent(harness.ctx as never, { sessionId: "s2" })).agent;

    expect(harness.router.resolveMode("s1")).toBe("direct");
    expect(harness.router.resolveMode("s2")).toBe("direct");

    harness.router.setMode("s1", "symbolic");
    expect(harness.router.resolveMode("s2")).toBe("direct");

    first.followup(userMessage("a"));
    harness.respondLast({ text: "ra" });
    await first.whenIdle();
    second.followup(userMessage("b"));
    harness.respondLast({ text: "rb" });
    await second.whenIdle();

    const modes = harness.sent
      .filter(frame => frame.operation === "session.turn")
      .map(frame => frame.payload.mode);
    expect(modes).toEqual(["symbolic", "direct"]);

    await first.dispose();
    expect(harness.router.resolveMode("s1")).toBe("direct");
    expect(harness.router.resolveMode("s2")).toBe("direct");
  });
});
