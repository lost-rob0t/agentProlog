import { describe, expect, it } from "vitest";

import { ModeError, ProtocolError } from "../src/errors.js";
import { ModeRouter, type TurnOutcome } from "../src/router.js";
import type { AgentPrologMode } from "../src/modes.js";

function makeRouter(overrides: Partial<ConstructorParameters<typeof ModeRouter>[0]> = {}) {
  const executed: Array<{ sessionId: string; text: string; mode: AgentPrologMode }> = [];
  const modeChanges: Array<{ sessionId: string; from: AgentPrologMode; to: AgentPrologMode }> = [];
  const settled: Array<{ sessionId: string; mode: AgentPrologMode; backend: string; cancelled: boolean; error?: string }> = [];
  const router = new ModeRouter({
    execute: async (request, mode) => {
      executed.push({ sessionId: request.sessionId, text: request.text, mode });
      return {
        text: `reply:${request.text}`,
        provider: "openrouter",
        model: null,
        mode,
      } satisfies TurnOutcome;
    },
    onModeChange: event => void modeChanges.push(event),
    onTurnSettled: record => void settled.push(record),
    ...overrides,
  });
  return { router, executed, modeChanges, settled };
}

describe("ModeRouter", () => {
  it("resolves the deterministic default (direct) for unknown sessions", () => {
    const { router } = makeRouter();
    expect(router.resolveMode("session-a")).toBe("direct");
    expect(router.currentMode("session-a")).toBe("direct");
  });

  it("supports an explicit configured default", () => {
    const { router } = makeRouter({ defaultMode: "symbolic" });
    expect(router.resolveMode("session-a")).toBe("symbolic");
  });

  it("switches to direct, symbolic, and symbolic-recursive", () => {
    const { router, modeChanges } = makeRouter();
    expect(router.setMode("s1", "direct")).toBe("direct");
    expect(router.resolveMode("s1")).toBe("direct");
    expect(router.setMode("s1", "symbolic")).toBe("symbolic");
    expect(router.resolveMode("s1")).toBe("symbolic");
    expect(router.setMode("s1", "symbolic-recursive")).toBe("symbolic-recursive");
    expect(router.resolveMode("s1")).toBe("symbolic-recursive");
    expect(modeChanges.map(change => `${change.from}->${change.to}`)).toEqual([
      "direct->symbolic",
      "symbolic->symbolic-recursive",
    ]);
  });

  it("rejects invalid modes without mutating state", () => {
    const { router } = makeRouter();
    router.setMode("s1", "symbolic");
    expect(() => router.setMode("s1", "auto" as never)).toThrow(ModeError);
    expect(router.resolveMode("s1")).toBe("symbolic");
  });

  it("keeps session modes isolated from each other", () => {
    const { router } = makeRouter();
    router.setMode("session-a", "symbolic");
    router.setMode("session-b", "symbolic-recursive");
    expect(router.resolveMode("session-a")).toBe("symbolic");
    expect(router.resolveMode("session-b")).toBe("symbolic-recursive");
    expect(router.resolveMode("session-c")).toBe("direct");
    router.setMode("session-a", "direct");
    expect(router.resolveMode("session-b")).toBe("symbolic-recursive");
  });

  it("routes each turn through the backend selected by the session mode", async () => {
    const { router, executed } = makeRouter();
    router.setMode("s-symbolic", "symbolic");
    router.setMode("s-recursive", "symbolic-recursive");

    await router.executeTurn({ sessionId: "s-direct", text: "hello" });
    await router.executeTurn({ sessionId: "s-symbolic", text: "plan this" });
    await router.executeTurn({ sessionId: "s-recursive", text: "decompose" });

    expect(executed.map(call => `${call.sessionId}:${call.mode}`)).toEqual([
      "s-direct:direct",
      "s-symbolic:symbolic",
      "s-recursive:symbolic-recursive",
    ]);
  });

  it("reports settled turns with backend, duration, and cancellation", async () => {
    const { router, settled } = makeRouter({
      execute: async () => {
        throw new ProtocolError("runtime_cancelled", "cancelled");
      },
    });
    await expect(router.executeTurn({ sessionId: "s1", text: "hi" })).rejects.toThrow("cancelled");
    expect(settled).toHaveLength(1);
    expect(settled[0]).toMatchObject({ sessionId: "s1", mode: "direct", backend: "direct", cancelled: true });
  });

  it("rejects empty turn text before selecting a backend", async () => {
    const { router, executed } = makeRouter();
    await expect(router.executeTurn({ sessionId: "s1", text: "   " })).rejects.toThrow(/non-empty/);
    expect(executed).toHaveLength(0);
  });

  it("forgets per-session state on disposal", () => {
    const { router } = makeRouter();
    router.setMode("s1", "symbolic");
    router.forgetSession("s1");
    expect(router.resolveMode("s1")).toBe("direct");
  });
});
