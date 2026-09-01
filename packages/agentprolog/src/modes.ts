import { ModeError } from "./errors.js";

/**
 * The authoritative agentProlog reasoning modes.
 *
 * These are canonical state, never string-scattered: every consumer parses
 * through {@link parseMode} / {@link isMode}, and the sidecar validates the
 * same closed set.
 */
export const AGENTPROLOG_MODES = ["direct", "symbolic", "symbolic-recursive"] as const;

export type AgentPrologMode = (typeof AGENTPROLOG_MODES)[number];

/** Deterministic session default: the lowest-overhead path. */
export const DEFAULT_MODE: AgentPrologMode = "direct";

export function isMode(value: unknown): value is AgentPrologMode {
  return typeof value === "string" && (AGENTPROLOG_MODES as readonly string[]).includes(value);
}

export function parseMode(value: unknown): AgentPrologMode {
  if (isMode(value)) return value;
  throw new ModeError(`unknown agentProlog mode: ${typeof value === "string" ? JSON.stringify(value) : String(value)}`);
}

/** Human-facing label used by command results and diagnostics. */
export function modeLabel(mode: AgentPrologMode): string {
  return mode;
}
