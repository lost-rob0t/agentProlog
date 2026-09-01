import { describe, expect, it } from "vitest";

import { Bridge } from "../src/bridge.js";
import { ProtocolError } from "../src/errors.js";
import { PROTOCOL_VERSION, type RequestFrame } from "../src/protocol.js";

function frame(overrides: Partial<RequestFrame> = {}): RequestFrame {
  return {
    version: PROTOCOL_VERSION,
    request_id: "req-1",
    session_id: "s1",
    operation: "session.inspect",
    payload: {},
    ...overrides,
  };
}

function makeBridge() {
  const sent: RequestFrame[] = [];
  const bridge = new Bridge({
    send: frame => void sent.push(frame),
    capabilities: { conversation: true, modes: true },
  });
  return { bridge, sent };
}

describe("Bridge", () => {
  it("correlates a response to its pending request", async () => {
    const { bridge, sent } = makeBridge();
    const pending = bridge.request(frame());
    expect(sent).toHaveLength(1);
    bridge.receive({
      version: PROTOCOL_VERSION,
      request_id: "req-1",
      session_id: "s1",
      status: "ok",
      payload: { mode: "direct" },
    });
    await expect(pending).resolves.toMatchObject({ status: "ok", payload: { mode: "direct" } });
  });

  it("rejects error and cancelled statuses with structured codes", async () => {
    const { bridge } = makeBridge();
    const errorPending = bridge.request(frame({ request_id: "req-e" }));
    bridge.receive({
      version: PROTOCOL_VERSION,
      request_id: "req-e",
      session_id: "s1",
      status: "error",
      payload: {},
      error: { code: "turn_failed", message: "provider exploded" },
    });
    await expect(errorPending).rejects.toMatchObject({ code: "runtime_error" });

    const cancelPending = bridge.request(frame({ request_id: "req-c" }));
    bridge.receive({
      version: PROTOCOL_VERSION,
      request_id: "req-c",
      session_id: "s1",
      status: "cancelled",
      payload: {},
      error: { code: "cancelled" },
    });
    await expect(cancelPending).rejects.toMatchObject({ code: "runtime_cancelled" });
  });

  it("rejects responses whose session does not match the request", async () => {
    const { bridge } = makeBridge();
    const pending = bridge.request(frame());
    expect(() =>
      bridge.receive({
        version: PROTOCOL_VERSION,
        request_id: "req-1",
        session_id: "other",
        status: "ok",
        payload: {},
      }),
    ).toThrow(ProtocolError);

    void pending;
  });

  it("validates requests against the operation allow-list", async () => {
    const { bridge } = makeBridge();
    expect(() => bridge.request(frame({ operation: "self_destruct" }))).toThrow(/not allow-listed/);
    expect(() => bridge.request(frame({ version: 99 as never }))).toThrow(/unsupported protocol version/);
  });

  it("delivers runtime events and enforces per-run monotonic sequences", () => {
    const { bridge } = makeBridge();
    const events: Array<Record<string, unknown>> = [];
    const received = bridge.receive({
      version: PROTOCOL_VERSION,
      session_id: "s1",
      run_id: "run-1",
      event: "turn_started",
      sequence: 0,
    });
    expect(received.type).toBe("event");
    bridge.receive({ version: PROTOCOL_VERSION, session_id: "s1", run_id: "run-1", event: "turn_finished", sequence: 1 });
    expect(events).toEqual([]);
    expect(() =>
      bridge.receive({ version: PROTOCOL_VERSION, session_id: "s1", run_id: "run-1", event: "late", sequence: 0 }),
    ).toThrow(/non-monotonic/);
  });

  it("rejects pending requests on dispose", async () => {
    const { bridge } = makeBridge();
    const pending = bridge.request(frame());
    bridge.dispose("test shutdown");
    await expect(pending).rejects.toMatchObject({ code: "bridge_disposed", message: "test shutdown" });
  });
});
