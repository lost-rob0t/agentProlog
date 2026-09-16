import { EventEmitter } from "node:events";

import { afterEach, describe, expect, it } from "vitest";

import { ProtocolError } from "../src/errors.js";
import { SidecarTransport } from "../src/sidecar.js";

interface FakeChild extends EventEmitter {
  stdout: EventEmitter & { setEncoding: (encoding: string) => void };
  stderr: EventEmitter & { setEncoding: (encoding: string) => void };
  stdin: { writable: boolean; write: (chunk: string) => void; end: () => void };
  kill: (signal?: string) => void;
  exited?: boolean;
}

function makeFakeChild(): FakeChild {
  const child = new EventEmitter() as FakeChild;
  const makeStream = (): EventEmitter & { setEncoding: (encoding: string) => void } => {
    const stream = new EventEmitter() as EventEmitter & { setEncoding: (encoding: string) => void };
    stream.setEncoding = () => stream;
    return stream;
  };
  child.stdout = makeStream();
  child.stderr = makeStream();
  const written: string[] = [];
  child.stdin = {
    writable: true,
    write(chunk) {
      written.push(chunk);
      return;
    },
    end() {
      if (!child.exited) {
        child.exited = true;
        process.nextTick(() => child.emit("exit", 0, null));
      }
    },
  };
  child.kill = () => {
    if (!child.exited) {
      child.exited = true;
      child.emit("exit", null, "SIGTERM");
    }
  };
  return child;
}

function makeTransport(child: FakeChild): SidecarTransport {
  return new SidecarTransport({
    command: "fake-sidecar",
    spawn: (() => child) as never,
    shutdownMs: 50,
  });
}

function describeReply(requestId: string): string {
  return `${JSON.stringify({
    version: 1,
    request_id: requestId,
    session_id: "bridge",
    status: "ok",
    payload: {
      protocol_version: 1,
      runtime: "prolog-rlm",
      transport: "ndjson-stdio",
      capabilities: { conversation: true, cancellation: true, agent_factory: true, evolution: false, modes: true },
    },
  })}\n`;
}

afterEach(() => {
  // no shared state
});

