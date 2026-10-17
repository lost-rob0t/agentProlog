import readline from "node:readline";

import {
  executeTurnViaBridge,
  isMode,
  listSkills,
  ModeRouter,
  parseMode,
  PROTOCOL_VERSION,
  ProtocolError,
  type Bridge,
  type RequestFrame,
} from "@agentprolog/dsh";
import { helpText, parseInput, resolveModeCommand } from "./commands.js";
import { dim, Spinner } from "./render.js";

export interface AppTransport {
  request: (frame: RequestFrame) => Promise<Record<string, unknown>>;
  activeBridge: Bridge | null;
  stop: (reason?: string) => Promise<void>;
}

export interface AppOptions {
  readonly sessionId: string;
  readonly transport: AppTransport;
  readonly router: ModeRouter;
  readonly input: NodeJS.ReadableStream;
  readonly output: NodeJS.WritableStream;
  readonly tty: boolean;
}

/**
 * The terminal frontend. It is one adapter over the same canonical protocol
 * the DSH plugin uses: turns go through the ModeRouter and the Prolog sidecar
 * only; slash commands perform router state transitions; nothing here owns
 * execution semantics.
 */
export class App {
  private readonly options: AppOptions;
  private rl: readline.Interface | undefined;
  private turnActive = false;
  private stopping = false;

  constructor(options: AppOptions) {
    this.options = options;
  }

  get sessionId(): string {
    return this.options.sessionId;
  }

  banner(info: { runtime: string; protocolVersion: number; skills: readonly string[]; sidecar: string }): void {
    const { output, tty } = this.options;
    const line = (text: string): void => void output.write(`${text}\n`);
    line(`${dim(tty, "AgentProlog TUI")} — prolog-rlm runtime (protocol v${info.protocolVersion})`);
    line(dim(tty, `sidecar: ${info.sidecar}`));
    if (info.skills.length > 0) {
      line(dim(tty, `skills: ${info.skills.join(", ")}`));
    }
    line(dim(tty, "/direct  /symbolic  /symbolic-recursive  —  /help lists all commands"));
    line("");
  }

  run(onQuit: () => void): void {
    this.onQuit = onQuit;
    const rl = readline.createInterface({
      input: this.options.input,
      output: this.options.tty ? this.options.output : undefined,
      terminal: this.options.tty,
    });
    this.rl = rl;
    rl.on("line", line => {
      // Lines run strictly in arrival order, so a quit never overtakes a
      // still-settling command reply.
      this.queue = this.queue.then(() => this.handleLine(line)).catch(() => undefined);
    });
    rl.on("close", () => {
      this.closeRequested = true;
      if (this.turnActive) void this.cancelTurn();
      void this.queue.then(() => {
        if (!this.stopping) return this.stop("input closed");
      });
    });
    rl.on("SIGINT", () => {
      void this.handleInterrupt();
    });
    this.reprompt();
  }

  private onQuit: () => void = () => undefined;
  private closeRequested = false;
  private queue: Promise<void> = Promise.resolve();

  private reprompt(): void {
    if (!this.rl || this.turnActive) return;
    const mode = this.options.router.resolveMode(this.options.sessionId);
    this.rl.setPrompt(`${mode} ❯ `);
    if (this.options.tty) this.rl.prompt();
  }

  async handleLine(line: string): Promise<void> {
    const parsed = parseInput(line);
    if (!parsed) {
      this.reprompt();
      return;
    }
    try {
      if (parsed.kind === "command") {
        await this.handleCommand(parsed);
      } else {
        await this.submitTurn(parsed.text);
      }
    } catch (error) {
      // Stopping intentionally rejects in-flight requests (bridge disposal);
      // contain everything so shutdown stays graceful.
      if (!this.stopping) this.printError(error);
    }
    this.reprompt();
  }

  async handleInterrupt(): Promise<void> {
    if (this.turnActive) {
      await this.cancelTurn();
      return;
    }
    await this.stop("interrupt");
  }

  async cancelTurn(): Promise<void> {
    this.options.output.write(`${dim(this.options.tty, "… cancelling turn")}\n`);
    try {
      await this.options.transport.request({
        version: PROTOCOL_VERSION,
        request_id: `cancel-${Date.now().toString(36)}`,
        session_id: this.options.sessionId,
        operation: "session.cancel",
        payload: { cause: { kind: "user" } },
      });
    } catch (error) {
      this.printError(error);
    }
  }

  async stop(reason: string): Promise<void> {
    if (this.stopping) return;
    this.stopping = true;
    this.rl?.close();
    this.rl = undefined;
    await this.options.transport.stop(reason);
    this.options.output.write(`${dim(this.options.tty, "goodbye")}\n`);
    this.onQuit();
  }

