import { EventEmitter } from "node:events";
import { spawn as nodeSpawn } from "node:child_process";
import { Bridge } from "./bridge.js";
import { PROTOCOL_VERSION, ProtocolError } from "./protocol.js";

export class SidecarTransport extends EventEmitter {
  constructor({ command, args = [], cwd, env = {}, spawn = nodeSpawn, shutdownMs = 2000 }) {
    super();
    if (!command) throw new ProtocolError("bridge_spawn_failed", "sidecar command is required");
    this.command = command;
    this.args = args;
    this.cwd = cwd;
    this.env = env;
    this.spawn = spawn;
    this.shutdownMs = shutdownMs;
    this.child = null;
    this.buffer = "";
    this.bridge = null;
    this.stopping = false;
  }

  async start({ sessionId = "bridge", requestId = "describe-1" } = {}) {
    if (this.child) throw new ProtocolError("bridge_already_started", "sidecar already started");
    const child = this.spawn(this.command, this.args, {
      cwd: this.cwd,
      env: { ...process.env, ...this.env },
      stdio: ["pipe", "pipe", "pipe"],
      shell: false,
    });
    this.child = child;
    this.bridge = new Bridge({ send: frame => this.#write(frame) });
    child.stdout?.setEncoding?.("utf8");
    child.stdout?.on?.("data", chunk => this.#onData(chunk));
    child.stderr?.setEncoding?.("utf8");
    child.stderr?.on?.("data", chunk => this.emit("stderr", chunk));
    child.on?.("error", error => this.#fail(new ProtocolError("bridge_spawn_failed", error.message)));
    child.on?.("exit", (code, signal) => {
      if (!this.stopping) this.#fail(new ProtocolError("bridge_disconnected", `sidecar exited code=${code} signal=${signal}`));
      this.emit("exit", { code, signal });
      this.child = null;
    });

    const description = await this.bridge.request({
      version: PROTOCOL_VERSION,
      request_id: requestId,
      session_id: sessionId,
      operation: "runtime.describe",
      payload: {},
    });
    const version = description.payload?.protocol_version ?? description.version;
    if (version !== PROTOCOL_VERSION) {
      await this.stop();
      throw new ProtocolError("protocol_mismatch", `runtime protocol ${version} is unsupported`);
    }
    this.bridge.capabilities = description.payload?.capabilities ?? {};
    return description;
  }

  request(frame) {
    if (!this.bridge || !this.child) return Promise.reject(new ProtocolError("bridge_disconnected", "sidecar is not running"));
    return this.bridge.request(frame);
  }

  async stop(reason = "plugin unload") {
    if (!this.child) return;
    this.stopping = true;
    const child = this.child;
    this.bridge?.dispose(reason);
    try { child.stdin?.end?.(); } catch {}
    await Promise.race([
      new Promise(resolve => child.once?.("exit", resolve)),
      new Promise(resolve => setTimeout(resolve, this.shutdownMs)),
    ]);
    if (this.child === child) child.kill?.("SIGTERM");
    this.child = null;
    this.stopping = false;
  }

  #write(frame) {
    if (!this.child?.stdin?.writable) throw new ProtocolError("bridge_disconnected", "sidecar stdin is not writable");
    this.child.stdin.write(`${JSON.stringify(frame)}\n`);
  }

  #onData(chunk) {
    this.buffer += chunk;
    while (true) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) break;
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      let frame;
      try { frame = JSON.parse(line); }
      catch { return this.#fail(new ProtocolError("bridge_malformed_frame", "sidecar emitted invalid JSON")); }
      try {
        const received = this.bridge.receive(frame);
        if (received?.type === "event") this.emit("event", received.value);
      } catch (error) { this.#fail(error); }
    }
  }

  #fail(error) {
    this.bridge?.dispose(error.message);
    this.emit("bridgeError", error);
  }
}
