import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { SidecarTransport } from "../src/sidecar.js";

const SIDECAR = process.env.AGENTPROLOG_SIDECAR;

describe.skipIf(!SIDECAR)("persistent sidecar single-writer admission (real processes, keyless)", () => {
  it.each(["graceful", "crash"] as const)("rejects a second writer and releases ownership after %s exit", async exit => {
    const sandbox = mkdtempSync(join(tmpdir(), "agentprolog-store-lock-"));
    const store = join(sandbox, "conversation.db");
    const alias = join(sandbox, "alias.db");
    let child: ChildProcess | undefined;
    const first = new SidecarTransport({ command: SIDECAR!, env: { AGENTPROLOG_CONVERSATION_STORE: store },
      spawn: new Proxy(spawn, { apply(target, thisArg, args) {
        child = Reflect.apply(target, thisArg, args) as ChildProcess; return child;
      } }) });
    let rejected: SidecarTransport | undefined;
    let resumed: SidecarTransport | undefined;
    try {
      await first.start();
      symlinkSync(store, alias);
      rejected = new SidecarTransport({ command: SIDECAR!, env: { AGENTPROLOG_CONVERSATION_STORE: alias } });
      let stderr = "";
      rejected.on("stderr", chunk => { stderr += String(chunk); });
      await expect(rejected.start()).rejects.toMatchObject({ message: /sidecar exited/ });
      expect(stderr).toContain("conversation_store_locked");
      await rejected.stop("expected contention");
      if (exit === "graceful") await first.stop("release store");
      else {
        const exited = once(first, "exit");
        child!.kill("SIGKILL");
        await exited;
      }
      resumed = new SidecarTransport({ command: SIDECAR!, env: { AGENTPROLOG_CONVERSATION_STORE: store } });
      await expect(resumed.start()).resolves.toMatchObject({ payload: { protocol_version: 1 } });
    } finally {
      await first.stop("cleanup");
      await rejected?.stop("cleanup");
      await resumed?.stop("cleanup");
      rmSync(sandbox, { recursive: true, force: true });
    }
  });

  it("retains actual incoming history across restart without provider access", async () => {
    const sandbox = mkdtempSync(join(tmpdir(), "agentprolog-history-"));
    const store = join(sandbox, "conversation.db");
    const session = "durable-history";
    // Empty credentials make provider admission fail locally, before any HTTP
    // call. The accepted incoming message must nevertheless remain durable.
    const create = (): SidecarTransport => new SidecarTransport({ command: SIDECAR!,
      env: { AGENTPROLOG_CONVERSATION_STORE: store, OPENROUTER_API_KEY: "" } });
    const first = create(); const second = create();
    let request = 0;
    const send = (transport: SidecarTransport, operation: string, payload: Record<string, unknown> = {}) =>
      transport.request({ version: 1, request_id: `history-${++request}`, session_id: session, operation, payload });
    try {
      await first.start();
      await send(first, "session.start", { cwd: process.cwd() });
      await expect(send(first, "session.turn", { text: "first durable user message", mode: "symbolic" }))
        .rejects.toMatchObject({ message: /missing_credential/ });
      await first.stop("restart");
      expect(readFileSync(store, "utf8")).toContain("first durable user message");
      await second.start();
      await expect(send(second, "session.start", { cwd: process.cwd() }))
        .resolves.toMatchObject({ payload: { resumed: true } });
      await expect(send(second, "session.inspect"))
        .resolves.toMatchObject({ payload: { stats: { messages: 1, user_messages: 1 } } });
      await expect(send(second, "session.turn", { text: "second durable user message", mode: "symbolic" }))
        .rejects.toMatchObject({ message: /missing_credential/ });
      await expect(send(second, "session.inspect"))
        .resolves.toMatchObject({ payload: { stats: { messages: 2, user_messages: 2 } } });
      await second.stop("flush");
      const journal = readFileSync(store, "utf8");
      expect(journal).toContain("first durable user message");
      expect(journal).toContain("second durable user message");
    } finally {
      await first.stop("cleanup"); await second.stop("cleanup");
      rmSync(sandbox, { recursive: true, force: true });
    }
  });
});
