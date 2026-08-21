import assert from "node:assert/strict";
import test from "node:test";
import { Bridge } from "../src/bridge.js";
import { PROTOCOL_VERSION, ProtocolError, validateRequest, validateRuntimeEvent } from "../src/protocol.js";

function request(overrides = {}) {
  return {
    version: PROTOCOL_VERSION,
    request_id: "req-1",
    session_id: "session-1",
    operation: "runtime.describe",
    payload: {},
    ...overrides,
  };
}

test("rejects unknown protocol versions and arbitrary operations", () => {
  assert.throws(() => validateRequest(request({ version: 99 })), error => error.code === "protocol_mismatch");
  assert.throws(() => validateRequest(request({ operation: "prolog.call" })), error => error.code === "unknown_operation");
});

test("holds experiment operations until upstream capability exists", () => {
  const frame = request({ operation: "experiment.start" });
  assert.throws(() => validateRequest(frame), error => error.code === "capability_unavailable");
  assert.equal(validateRequest(frame, { evolution: true }), frame);
});

test("preserves subagent correlation fields without scheduling in TypeScript", () => {
  const event = validateRuntimeEvent({
    version: PROTOCOL_VERSION,
    session_id: "session-1",
    run_id: "child-1",
    parent_run_id: "parent-1",
    subagent_run_id: "child-1",
    sequence: 0,
    event: "subagent.completed",
    payload: { outcome: "verified" },
  });
  assert.equal(event.parent_run_id, "parent-1");
  assert.equal(event.subagent_run_id, "child-1");
});

test("correlates responses and rejects duplicate pending request ids", async () => {
  const sent = [];
  const bridge = new Bridge({ send: frame => sent.push(frame) });
  const pending = bridge.request(request());
  await assert.rejects(bridge.request(request()), error => error.code === "duplicate_request");
  bridge.receive({ version: PROTOCOL_VERSION, request_id: "req-1", session_id: "session-1", status: "ok", payload: {} });
  assert.equal((await pending).status, "ok");
  assert.equal(sent.length, 1);
});

test("rejects non-monotonic runtime events", () => {
  const bridge = new Bridge({ send() {} });
  bridge.receive({ version: PROTOCOL_VERSION, session_id: "s", run_id: "r", sequence: 2, event: "trace", payload: {} });
  assert.throws(
    () => bridge.receive({ version: PROTOCOL_VERSION, session_id: "s", run_id: "r", sequence: 2, event: "trace", payload: {} }),
    error => error.code === "out_of_order_event",
  );
});

test("dispose fails outstanding work instead of reporting false success", async () => {
  const bridge = new Bridge({ send() {} });
  const pending = bridge.request(request());
  bridge.dispose("plugin unload");
  await assert.rejects(pending, error => error instanceof ProtocolError && error.code === "bridge_disposed");
  await assert.rejects(bridge.request(request({ request_id: "req-2" })), error => error.code === "bridge_disposed");
});
