import { describe, expect, it } from "vitest";

import { apply, type AgentPrologPluginConfig, type PluginDeps } from "../src/plugin.js";
import type { SidecarTransport } from "../src/sidecar.js";
import { HARNESS, makeFakeContext, type FakeContext } from "./fakes.js";

function config(overrides: Partial<AgentPrologPluginConfig> = {}): AgentPrologPluginConfig {
  return {
    command: "/nix/store/fake-agentprolog-sidecar",
    harness: HARNESS,
    ...overrides,
  };
}

interface FakeTransportControls {
  readonly instances: FakeTransport[];
}

class FakeTransport {
  started = 0;
  stopped: string[] = [];
  constructor(_options: Record<string, unknown>) {
    controls.instances.push(this);
  }
  async start(): Promise<unknown> {
    this.started += 1;
    throw new Error("use startOk in tests");
  }
  async request(): Promise<Record<string, unknown>> {
    throw new Error("not wired");
  }
  onEvent(): () => void {
    return () => undefined;
  }
  async stop(reason: string): Promise<void> {
    this.stopped.push(reason);
  }
  capabilities(): Record<string, unknown> {
    return {};
  }
  activeBridge = null;
}

let controls: FakeTransportControls;

function makeTransportDeps(): PluginDeps & { controls: FakeTransportControls } {
  controls = { instances: [] };
  return { Transport: FakeTransport as unknown as typeof SidecarTransport, controls };
}

function fakeTransportFactory() {
  const deps = makeTransportDeps();
  const instances = deps.controls.instances;
  class FakeOkTransport extends FakeTransport {
    override capabilities(): Record<string, unknown> {
      return { modes: true };
    }
    override async start(): Promise<unknown> {
      this.started += 1;
      return {
        version: 1,
        request_id: "describe-1",
        session_id: "bridge",
        status: "ok",
        payload: { protocol_version: 1, runtime: "prolog-rlm", capabilities: { modes: true } },
      };
    }
  }
  return { Transport: FakeOkTransport as unknown as typeof SidecarTransport, instances };
}

describe("agentProlog DSH plugin", () => {
  it("mounts exactly one factory, the service, and the three commands", async () => {
    const ctx = makeFakeContext();
    const { Transport, instances } = fakeTransportFactory();
    const service = await apply(ctx as unknown as never, config(), { Transport });
    expect(service).toBeDefined();
    expect(ctx.agents?.factories).toHaveLength(1);
    expect(ctx.services.get("agentprolog")).toBe(service);
    expect(ctx.commands?.registered.map(command => command.name)).toEqual([
      "direct",
      "symbolic",
      "symbolic-recursive",
    ]);
    expect(ctx.effects.length).toBeGreaterThan(0);
    expect(instances).toHaveLength(1);
  });

  it("service router is session-safe and exposed for inspection", async () => {
    const ctx = makeFakeContext();
    const { Transport } = fakeTransportFactory();
    const service = await apply(ctx as unknown as never, config(), { Transport });
    expect(service.router.resolveMode("s1")).toBe("direct");
    service.router.setMode("s1", "symbolic");
    expect(service.router.resolveMode("s1")).toBe("symbolic");
    expect(service.router.resolveMode("s2")).toBe("direct");
    expect(service.capabilities()).toMatchObject({ modes: true });
  });

  it("fails closed on harness version mismatch without mounting anything", async () => {
    const ctx = makeFakeContext();
    const { Transport } = fakeTransportFactory();
    await expect(
      apply(ctx as unknown as never, config({ harness: { version: "0.1.0-rc.8", revision: "deadbeef" } }), { Transport }),
    ).rejects.toMatchObject({ message: /unsupported DeepSeek Harness version/ });
    expect(ctx.agents?.factories).toHaveLength(0);
    expect(ctx.commands?.registered).toHaveLength(0);
    expect(ctx.services.size).toBe(0);
  });

  it("fails closed on harness revision mismatch", async () => {
    const ctx = makeFakeContext();
    const { Transport } = fakeTransportFactory();
    await expect(
      apply(ctx as unknown as never, config({ harness: { version: HARNESS.version, revision: "not-the-rev" } }), { Transport }),
    ).rejects.toMatchObject({ message: /unsupported DeepSeek Harness revision/ });
  });

  it("requires the nix-pinned sidecar command", async () => {
    const ctx = makeFakeContext();
    const { Transport } = fakeTransportFactory();
    await expect(apply(ctx as unknown as never, config({ command: "" }), { Transport })).rejects.toThrow(/sidecar command/);
  });

  it("degrades to a router-only plugin when ctx.commands is unavailable", async () => {
    const ctx = makeFakeContext({ withCommands: false });
    const { Transport } = fakeTransportFactory();
    const service = await apply(ctx as unknown as never, config(), { Transport });
    expect(ctx.commands).toBeUndefined();
    expect(service.router.resolveMode("s1")).toBe("direct");
  });

  it("stops the transport when a Cordis effect disposer runs", async () => {
    const ctx = makeFakeContext();
    const { Transport, instances } = fakeTransportFactory();
    await apply(ctx as unknown as never, config(), { Transport });
    for (const cleanup of ctx.effects) cleanup();
    expect(instances[0]?.stopped).toEqual(["Cordis plugin unload"]);
  });

  it("rolls back registrations when startup fails mid-way", async () => {
    const ctx: FakeContext = makeFakeContext();
    const deps = makeTransportDeps();
    await expect(apply(ctx as unknown as never, config(), deps)).rejects.toThrow("use startOk in tests");
    expect(ctx.agents?.factories).toHaveLength(0);
    expect(ctx.services.size).toBe(0);
  });

  it("rejects an invalid configured default mode", async () => {
    const ctx = makeFakeContext();
    const { Transport } = fakeTransportFactory();
    await expect(
      apply(ctx as unknown as never, config({ defaults: { mode: "auto" as never } }), { Transport }),
    ).rejects.toThrow(/unknown agentProlog mode/);
  });
});
