import { PassThrough, Writable } from "node:stream";

import { describe, expect, it } from "vitest";

import { Bridge, executeTurnViaBridge, ModeRouter, PROTOCOL_VERSION, type RequestFrame } from "@agentprolog/dsh";
import { App } from "../src/app.js";

interface Harness {
  readonly app: App;
  readonly output: { text: string };
  readonly sent: RequestFrame[];
  readonly stopped: string[];
  respondTo: (requestId: string, overrides: Partial<{ status: string; text: string; skills: Array<{ name: string; description: string }>; error: { code: string; message: string } }>) => void;
  respondLast: (overrides?: Partial<{ status: string; text: string; skills: Array<{ name: string; description: string }>; error: { code: string; message: string } }>) => void;
  quit: Promise<void>;
}

function makeHarness(): Harness {
  const sent: RequestFrame[] = [];
  const stopped: string[] = [];
  const outputBuffer = { text: "" };

  const respondTo: Harness["respondTo"] = (requestId, overrides) => {
    const payload: Record<string, unknown> =
      overrides.skills !== undefined
        ? { skills: overrides.skills }
        : overrides.status === undefined || overrides.status === "ok"
          ? { text: overrides.text ?? "symbolic reply" }
          : {};
    bridge.receive({
      version: PROTOCOL_VERSION,
      request_id: requestId,
      session_id: sent.find(frame => frame.request_id === requestId)?.session_id ?? "s1",
      status: (overrides.status ?? "ok") as never,
      payload,
      ...(overrides.error === undefined ? {} : { error: overrides.error }),
    } as never);
  };

  const bridge = new Bridge({
    send: frame => {
      sent.push(frame);
      // Lifecycle operations settle immediately, mirroring the sidecar; turns
      // and skill listings are test-driven through respondTo/respondLast.
      if (frame.operation === "session.start" || frame.operation === "session.cancel") {
        queueMicrotask(() => respondTo(frame.request_id, { text: "unused" }));
      }
    },
  });

  const output = new Writable({
    write(chunk: unknown, _encoding, callback) {
      outputBuffer.text += String(chunk);
      callback();
    },
  });

  const respondLast: Harness["respondLast"] = (overrides = {}) => {
    respondTo(sent[sent.length - 1]!.request_id, overrides);
  };

  const router = new ModeRouter({
    execute: (request, mode) =>
      // Exercise the real adapter so error classification matches production.
      executeTurnViaBridge(bridge, {
        sessionId: request.sessionId,
        text: request.text,
        mode,
        options: {},
      }),
  });

  let quitResolve: () => void = () => undefined;
  const quit = new Promise<void>(resolve => {
    quitResolve = resolve;
  });

  const app = new App({
    sessionId: "s1",
    transport: {
      request: frame => bridge.request(frame) as unknown as Promise<Record<string, unknown>>,
      activeBridge: bridge,
      stop: reason => {
        stopped.push(reason ?? "");
        return Promise.resolve();
      },
    },
    router,
    input: new PassThrough(),
    output,
    tty: false,
  });
  app.run(() => quitResolve());

  return { app, output: outputBuffer, sent, stopped, respondTo, respondLast, quit };
}

async function until(predicate: () => boolean): Promise<void> {
  for (let i = 0; i < 200 && !predicate(); i += 1) {
    await new Promise(resolve => setImmediate(resolve));
  }
}

describe("TUI app", () => {
  it("mode commands perform router state transitions and report them", async () => {
    const { app, output, quit } = makeHarness();
    await app.handleLine("/symbolic");
    expect(output.text).toContain("◈ Mode: symbolic");
    expect(app["options"].router.resolveMode("s1")).toBe("symbolic");

    await app.handleLine("/direct");
    expect(output.text).toContain("◈ Mode: direct");

    await app.handleLine("/symbolic-recursive");
    expect(output.text).toContain("◈ Mode: symbolic-recursive");
    await app.handleLine("/quit");
    await quit;
  });

  it("the /mode command inspects and validates", async () => {
    const { app, output, quit } = makeHarness();
    await app.handleLine("/mode");
    expect(output.text).toContain("Mode: direct");
    await app.handleLine("/mode bogus");
    expect(output.text).toContain('✗ unknown mode "bogus"');
    expect(app["options"].router.resolveMode("s1")).toBe("direct");
    await app.handleLine("/quit");
    await quit;
  });

  it("a message submits a canonical turn through the router's mode", async () => {
    const { app, output, sent, respondLast, quit } = makeHarness();
    await app.handleLine("/symbolic");
    const pending = app.handleLine("plan the refactor");
    await until(() => sent.some(frame => frame.operation === "session.turn"));
    expect(sent.find(frame => frame.operation === "session.turn")?.payload).toMatchObject({
      mode: "symbolic",
      text: "plan the refactor",
    });
    respondLast({ text: "here is the plan" });
    await pending;
    expect(output.text).toContain("⏺ here is the plan");
    expect(output.text).toContain("mode: symbolic");
    await app.handleLine("/quit");
    await quit;
  });

  it("a concurrent message while a turn runs is rejected without a second turn", async () => {
    const { app, output, sent, quit } = makeHarness();
    void app.handleLine("long running question");
    await until(() => sent.some(frame => frame.operation === "session.turn"));
    await app.handleLine("second question");
    expect(output.text).toContain("… a turn is already running");
    expect(sent.filter(frame => frame.operation === "session.turn")).toHaveLength(1);
    await app.handleLine("/quit");
    await quit;
  });

  it("structured runtime failures print their code, never a fake success", async () => {
    const { app, output, sent, respondLast, quit } = makeHarness();
    const pending = app.handleLine("this will fail");
    await until(() => sent.some(frame => frame.operation === "session.turn"));
    respondLast({
      status: "error",
      error: { code: "budget_exhausted", message: "iteration ceiling reached" },
    });
    await pending;
    expect(output.text).toContain("✗ [budget_exhausted] iteration ceiling reached");
    await app.handleLine("/quit");
    await quit;
  });

  it("cancellation settles as cancelled", async () => {
    const { app, output, sent, respondLast, quit } = makeHarness();
    const pending = app.handleLine("long turn");
    await until(() => sent.some(frame => frame.operation === "session.turn"));
    respondLast({ status: "cancelled", error: { code: "cancelled", message: "cancelled" } });
    await pending;
    expect(output.text).toContain("✗ [runtime_cancelled]");
    await app.handleLine("/quit");
    await quit;
  });

  it("the /skills command lists the runtime catalog", async () => {
    const { app, output, sent, respondTo, quit } = makeHarness();
    const pending = app.handleLine("/skills");
    await until(() => sent.some(frame => frame.operation === "skill.list"));
    const listRequest = sent.find(frame => frame.operation === "skill.list")!;
    respondTo(listRequest.request_id, {
      skills: [{ name: "demo-skill", description: "a demo" }],
    });
    await pending;
    expect(output.text).toContain("• demo-skill — a demo");
    await app.handleLine("/quit");
    await quit;
  });

  it("unknown commands fail with guidance instead of reaching the model", async () => {
    const { app, output, sent, quit } = makeHarness();
    await app.handleLine("/deploy");
    expect(output.text).toContain("✗ unknown command /deploy");
    expect(sent.filter(frame => frame.operation === "session.turn")).toHaveLength(0);
    await app.handleLine("/quit");
    await quit;
  });
});
