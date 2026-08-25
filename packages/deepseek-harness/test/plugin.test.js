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
    this.bridge = { capabilities: { conversation: true, cancellation: true, evolution: false } };
    FakeTransport.instances.push(this);
  }
  async start() {
    return { payload: { protocol_version: 1, capabilities: this.bridge.capabilities } };
  }
  request(frame) { this.requests.push(frame); return Promise.resolve({ status: "ok", payload: {} }); }
  async stop(reason) { this.stops.push(reason); }
}
FakeTransport.instances = [];

class FakeFactory {
  constructor(ctx, bridge) {
    this.ctx = ctx;
    this.bridge = bridge;
  }
}

function fakeContext({ existingFactory = null } = {}) {
  const effects = [];
  const services = new Map();
  const agents = {
    factory: existingFactory,
    setFactory(factory) {
      if (this.factory) throw new Error("AgentFactory already registered");
      this.factory = factory;
      const cleanup = () => { if (this.factory === factory) this.factory = null; };
      effects.push(cleanup);
      return cleanup;
    },
  };
  return {
    effects,
    services,
    agents,
    sessions: {},
    effect(body) {
      const cleanup = body();
      if (typeof cleanup === "function") effects.push(cleanup);
      return cleanup;
    },
    provide(name, service) {
      if (services.has(name)) throw new Error(`service already provided: ${name}`);
      services.set(name, service);
      const cleanup = () => services.delete(name);
      effects.push(cleanup);
      return cleanup;
    },
    async unload() {
      for (const cleanup of [...effects].reverse()) await cleanup();
    },
  };
}

const config = (extra = {}) => ({
  command: "/nix/store/agentprolog-rlm",
  harness: SUPPORTED_HARNESS,
  ...extra,
});

const deps = { Transport: FakeTransport, Factory: FakeFactory };

test("negotiates sidecar then publishes exactly one factory and bridge service", async () => {
  FakeTransport.instances.length = 0;
  const ctx = fakeContext();
  const { service, factory } = await apply(ctx, config(), deps);
  assert.equal(ctx.services.get(SERVICE_NAME), service);
  assert.equal(ctx.agents.factory, factory);
  assert.equal(factory.bridge, service);
  assert.deepEqual(service.capabilities(), { conversation: true, cancellation: true, evolution: false });
});

test("Cordis unload removes factory/service before stopping sidecar", async () => {
  FakeTransport.instances.length = 0;
  const ctx = fakeContext();
  await apply(ctx, config({ command: "sidecar" }), deps);
  assert.ok(ctx.agents.factory);
  assert.equal(ctx.services.has(SERVICE_NAME), true);
  await ctx.unload();
  assert.equal(ctx.agents.factory, null);
  assert.equal(ctx.services.has(SERVICE_NAME), false);
  assert.deepEqual(FakeTransport.instances[0].stops, ["Cordis plugin unload"]);
});

test("fails closed when stock agent-loop or another factory is still active", async () => {
  FakeTransport.instances.length = 0;
  const ctx = fakeContext({ existingFactory: { kind: "stock-agent-loop" } });
  await assert.rejects(apply(ctx, config(), deps), /AgentFactory already registered/);
  assert.equal(ctx.agents.factory.kind, "stock-agent-loop");
  assert.equal(ctx.services.size, 0);
  assert.deepEqual(FakeTransport.instances[0].stops, ["plugin startup failed"]);
});

test("does not publish when startup negotiation fails", async () => {
  class FailingTransport extends FakeTransport {
    async start() { throw new Error("protocol mismatch"); }
  }
  const ctx = fakeContext();
  await assert.rejects(
    apply(ctx, config({ command: "sidecar" }), { Transport: FailingTransport, Factory: FakeFactory }),
    /protocol mismatch/,
  );
  assert.equal(ctx.services.has(SERVICE_NAME), false);
  assert.equal(ctx.agents.factory, null);
});

test("requires an explicit Nix-pinned sidecar command", async () => {
  const ctx = fakeContext();
  await assert.rejects(
    apply(ctx, { harness: SUPPORTED_HARNESS }, deps),
    error => error.code === "bridge_spawn_failed",
  );
});

test("requires explicit pinned Harness identity", async () => {
  FakeTransport.instances.length = 0;
  const ctx = fakeContext();
  await assert.rejects(
    apply(ctx, { command: "sidecar" }, deps),
    error => error.code === "harness_identity_required",
  );
  assert.equal(FakeTransport.instances.length, 0);
  assert.equal(ctx.services.size, 0);
});

test("rejects incompatible Harness before spawning or publishing", async () => {
  FakeTransport.instances.length = 0;
  const ctx = fakeContext();
  await assert.rejects(
    apply(ctx, config({ harness: { ...SUPPORTED_HARNESS, revision: "unexpected" } }), deps),
    error => error.code === "harness_revision_mismatch",
  );
  assert.equal(FakeTransport.instances.length, 0);
  assert.equal(ctx.services.size, 0);
  assert.equal(ctx.effects.length, 0);
});
