import { CommandId, type CommandDefinition, type CommandResult } from "@deepseek-ai/dsh-commands";

/** Minimal recording stand-in for the DSH services the plugin consumes. */
export interface FakeCommandRegistry {
  readonly registered: CommandDefinition[];
  register: (definition: CommandDefinition) => () => void;
  /** Dispatch by command name; returns the handler's result. */
  dispatch: (name: string, agent: { id: string }, rawInput?: string) => Promise<CommandResult>;
}

export interface FakeAgentRegistry {
  readonly factories: unknown[];
  setFactory: (factory: unknown) => () => void;
}

export interface FakeSessionService {
  prepare: (id: string, options?: unknown) => FakeSession;
  readonly sessions: Map<string, FakeSession>;
}

export interface FakeSession {
  readonly id: string;
  readonly header: { seedLength: number };
  readonly events: Array<{ type: string; data: unknown; seq: number }>;
  options?: unknown;
  append: (type: string, data: unknown, options?: unknown) => { type: string; data: unknown };
}

export interface FakeContextOptions {
  readonly withCommands?: boolean;
  readonly withAgents?: boolean;
  readonly withSessions?: boolean;
}

export interface FakeContext {
  effects: Array<() => void>;
  services: Map<string, unknown>;
  events: Array<{ name: string; args: unknown[] }>;
  effect: (body: () => unknown, label?: string) => void;
  provide: (name: string, service: unknown) => () => void;
  emit: (name: string, ...args: unknown[]) => void;
  logger: { info: (message: string) => void; warn: (message: string) => void };
  commands?: FakeCommandRegistry;
  agents?: FakeAgentRegistry;
  sessions?: FakeSessionService;
}

let seq = 0;

export function makeFakeSession(id: string): FakeSession {
  const session: FakeSession = {
    id,
    header: { seedLength: 0 },
    events: [],
    append(type, data) {
      seq += 1;
      const event = { type, data, seq };
      session.events.push(event);
      return event;
    },
  };
  return session;
}

export function makeFakeContext(options: FakeContextOptions = {}): FakeContext {
  const { withCommands = true, withAgents = true, withSessions = true } = options;
  const ctx: FakeContext = {
    effects: [],
    services: new Map(),
    events: [],
    effect(body) {
      // Mirror the real contract: the body runs at load; its return value is
      // the cleanup disposer.
      const cleanup = body();
      if (typeof cleanup === "function") ctx.effects.push(cleanup as () => void);
    },
    provide(name, service) {
      ctx.services.set(name, service);
      return () => ctx.services.delete(name);
    },
    emit(name, ...args) {
      ctx.events.push({ name, args });
    },
    logger: {
      info: () => undefined,
      warn: () => undefined,
    },
  };
  if (withCommands) {
    const registered: CommandDefinition[] = [];
    ctx.commands = {
      registered,
      register(definition) {
        registered.push(definition);
        return () => {
          const index = registered.indexOf(definition);
          if (index >= 0) registered.splice(index, 1);
        };
      },
      async dispatch(name, agent, rawInput = "") {
        const definition = registered.find(command => command.name === name);
        if (!definition) return { kind: "error", text: `unknown command: ${name}` };
        return definition.handler({
          commandId: `cmd-test-${name}` as CommandId,
          agent: agent as never,
          rawInput,
          attachments: [],
          signal: new AbortController().signal,
        });
      },
    };
  }
  if (withAgents) {
    const factories: unknown[] = [];
    ctx.agents = {
      factories,
      setFactory(factory) {
        factories.push(factory);
        return () => {
          const index = factories.indexOf(factory);
          if (index >= 0) factories.splice(index, 1);
        };
      },
    };
  }
  if (withSessions) {
    const sessions = new Map<string, FakeSession>();
    ctx.sessions = {
      sessions,
      prepare(id, sessionOptions) {
        const session = makeFakeSession(id);
        session.options = sessionOptions;
        sessions.set(id, session);
        return session;
      },
    };
  }
  return ctx;
}

export const HARNESS = Object.freeze({
  version: "0.1.1-rc.2",
  revision: "b150a551b8d465e31e418e1b2eaf5e79bbb7d28e",
});
