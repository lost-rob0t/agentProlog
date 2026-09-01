import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";

import { Bridge } from "./bridge.js";
import { ProtocolError } from "./errors.js";
import { PROTOCOL_VERSION, type RequestFrame } from "./protocol.js";

export type SpawnFunction = typeof nodeSpawn;

export interface SidecarOptions {
  readonly command: string;
  readonly args?: readonly string[];
  readonly cwd?: string;
  readonly env?: Readonly<Record<string, string>>;
  readonly spawn?: SpawnFunction;
  readonly shutdownMs?: number;
}

/**
 * Persistent sidecar transport: one long-lived Prolog process, NDJSON frames
 * over stdio, fail-closed on malformed output, early exit, or protocol
 * mismatch. Cancellation and crash semantics are terminal; the transport
 * never restarts or silently retries behind the caller's back.
 */
export class SidecarTransport extends EventEmitter {
  private readonly command: string;
  private readonly args: readonly string[];
  private readonly cwd: string | undefined;
  private readonly env: Readonly<Record<string, string>>;
  private readonly spawnFn: SpawnFunction;
  private readonly shutdownMs: number;
  private child: ChildProcess | null = null;
  private buffer = "";
  private bridge: Bridge | null = null;
  private stopping = false;

  constructor(options: SidecarOptions) {
    super();
    const { command, args = [], cwd, env = {}, spawn = nodeSpawn, shutdownMs = 2000 } = options;
    if (!command) throw new ProtocolError("bridge_spawn_failed", "sidecar command is required");
    this.command = command;
    this.args = args;
    this.cwd = cwd;
    this.env = env;
    this.spawnFn = spawn;
    this.shutdownMs = shutdownMs;
  }

  get activeBridge(): Bridge | null {
    return this.bridge;
  }

  async start(options: { sessionId?: string; requestId?: string } = {}): Promise<RuntimeDescription> {
    if (this.child) throw new ProtocolError("bridge_already_started", "sidecar already started");
    const { sessionId = "bridge", requestId = "describe-1" } = options;
    const child = this.spawnFn(this.command, [...this.args], {
      cwd: this.cwd,
      env: { ...process.env, ...this.env },
      stdio: ["pipe", "pipe", "pipe"],
      shell: false,
    });
    this.child = child;
    this.bridge = new Bridge({ send: frame => this.write(frame) });
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => this.onData(chunk));
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk: string) => this.emit("stderr", chunk));
    child.on("error", error => this.fail(new ProtocolError("bridge_spawn_failed", error.message)));
    child.on("exit", (code, signal) => {
      if (!this.stopping) this.fail(new ProtocolError("bridge_disconnected", `sidecar exited code=${code} signal=${signal}`));
      this.emit("exit", { code, signal });
      this.child = null;
    });

    const description = await this.request({
      version: PROTOCOL_VERSION,
      request_id: requestId,
      session_id: sessionId,
      operation: "runtime.describe",
      payload: {},
    }) as unknown as RuntimeDescription;
    const version = description.payload?.protocol_version ?? (description as unknown as { version?: number }).version;
    if (version !== PROTOCOL_VERSION) {
      await this.stop();
      throw new ProtocolError("protocol_mismatch", `runtime protocol ${String(version)} is unsupported`);
    }
    const capabilities = description.payload?.capabilities ?? {};
    this.bridge.capabilities = capabilities;
    return description;
  }

  request(frame: RequestFrame): Promise<Record<string, unknown>> {
    if (!this.bridge || !this.child) {
      return Promise.reject(new ProtocolError("bridge_disconnected", "sidecar is not running"));
    }
    return this.bridge.request(frame) as unknown as Promise<Record<string, unknown>>;
  }

  capabilities(): Record<string, unknown> {
    return { ...(this.bridge?.capabilities ?? {}) };
  }

  onEvent(listener: (event: Record<string, unknown>) => void): () => void {
    this.on("event", listener);
    return () => this.off("event", listener);
  }

  async stop(reason = "plugin unload"): Promise<void> {
    if (!this.child) return;
    this.stopping = true;
    const child = this.child;
    this.bridge?.dispose(reason);
    try {
      child.stdin?.end();
    } catch {
      // stdin already destroyed; nothing further to half-close
    }
    await Promise.race([
      new Promise<void>(resolve => child.once?.("exit", () => resolve())),
      new Promise<void>(resolve => setTimeout(resolve, this.shutdownMs)),
    ]);
    if (this.child === child) child.kill?.("SIGTERM");
    this.child = null;
    this.stopping = false;
  }

  private write(frame: RequestFrame): void {
    if (!this.child?.stdin?.writable) {
      throw new ProtocolError("bridge_disconnected", "sidecar stdin is not writable");
    }
    this.child.stdin.write(`${JSON.stringify(frame)}\n`);
  }

  private onData(chunk: string): void {
    this.buffer += chunk;
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) break;
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      let frame: unknown;
      try {
        frame = JSON.parse(line);
      } catch {
        return this.fail(new ProtocolError("bridge_malformed_frame", "sidecar emitted invalid JSON"));
      }
      try {
        const received = this.bridge?.receive(frame as never);
        if (received?.type === "event") this.emit("event", received.value);
      } catch (error) {
        this.fail(error instanceof Error ? error : new ProtocolError("bridge_malformed_frame", String(error)));
      }
    }
  }

  private fail(error: Error): void {
    this.bridge?.dispose(error.message);
    this.emit("bridgeError", error);
  }
}

export interface RuntimeDescription {
  readonly version: number;
  readonly request_id: string;
  readonly session_id: string;
  readonly status: "ok";
  readonly payload: {
    readonly protocol_version: number;
    readonly runtime: string;
    readonly transport: string;
    readonly capabilities: Record<string, unknown>;
    readonly [key: string]: unknown;
  };
}
