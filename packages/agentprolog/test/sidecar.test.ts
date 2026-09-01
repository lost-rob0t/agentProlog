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
});
