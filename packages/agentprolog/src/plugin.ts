import type { Context } from "@deepseek-ai/cordis";
import type { CommandRuntime } from "@deepseek-ai/dsh-commands";

import { executeTurnViaBridge, type AdapterOptions } from "./adapters.js";
import { assertHarnessCompatibility, type HarnessIdentity } from "./compatibility.js";
import { modeCommandDefinitions } from "./commands.js";
import { PrologAgentFactory } from "./agent-factory.js";
import { DEFAULT_MODE, parseMode, type AgentPrologMode } from "./modes.js";
import { ModeRouter } from "./router.js";
import { SidecarTransport } from "./sidecar.js";
import { loadSkillRoots, type SkillRoot } from "./skills.js";

export const name = "agentprolog";
export const inject = ["agents", "sessions", "commands"] as const;
export const SERVICE_NAME = "agentprolog";

export interface AgentPrologDefaults {
  readonly mode?: AgentPrologMode;
  readonly provider?: string;
  readonly model?: string | null;
  readonly maxRecursionDepth?: number;
}

export interface SkillRootsConfig {
  readonly roots: readonly SkillRoot[];
}

export interface AgentPrologPluginConfig {
  /** Nix-pinned sidecar command, e.g. the flake's agentprolog-sidecar wrapper. */
  readonly command: string;
  readonly args?: readonly string[];
  readonly cwd?: string;
  readonly env?: Readonly<Record<string, string>>;
  readonly shutdownMs?: number;
  readonly harness: HarnessIdentity;
  readonly defaults?: AgentPrologDefaults;
  /** Skill roots admitted into the runtime catalog before any turn runs. */
  readonly skills?: SkillRootsConfig;
}

export interface AgentPrologService {
  readonly request: (frame: Parameters<SidecarTransport["request"]>[0]) => ReturnType<SidecarTransport["request"]>;
  readonly describe: () => unknown;
  readonly capabilities: () => Record<string, unknown>;
  readonly router: ModeRouter;
}

/**
 * The AgentProlog DSH plugin: one out-of-tree plugin owns the persistent
 * Prolog bridge, the session-scoped mode router, the /direct, /symbolic and
 * /symbolic-recursive commands, and the single authoritative AgentFactory.
 * DSH stays the harness (sessions, tools, approvals, events); Prolog-RLM owns
 * canonical execution semantics. Symbolic failures propagate fail-closed —
 * there is no silent fallback to direct mode.
 */
export interface PluginDeps {
  /** Injectable for tests; production uses the real sidecar transport. */
  readonly Transport?: typeof SidecarTransport;
}

