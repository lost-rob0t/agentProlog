import { AGENTPROLOG_MODES, isMode, modeLabel, type AgentPrologMode } from "@agentprolog/dsh";

export type ParsedInput =
  | { kind: "command"; name: string; args: string }
  | { kind: "message"; text: string };

/**
 * Split one input line into a slash command (local, UI-side) or a user
 * message (submitted as a canonical turn). Blank lines yield undefined.
 */
export function parseInput(line: string): ParsedInput | undefined {
  const trimmed = line.trim();
  if (!trimmed) return undefined;
  if (!trimmed.startsWith("/")) return { kind: "message", text: trimmed };
  const withoutSlash = trimmed.slice(1);
  const separator = withoutSlash.indexOf(" ");
  const name = (separator < 0 ? withoutSlash : withoutSlash.slice(0, separator)).toLowerCase();
  const args = separator < 0 ? "" : withoutSlash.slice(separator + 1).trim();
  return { kind: "command", name, args };
}

/** The canonical mode commands; everything else is TUI-local. */
export const MODE_COMMANDS: Readonly<Record<string, AgentPrologMode>> = Object.freeze(
  Object.fromEntries(AGENTPROLOG_MODES.map(mode => [mode, mode])),
);

export function resolveModeCommand(name: string): AgentPrologMode | undefined {
  const mode = MODE_COMMANDS[name];
  return isMode(mode) ? mode : undefined;
}

export function modeLabelFor(mode: AgentPrologMode): string {
  return modeLabel(mode);
}

export function helpText(): string {
  return [
    "/direct               switch to direct mode (no symbolic planning, no recursion)",
    "/symbolic             switch to symbolic mode (typed plans, single recursion level)",
    "/symbolic-recursive   switch to symbolic-recursive mode (bounded recursive decomposition)",
    "/mode [name]          show the current mode, or set it",
    "/skills               list skills loaded into the runtime catalog",
    "/clear                clear the transcript",
    "/quit                 exit (Ctrl+D; Ctrl+C cancels a running turn first)",
  ].join("\n");
}
