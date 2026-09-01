import { describe, expect, it } from "vitest";

import { SidecarTransport } from "../src/sidecar.js";

const SIDECAR = process.env.AGENTPROLOG_SIDECAR;

describe.skipIf(!SIDECAR)("headless sidecar integration (real Prolog process, keyless)", () => {
  it("completes the describe handshake with mode capabilities", async () => {
    const transport = new SidecarTransport({ command: SIDECAR! });
    const description = await transport.start();
    expect(description.payload.runtime).toBe("prolog-rlm");
    expect(description.payload.protocol_version).toBe(1);
    expect(description.payload.capabilities).toMatchObject({ modes: true, cancellation: true });
    await transport.stop("test end");
  }, 30000);

  it("rejects session operations before session.start", async () => {
    const transport = new SidecarTransport({ command: SIDECAR! });
    await transport.start();
    await expect(
      transport.request({ version: 1, request_id: "r1", session_id: "ghost", operation: "session.mode", payload: { mode: "symbolic" } }),
    ).rejects.toMatchObject({ code: "runtime_error", message: /session.start must succeed/ });
    await expect(
      transport.request({ version: 1, request_id: "r2", session_id: "ghost", operation: "session.turn", payload: { text: "hi" } }),
    ).rejects.toMatchObject({ code: "runtime_error", message: /session.start must succeed/ });
    await transport.stop("test end");
  }, 30000);

  it("performs canonical mode transitions and reports them through inspect", async () => {
    const transport = new SidecarTransport({ command: SIDECAR! });
    await transport.start();
    const started = (await transport.request({ version: 1, request_id: "s1", session_id: "sess-1", operation: "session.start", payload: {} })) as {
      payload: { mode: string };
    };
    expect(started.payload.mode).toBe("direct");

    const setSymbolic = (await transport.request({
      version: 1, request_id: "s2", session_id: "sess-1", operation: "session.mode", payload: { mode: "symbolic" },
    })) as { payload: { mode: string; previous: string } };
    expect(setSymbolic.payload).toMatchObject({ mode: "symbolic", previous: "direct" });

    const setRecursive = (await transport.request({
      version: 1, request_id: "s3", session_id: "sess-1", operation: "session.mode", payload: { mode: "symbolic-recursive" },
    })) as { payload: { mode: string; previous: string } };
    expect(setRecursive.payload).toMatchObject({ mode: "symbolic-recursive", previous: "symbolic" });

    const inspect = (await transport.request({ version: 1, request_id: "s4", session_id: "sess-1", operation: "session.inspect", payload: {} })) as {
      payload: { mode: string; busy: boolean };
    };
    expect(inspect.payload).toMatchObject({ mode: "symbolic-recursive", busy: false });

    await expect(
      transport.request({ version: 1, request_id: "s5", session_id: "sess-1", operation: "session.mode", payload: { mode: "bogus" } }),
    ).rejects.toMatchObject({ code: "runtime_error", runtimeCode: "runtime_exception" });
    const inspectAfter = (await transport.request({ version: 1, request_id: "s6", session_id: "sess-1", operation: "session.inspect", payload: {} })) as {
      payload: { mode: string };
    };
    expect(inspectAfter.payload.mode).toBe("symbolic-recursive");
    await transport.stop("test end");
  }, 30000);

  it("fails a turn closed on an unsupported provider without any model call", async () => {
    const transport = new SidecarTransport({ command: SIDECAR! });
    await transport.start();
    await transport.request({ version: 1, request_id: "s1", session_id: "sess-2", operation: "session.start", payload: {} });
    await expect(
      transport.request({
        version: 1, request_id: "t1", session_id: "sess-2", operation: "session.turn",
        payload: { text: "hi", mode: "direct", provider: "not-openrouter" },
      }),
    ).rejects.toMatchObject({ code: "runtime_error", runtimeCode: "runtime_exception" });
    await transport.stop("test end");
  }, 30000);

  it("emits turn lifecycle runtime events and cancels idle sessions cleanly", async () => {
    const transport = new SidecarTransport({ command: SIDECAR! });
    const events: Array<Record<string, unknown>> = [];
    transport.onEvent(event => void events.push(event));
    await transport.start();
    await transport.request({ version: 1, request_id: "s1", session_id: "sess-3", operation: "session.start", payload: {} });

    const turnPending = transport.request({
      version: 1, request_id: "t1", session_id: "sess-3", operation: "session.turn",
      payload: { text: "hi", mode: "symbolic-recursive", provider: "bad" },
    });
    await expect(turnPending).rejects.toMatchObject({ code: "runtime_error", runtimeCode: "runtime_exception" });

    const started = events.find(event => event.event === "turn_started");
    expect(started).toMatchObject({ session_id: "sess-3", run_id: "t1", sequence: 0 });
    expect((started?.data as { mode?: string }).mode).toBe("symbolic-recursive");
    const finished = events.find(event => event.event === "turn_finished");
    expect(finished).toMatchObject({ session_id: "sess-3", run_id: "t1", sequence: 1 });

    const cancel = (await transport.request({ version: 1, request_id: "c1", session_id: "sess-3", operation: "session.cancel", payload: {} })) as {
      payload: { accepted: boolean; active_turns: number };
    };
    expect(cancel.payload).toMatchObject({ accepted: false, active_turns: 0 });
    await transport.stop("test end");
  }, 30000);

  it("loads, lists, and resets skills from a fixture root (keyless)", async () => {
    const transport = new SidecarTransport({ command: SIDECAR! });
    await transport.start();

    const loaded = (await transport.request({
      version: 1, request_id: "sk1", session_id: "bridge", operation: "skill.load",
      payload: { roots: [{ source: "project", path: "test/fixtures/skills" }] },
    })) as { payload: { loaded: number; skills: Array<{ name: string; description: string }> } };
    expect(loaded.payload.skills).toContainEqual({
      name: "demo-skill",
      description: "Demonstrates agentProlog skill loading end to end.",
    });

    const listed = (await transport.request({
      version: 1, request_id: "sk2", session_id: "bridge", operation: "skill.list", payload: {},
    })) as { payload: { skills: Array<{ name: string }> } };
    expect(listed.payload.skills.map(skill => skill.name)).toContain("demo-skill");

    const reset = (await transport.request({
      version: 1, request_id: "sk3", session_id: "bridge", operation: "skill.reset", payload: {},
    })) as { payload: { skills: unknown[] } };
    expect(reset.payload.skills).toEqual([]);

    const listedAfterReset = (await transport.request({
      version: 1, request_id: "sk4", session_id: "bridge", operation: "skill.list", payload: {},
    })) as { payload: { skills: unknown[] } };
    expect(listedAfterReset.payload.skills).toEqual([]);

    await expect(
      transport.request({
        version: 1, request_id: "sk5", session_id: "bridge", operation: "skill.load",
        payload: { roots: [{ source: "external", path: "" }] },
      }),
    ).rejects.toMatchObject({ code: "runtime_error", runtimeCode: "runtime_exception" });
    await transport.stop("test end");
  }, 30000);
});
