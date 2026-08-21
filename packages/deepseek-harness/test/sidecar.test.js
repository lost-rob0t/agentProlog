import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { SidecarTransport } from "../src/sidecar.js";
import { PROTOCOL_VERSION } from "../src/protocol.js";

class Stream extends EventEmitter {
  constructor() { super(); this.writable = true; this.writes = []; }
  setEncoding() {}
  write(value) { this.writes.push(value); return true; }
  end() { this.writable = false; }
}

class FakeChild extends EventEmitter {
  constructor() {
    super();
    this.stdin = new Stream();
    this.stdout = new Stream();
    this.stderr = new Stream();
    this.killed = [];
  }
  kill(signal) { this.killed.push(signal); this.emit("exit", null, signal); }
}

function fakeSpawnFactory(child, seen) {
  return (command, args, options) => {
    seen.push({ command, args, options });
    queueMicrotask(() => {
      const request = JSON.parse(child.stdin.writes[0]);
      child.stdout.emit("data", `${JSON.stringify({
        version: PROTOCOL_VERSION,
        request_id: request.request_id,
        session_id: request.session_id,
        status: "ok",
        payload: { protocol_version: PROTOCOL_VERSION, capabilities: { subagents: true } },
      })}\n`);
    });
    return child;
  };
}

test("starts without an ambient shell and negotiates runtime capabilities", async () => {
  const child = new FakeChild();
  const seen = [];
  const transport = new SidecarTransport({ command: "/nix/store/sidecar/bin/agentprolog-rlm", args: ["--stdio"], spawn: fakeSpawnFactory(child, seen) });
  const description = await transport.start();
  assert.equal(seen[0].options.shell, false);
  assert.equal(description.payload.capabilities.subagents, true);
  assert.equal(transport.bridge.capabilities.subagents, true);
  await transport.stop();
});

test("passes runtime events through without scheduling subagents in JavaScript", async () => {
  const child = new FakeChild();
  const transport = new SidecarTransport({ command: "sidecar", spawn: fakeSpawnFactory(child, []) });
  await transport.start();
  const events = [];
  transport.on("event", event => events.push(event));
  child.stdout.emit("data", `${JSON.stringify({ version: PROTOCOL_VERSION, session_id: "s", run_id: "child", parent_run_id: "parent", subagent_run_id: "child", sequence: 1, event: "subagent.completed", payload: { status: "verified" } })}\n`);
  assert.equal(events[0].parent_run_id, "parent");
  assert.equal(events[0].subagent_run_id, "child");
  await transport.stop();
});

test("malformed sidecar output fails outstanding requests", async () => {
  const child = new FakeChild();
  const transport = new SidecarTransport({ command: "sidecar", spawn: fakeSpawnFactory(child, []) });
  await transport.start();
  const pending = transport.request({ version: PROTOCOL_VERSION, request_id: "req-2", session_id: "s", operation: "session.inspect", payload: {} });
  child.stdout.emit("data", "not-json\n");
  await assert.rejects(pending, error => error.code === "bridge_disposed");
  await transport.stop();
});

test("unload fails pending work and terminates a sidecar that does not exit", async () => {
  const child = new FakeChild();
  const transport = new SidecarTransport({ command: "sidecar", spawn: fakeSpawnFactory(child, []), shutdownMs: 1 });
  await transport.start();
  const pending = transport.request({ version: PROTOCOL_VERSION, request_id: "req-3", session_id: "s", operation: "session.inspect", payload: {} });
  await transport.stop("plugin unload");
  await assert.rejects(pending, error => error.code === "bridge_disposed");
  assert.deepEqual(child.killed, ["SIGTERM"]);
});
