import { describe, expect, it } from "vitest";

import { modeCommandDefinitions } from "../src/commands.js";
import { CommandId } from "@deepseek-ai/dsh-commands";
import { ModeRouter } from "../src/router.js";

function makeAgent(id: string): { id: string } {
  return { id };
}

function makeRegistry() {
  const router = new ModeRouter({ execute: async (request, mode) => ({ text: "x", provider: "p", model: null, mode }) });
  const definitions = modeCommandDefinitions({ router, sessionIdFor: agent => agent.id });
  const byName = new Map(definitions.map(definition => [definition.name, definition]));
  const dispatch = async (name: string, agent: { id: string }) =>
    byName.get(name)!.handler({
      commandId: `cmd-${name}` as CommandId,
      agent: agent as never,
      rawInput: "",
      attachments: [],
      signal: new AbortController().signal,
    });
  return { router, definitions, byName, dispatch };
}

describe("mode commands", () => {
  it("registers exactly /direct, /symbolic, /symbolic-recursive", () => {
    const { definitions } = makeRegistry();
    expect(definitions.map(definition => definition.name)).toEqual([
      "direct",
      "symbolic",
      "symbolic-recursive",
    ]);
  });

  it("each command performs the corresponding router state transition", async () => {
    const { router, dispatch } = makeRegistry();
    const session = makeAgent("session-a");

    expect(await dispatch("direct", session)).toEqual({ kind: "success", text: "Mode: direct" });
    expect(router.resolveMode("session-a")).toBe("direct");

    expect(await dispatch("symbolic", session)).toEqual({ kind: "success", text: "Mode: symbolic" });
    expect(router.resolveMode("session-a")).toBe("symbolic");

    expect(await dispatch("symbolic-recursive", session)).toEqual({ kind: "success", text: "Mode: symbolic-recursive" });
    expect(router.resolveMode("session-a")).toBe("symbolic-recursive");
  });

  it("a command on one session does not touch another session's mode", async () => {
    const { router, dispatch } = makeRegistry();
    await dispatch("symbolic", makeAgent("session-a"));
    await dispatch("symbolic-recursive", makeAgent("session-b"));
    expect(router.resolveMode("session-a")).toBe("symbolic");
    expect(router.resolveMode("session-b")).toBe("symbolic-recursive");
  });

  it("command names satisfy the DSH slash-command grammar", () => {
    const { definitions } = makeRegistry();
    for (const definition of definitions) {
      expect(definition.name).toMatch(/^[a-z][a-z0-9_-]*$/u);
      expect(definition.description.length).toBeGreaterThan(0);
    }
  });
});
