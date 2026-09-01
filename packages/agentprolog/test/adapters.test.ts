import { describe, expect, it } from "vitest";

import { executeTurnViaBridge } from "../src/adapters.js";
import { Bridge } from "../src/bridge.js";
import { PROTOCOL_VERSION, type RequestFrame, type ResponseFrame } from "../src/protocol.js";

interface Harness {
  bridge: Bridge;
  readonly sent: RequestFrame[];
  respond: (response: Partial<ResponseFrame> & { request_id?: string }) => void;
}

function makeHarness(): Harness {
  const sent: RequestFrame[] = [];
  const bridge = new Bridge({ send: frame => void sent.push(frame) });
  return {
    bridge,
    sent,
    respond(response) {
      bridge.receive({
        version: PROTOCOL_VERSION,
        request_id: response.request_id ?? sent[sent.length - 1]!.request_id,
        session_id: "s1",
        status: response.status ?? "ok",
        payload: response.payload ?? {},
        ...(response.error === undefined ? {} : { error: response.error }),
      } as ResponseFrame);
    },
  };
}

describe("mode adapters", () => {
  it("shapes the canonical turn payload per mode", async () => {
    const harness = makeHarness();
    const pending = executeTurnViaBridge(harness.bridge, {
      sessionId: "s1",
      text: "do the thing",
      mode: "symbolic-recursive",
      options: { provider: "openrouter", model: "deepseek-v4", maxRecursionDepth: 3 },
    });
    harness.respond({ payload: { text: "done", provider: "openrouter", model: "deepseek-v4", meta: { budget_max_recursion_depth: 3 } } });
    const outcome = await pending;

    expect(harness.sent[0]).toMatchObject({
      version: PROTOCOL_VERSION,
      session_id: "s1",
      operation: "session.turn",
      payload: {
        text: "do the thing",
        mode: "symbolic-recursive",
        provider: "openrouter",
        model: "deepseek-v4",
        max_recursion_depth: 3,
      },
    });
    expect(outcome).toMatchObject({ text: "done", mode: "symbolic-recursive", provider: "openrouter", model: "deepseek-v4" });
  });

  it("omits recursion fields for direct and symbolic modes", async () => {
    for (const mode of ["direct", "symbolic"] as const) {
      const harness = makeHarness();
      const pending = executeTurnViaBridge(harness.bridge, { sessionId: "s1", text: "hi", mode, options: {} });
      harness.respond({ payload: { text: "ok" } });
      await pending;
      expect(harness.sent[0]?.payload).not.toHaveProperty("max_recursion_depth");
    }
  });

  it("rejects invalid recursion ceilings before sending anything", async () => {
    const harness = makeHarness();
    await expect(
      executeTurnViaBridge(harness.bridge, {
        sessionId: "s1",
        text: "hi",
        mode: "symbolic-recursive",
        options: { maxRecursionDepth: 0 },
      }),
    ).rejects.toMatchObject({ code: "invalid_recursion_depth" });
    expect(harness.sent).toHaveLength(0);
  });

  it("propagates cancellation as runtime_cancelled", async () => {
    const harness = makeHarness();
    const pending = executeTurnViaBridge(harness.bridge, { sessionId: "s1", text: "hi", mode: "direct", options: {} });
    harness.respond({ status: "cancelled", error: { code: "cancelled", message: "canonical Prolog-RLM turn cancelled" } });
    await expect(pending).rejects.toMatchObject({ code: "runtime_cancelled" });
  });

  it("wraps runtime errors in a structured TurnExecutionError", async () => {
    const harness = makeHarness();
    const pending = executeTurnViaBridge(harness.bridge, { sessionId: "s1", text: "hi", mode: "symbolic", options: {} });
    harness.respond({ status: "error", error: { code: "budget_exhausted", message: "iteration ceiling reached" } });
    await expect(pending).rejects.toMatchObject({ code: "budget_exhausted", name: "TurnExecutionError" });
  });

  it("fails closed when the runtime returns no assistant text", async () => {
    const harness = makeHarness();
    const pending = executeTurnViaBridge(harness.bridge, { sessionId: "s1", text: "hi", mode: "direct", options: {} });
    harness.respond({ payload: { provider: "openrouter" } });
    await expect(pending).rejects.toMatchObject({ code: "invalid_turn_response" });
  });
});