describe("SidecarTransport", () => {
  it("completes the describe handshake and exposes capabilities", async () => {
    const child = makeFakeChild();
    const transport = makeTransport(child);
    child.stdout.on("data", () => undefined);
    const pending = transport.start();
    child.stdout.emit("data", describeReply("describe-1"));
    const description = await pending;
    expect(description.payload.protocol_version).toBe(1);
    expect(transport.capabilities()).toMatchObject({ modes: true });
    await transport.stop("test end");
  });

  it("fails closed on protocol mismatch", async () => {
    const child = makeFakeChild();
    const transport = makeTransport(child);
    const mismatch = describeReply("describe-1").replace('"protocol_version":1', '"protocol_version":99');
    const pending = transport.start();
    child.stdout.emit("data", mismatch);
    await expect(pending).rejects.toMatchObject({ code: "protocol_mismatch" });
  });

  it("fails closed when the sidecar exits during startup", async () => {
    const child = makeFakeChild();
    const transport = makeTransport(child);
    const pending = transport.start();
    child.emit("exit", 1, null);
    await expect(pending).rejects.toMatchObject({ code: expect.stringMatching(/^bridge_dis/) });
  });

  it("rejects pending requests when the sidecar dies mid-flight", async () => {
    const child = makeFakeChild();
    const transport = makeTransport(child);
    const started = transport.start();
    child.stdout.emit("data", describeReply("describe-1"));
    await started;

    const pending = transport.request({
      version: 1,
      request_id: "req-1",
      session_id: "s1",
      operation: "session.start",
      payload: {},
    });
    child.emit("exit", 1, null);
    await expect(pending).rejects.toMatchObject({ code: expect.stringMatching(/^bridge_dis/) });
  });

  it("fails closed on malformed NDJSON output", async () => {
    const child = makeFakeChild();
    const transport = makeTransport(child);
    const bridgeErrors: Error[] = [];
    transport.on("bridgeError", error => void bridgeErrors.push(error));
    const started = transport.start();
    child.stdout.emit("data", describeReply("describe-1"));
    await started;
    child.stdout.emit("data", "not json at all\n");
    expect(bridgeErrors[0]).toBeInstanceOf(ProtocolError);
    expect((bridgeErrors[0] as ProtocolError).code).toBe("bridge_malformed_frame");
  });

  it("surfaces sidecar stderr for diagnostics without scraping it", async () => {
    const child = makeFakeChild();
    const transport = makeTransport(child);
    const stderr: string[] = [];
    transport.on("stderr", chunk => void stderr.push(chunk));
    const started = transport.start();
    child.stdout.emit("data", describeReply("describe-1"));
    await started;
    child.stderr.emit("data", "sidecar diagnostic\n");
    expect(stderr.join("")).toContain("sidecar diagnostic");
    await transport.stop("test end");
  });

  it("delivers fragmented model text events before the final turn response", async () => {
    const child = makeFakeChild();
    const transport = makeTransport(child);
    const started = transport.start();
    child.stdout.emit("data", describeReply("describe-1"));
    await started;
    const observed: string[] = [];
    transport.onEvent(event => observed.push(String(event.event)));
    const pending = transport.request({
      version: 1, request_id: "turn-1", session_id: "s1",
      operation: "session.turn", payload: { text: "hello" },
    });
    let settled = false;
    void pending.then(() => { settled = true; });
    const event = (name: string, sequence: number, data: Record<string, unknown> = {}) =>
      JSON.stringify({ version: 1, session_id: "s1", run_id: "turn-1", event: name, sequence, data }) + "\n";
    const frames = [
      event("turn_started", 0),
      event("message_started", 1, { message_id: "turn-1:model:0:1", operation: "model" }),
      event("text_delta", 2, { message_id: "turn-1:model:0:1", delta: "He" }),
      event("text_delta", 3, { message_id: "turn-1:model:0:1", delta: "llo" }),
      event("message_completed", 4, { message_id: "turn-1:model:0:1" }),
    ].join("");
    child.stdout.emit("data", frames.slice(0, 47));
    child.stdout.emit("data", frames.slice(47));
    expect(observed).toEqual(["turn_started", "message_started", "text_delta", "text_delta", "message_completed"]);
    expect(settled).toBe(false);
    child.stdout.emit("data", JSON.stringify({
      version: 1, request_id: "turn-1", session_id: "s1", status: "ok", payload: { text: "Hello" },
    }) + "\n");
    await expect(pending).resolves.toMatchObject({ payload: { text: "Hello" } });
    await transport.stop("test end");
  });

  it.each(["cancelled", "error"])("keeps partial text unfinished when a turn %s", async status => {
    const child = makeFakeChild();
    const transport = makeTransport(child);
    const started = transport.start();
    child.stdout.emit("data", describeReply("describe-1"));
    await started;
    const observed: string[] = [];
    transport.onEvent(event => observed.push(String(event.event)));
    const pending = transport.request({
      version: 1, request_id: "turn-1", session_id: "s1",
      operation: "session.turn", payload: { text: "hello" },
    });
    for (const [sequence, name] of ["turn_started", "message_started", "text_delta", "turn_finished"].entries()) {
      child.stdout.emit("data", JSON.stringify({
        version: 1, session_id: "s1", run_id: "turn-1", event: name, sequence,
        data: name === "turn_finished" ? { status } : { delta: "partial" },
      }) + "\n");
    }
    child.stdout.emit("data", JSON.stringify({
      version: 1, request_id: "turn-1", session_id: "s1", status, payload: {},
      error: { code: status, message: status },
    }) + "\n");
    await expect(pending).rejects.toMatchObject({ code: `runtime_${status}` });
    expect(observed).toEqual(["turn_started", "message_started", "text_delta", "turn_finished"]);
    await transport.stop("test end");
  });
});
