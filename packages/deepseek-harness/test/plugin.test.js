import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { apply, SERVICE_NAME } from "../src/plugin.js";
import { SUPPORTED_HARNESS } from "../src/compatibility.js";

class FakeTransport extends EventEmitter {
  constructor(options) {
    super();
    this.options = options;
    this.stops = [];
    this.requests = [];
    this.bridge = { capabilities: { subagents: true, evolution: false } };
    FakeTransport.instances.push(this);
  }
  async start() {
    return { payload: { protocol_version: 1, capabilities: this.bridge.capabilities } };
  }
  request(frame) { this.requests.push(frame); return Promise.resolve({ status: "ok", payload: {} }); }
  async stop(reason) { this.stops.push(reason); }
}
FakeTransport.instances = [];

function fakeContext() {
  const effects = [];
  const services = new Map();
  return {
    effects,
    services,
    effect(disposer) { effects.push(disposer); return disposer; },
    async provide(name, service) {
      services.set(name, service);
      return () => services.delete(name);
    },
  };
}

const config = (extra = {}) => ({
  command: "/nix/store/agentprolog-rlm",
  harness: SUPPORTED_HARNESS,
  ...extra,
});

test("publishes service only after host compatibility and sidecar negotiation", async () => {
  FakeTransport.instances.length = 0;
  const ctx = fakeContext();
  const { service } = await apply(ctx, config(), { Transport: FakeTransport });
  assert.equal(ctx.services.get(SERVICE_NAME), service);
  assert.deepEqual(service.capabilities(), { subagents: true, evolution: false });
  await service.request({ request_id: "r1" });
  assert.equal(FakeTransport.instances[0].requests.length, 1);
});

test("Cordis effect unload removes service and stops sidecar", async () => {
  FakeTransport.instances.length = 0;
  const ctx = fakeContext();
  await apply(ctx, config({ command: "sidecar" }), { Transport: FakeTransport });
  assert.equal(ctx.services.has(SERVICE_NAME), true);
  await ctx.effects[0]();
  assert.equal(ctx.services.has(SERVICE_NAME), false);
  assert.deepEqual(FakeTransport.instances[0].stops, ["Cordis plugin unload"]);
});

test("does not publish a service when startup negotiation fails", async () => {
  class FailingTransport extends FakeTransport {
    async start() { throw new Error("protocol mismatch"); }
  }
  const ctx = fakeContext();
  await assert.rejects(apply(ctx, config({ command: "sidecar" }), { Transport: FailingTransport }), /protocol mismatch/);
  assert.equal(ctx.services.has(SERVICE_NAME), false);
});

test("requires an explicit Nix-pinned sidecar command", async () => {
  const ctx = fakeContext();
  await assert.rejects(
    apply(ctx, { harness: SUPPORTED_HARNESS }, { Transport: FakeTransport }),
    error => error.code === "bridge_spawn_failed",
  );
});

test("requires explicit pinned Harness identity", async () => {
  FakeTransport.instances.length = 0;
  const ctx = fakeContext();
  await assert.rejects(
    apply(ctx, { command: "sidecar" }, { Transport: FakeTransport }),
    error => error.code === "harness_identity_required",
  );
  assert.equal(FakeTransport.instances.length, 0);
  assert.equal(ctx.services.size, 0);
});

test("rejects incompatible Harness before spawning or publishing", async () => {
  FakeTransport.instances.length = 0;
  const ctx = fakeContext();
  await assert.rejects(
    apply(ctx, config({ harness: { ...SUPPORTED_HARNESS, revision: "unexpected" } }), { Transport: FakeTransport }),
    error => error.code === "harness_revision_mismatch",
  );
  assert.equal(FakeTransport.instances.length, 0);
  assert.equal(ctx.services.size, 0);
  assert.equal(ctx.effects.length, 0);
});
