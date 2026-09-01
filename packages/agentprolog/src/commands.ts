import type { CommandDefinition, CommandResult } from "@deepseek-ai/dsh-commands";
import { AGENTPROLOG_MODES, modeLabel, type AgentPrologMode } from "./modes.js";
import type { ModeRouter } from "./router.js";

export interface ModeCommandDeps {
  readonly router: ModeRouter;
  /** Resolves the session a command invocation applies to. */
  readonly sessionIdFor: (agent: { readonly id: string }) => string;
}

/**
 * The three canonical mode commands. Each handler performs a real, observable
 * router state transition — no prompt text asks any model to "interpret" a
 * command. The dispatching UI (web, TUI, headless) renders the returned
 * result text, keeping agentProlog presentation-free.
 */
export function modeCommandDefinitions({ router, sessionIdFor }: ModeCommandDeps): CommandDefinition[] {
  const definitions: CommandDefinition[] = [];
  for (const mode of AGENTPROLOG_MODES) {
    definitions.push({
      name: commandNameFor(mode),
      description: DESCRIPTIONS[mode],
      handler: (invocation): CommandResult => {
        const sessionId = sessionIdFor(invocation.agent);
        router.setMode(sessionId, mode as AgentPrologMode);
        return { kind: "success", text: `Mode: ${modeLabel(mode as AgentPrologMode)}` };
      },
    });
  }
  return definitions;
}

function commandNameFor(mode: AgentPrologMode): string {
  // Command names are lowercase with dashes; modes already match that grammar.
  return mode;
}

const DESCRIPTIONS: Record<AgentPrologMode, string> = {
  direct: "Switch this session to direct mode: native model/tool execution without symbolic planning or recursion.",
  symbolic: "Switch this session to symbolic mode: Prolog-RLM typed-plan supervision over the configured model.",
  "symbolic-recursive": "Switch this session to symbolic-recursive mode: bounded recursive Prolog-RLM decomposition with explicit iteration caps.",
};