  private async handleCommand(parsed: { name: string; args: string }): Promise<void> {
    const modeCommand = resolveModeCommand(parsed.name);
    if (modeCommand) {
      await this.setMode(modeCommand);
      this.printLine(`◈ Mode: ${modeCommand}`);
      return;
    }
    switch (parsed.name) {
      case "mode": {
        if (parsed.args) {
          if (!isMode(parsed.args)) {
            this.printLine(`✗ unknown mode "${parsed.args}" — one of: direct, symbolic, symbolic-recursive`);
            return;
          }
          await this.setMode(parseMode(parsed.args));
          this.printLine(`◈ Mode: ${parsed.args}`);
          return;
        }
        const state = await this.inspectSession();
        this.printLine(`Mode: ${state.mode}`);
        return;
      }
      case "status": {
        const state = await this.inspectSession();
        this.printLine(`Session: ${state.session_id} · mode: ${state.mode} · ${state.busy ? "running" : "idle"}`);
        return;
      }
      case "tools": {
        const result = await this.request("tool.list");
        const tools = Array.isArray(result.tools) ? result.tools : [];
        if (tools.length === 0) this.printLine("No tools registered for this session.");
        for (const tool of tools) {
          if (typeof tool === "object" && tool !== null && typeof tool.name === "string") {
            this.printLine(`• ${tool.name}${typeof tool.description === "string" ? ` — ${tool.description}` : ""}`);
          }
        }
        return;
      }
      case "skill": {
        if (parsed.args === "reset") {
          const result = await this.request("skill.reset");
          this.printLine(`Skills reset (${Array.isArray(result.skills) ? result.skills.length : 0} core skills).`);
          return;
        }
        if (parsed.args.startsWith("load ") && parsed.args.slice(5).trim()) {
          const path = parsed.args.slice(5).trim();
          const result = await this.request("skill.load", { roots: [{ source: "project", path }] });
          this.printLine(`Skills loaded (${String(result.loaded ?? 0)} total).`);
          return;
        }
        this.printLine("Usage: /skill load <root> | /skill reset");
        return;
      }
      case "skills": {
        const skills = await listSkills(this.options.transport);
        if (skills.length === 0) {
          this.printLine(dim(this.options.tty, "no skills loaded — set AGENTPROLOG_SKILLS or create ./skills"));
          return;
        }
        for (const skill of skills) {
          this.printLine(`• ${skill.name}${skill.description ? ` — ${skill.description}` : ""}`);
        }
        return;
      }
      case "help": {
        this.printLine(helpText());
        return;
      }
      case "clear": {
        if (this.options.tty) this.options.output.write("\x1b[2J\x1b[H");
        return;
      }
      case "quit":
      case "exit": {
        await this.stop("quit command");
        return;
      }
      default: {
        this.printLine(`✗ unknown command /${parsed.name} — /help lists commands`);
      }
    }
  }

  private async request(operation: string, payload: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    const response = await this.options.transport.request({
      version: PROTOCOL_VERSION,
      request_id: `tui-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`,
      session_id: this.options.sessionId,
      operation,
      payload,
    });
    return (response.payload ?? {}) as Record<string, unknown>;
  }

  private async inspectSession(): Promise<{ session_id: string; mode: string; busy: boolean }> {
    const state = await this.request("session.inspect");
    if (
      state.session_id !== this.options.sessionId ||
      !isMode(state.mode) ||
      typeof state.busy !== "boolean"
    ) {
      throw new ProtocolError("invalid_session_state", "sidecar returned incomplete or mismatched session inspection");
    }
    return { session_id: state.session_id, mode: state.mode, busy: state.busy };
  }

  private async setMode(mode: ReturnType<typeof parseMode>): Promise<void> {
    const result = await this.request("session.mode", { mode });
    if (result.mode !== mode) throw new Error("sidecar returned a different mode");
    this.options.router.setMode(this.options.sessionId, mode);
  }

  private async submitTurn(text: string): Promise<void> {
    if (this.turnActive) {
      this.printLine(dim(this.options.tty, "… a turn is already running; Ctrl+C cancels it"));
      return;
    }
    const mode = this.options.router.resolveMode(this.options.sessionId);
    this.printLine(dim(this.options.tty, `❯ ${text}`));
    this.turnActive = true;
    const spinner = new Spinner(this.options.output, this.options.tty, mode);
    spinner.start();
    try {
      const outcome = await this.options.router.executeTurn({
        sessionId: this.options.sessionId,
        text,
      });
      spinner.stop();
      this.printLine(`⏺ ${outcome.text}`);
      this.printLine(dim(this.options.tty, `  ${outcome.provider}/${outcome.model ?? "default"} · mode: ${outcome.mode}`));
    } catch (error) {
      spinner.stop();
      this.printError(error);
    } finally {
      this.turnActive = false;
    }
  }

  private printError(error: unknown): void {
    const protocol = error as { code?: string; message?: string };
    const code = typeof protocol?.code === "string" ? protocol.code : "error";
    const message = error instanceof Error ? error.message : String(error);
    this.printLine(`✗ [${code}] ${message}`);
  }

  private printLine(text: string): void {
    this.options.output.write(`${text}\n`);
  }
}