export async function apply(
  ctx: Context,
  config: AgentPrologPluginConfig,
  deps: PluginDeps = {},
): Promise<AgentPrologService> {
  if (!ctx || typeof (ctx as { effect?: unknown }).effect !== "function") {
    throw new Error("cordis context with effect() is required");
  }
  const agents = (ctx as unknown as { agents?: { setFactory?: unknown } }).agents;
  const sessions = (ctx as unknown as { sessions?: unknown }).sessions;
  if (!agents || typeof agents.setFactory !== "function" || !sessions) {
    throw new Error("DSH agents and sessions services are required");
  }
  if (!config.command) {
    throw new Error("Nix-pinned sidecar command is required");
  }
  assertHarnessCompatibility(config.harness);

  const defaults = config.defaults ?? {};
  const defaultMode = defaults.mode === undefined ? DEFAULT_MODE : parseMode(defaults.mode);
  const turnOptions: AdapterOptions = {
    ...(defaults.provider === undefined ? {} : { provider: defaults.provider }),
    ...(defaults.model === undefined ? {} : { model: defaults.model }),
    ...(defaults.maxRecursionDepth === undefined ? {} : { maxRecursionDepth: defaults.maxRecursionDepth }),
  };

  const hostLogger = (ctx as unknown as { logger?: { info?: (message: string) => void; warn?: (message: string) => void } }).logger;
  const logger = {
    info: (message: string) => hostLogger?.info?.(message),
    warn: (message: string) => hostLogger?.warn?.(message),
  };
  const hostEmit = (ctx as unknown as { emit?: (event: string, ...args: unknown[]) => void }).emit;
  const emit = (event: string, ...args: unknown[]) => hostEmit?.(event, ...args);
  const observeModeChange = (event: { sessionId: string; from: string; to: string }): void => {
    emit("agentprolog/mode/change", event);
    logger.info(`agentprolog mode session=${event.sessionId} from=${event.from} to=${event.to}`);
  };

  const Transport = deps.Transport ?? SidecarTransport;
  const transport = new Transport({
    command: config.command,
    args: config.args ?? [],
    cwd: config.cwd,
    env: { ...config.env },
    shutdownMs: config.shutdownMs,
  });
  ctx.effect(() => () => void transport.stop("Cordis plugin unload"));
  const removeEvents = transport.onEvent(event => {
    emit("agentprolog/runtime/event", event);
    logger.info(`agentprolog runtime event session=${String(event.session_id)} run=${String(event.run_id)} event=${String(event.event)} sequence=${String(event.sequence)}`);
  });

  let removeCommands: (() => void) | undefined;
  let removeService: (() => void) | undefined;
  let removeFactory: (() => void) | undefined;

  try {
    const description = await transport.start();

    // Fail-closed skill admission: an explicit but invalid skills config
    // aborts startup instead of silently running without skills.
    if (config.skills?.roots?.length) {
      const skills = await loadSkillRoots(transport, config.skills.roots);
      logger.info(`agentprolog skills loaded count=${skills.length}`);
    }

    const service: AgentPrologService = {
      request: frame => transport.request(frame),
      describe: () => description,
      capabilities: () => transport.capabilities(),
      router: undefined as never,
    };

    const router = new ModeRouter({
      defaultMode,
      onModeChange: observeModeChange,
      onTurnSettled: record => {
        emit("agentprolog/turn/settled", record);
        logger.info(
          `agentprolog turn session=${record.sessionId} mode=${record.mode} backend=${record.backend} ` +
          `duration_ms=${record.durationMs} cancelled=${record.cancelled}${record.error === undefined ? "" : ` error=${record.error}`}`,
        );
      },
      execute: (request, mode) => executeTurnViaBridge(transport.activeBridge!, {
        sessionId: request.sessionId,
        text: request.text,
        mode,
        options: turnOptions,
      }),
    });
    (service as { router: ModeRouter }).router = router;

    const factory = new PrologAgentFactory(
      ctx,
      transport.activeBridge!,
      router,
      {
        prepareSession: (id, sessionOptions) => (sessions as {
          prepare: (id: string, options: unknown) => never;
        }).prepare(id, sessionOptions),
      },
      { turn: turnOptions },
    );

    // AgentRegistry.setFactory fails while the stock agent-loop is mounted —
    // the Prolog profile must have exactly one factory.
    removeFactory = (agents as { setFactory: (factory: PrologAgentFactory) => () => void }).setFactory(factory);

    const commands = (ctx as unknown as { commands?: CommandRuntime }).commands;
    if (commands && typeof commands.register === "function") {
      for (const definition of modeCommandDefinitions({
        router,
        sessionIdFor: agent => agent.id,
      })) {
        const remove = commands.register(definition);
        const previous = removeCommands;
        removeCommands = () => {
          previous?.();
          remove();
        };
      }
    } else {
      logger.warn("agentprolog: ctx.commands is unavailable; mode commands were not registered");
    }

    removeService = (ctx as unknown as { provide: (name: string, service: AgentPrologService) => () => void }).provide(SERVICE_NAME, service);
    logger.info(`agentprolog plugin ready default_mode=${defaultMode} sidecar_protocol=${description.payload.protocol_version}`);
    return service;
  } catch (error) {
    try {
      removeCommands?.();
    } catch {
      // disposal best-effort during failed startup
    }
    try {
      removeService?.();
    } catch {
      // disposal best-effort during failed startup
    }
    try {
      removeFactory?.();
    } catch {
      // disposal best-effort during failed startup
    }
    try {
      removeEvents?.();
    } catch {
      // disposal best-effort during failed startup
    }
    await transport.stop("plugin startup failed");
    throw error;
  }
}
