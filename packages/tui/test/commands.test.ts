import { describe, expect, it } from "vitest";

import { helpText, parseInput, resolveModeCommand } from "../src/commands.js";

describe("TUI input parsing", () => {
  it("parses blank lines as undefined", () => {
    expect(parseInput("")).toBeUndefined();
    expect(parseInput("   \t ")).toBeUndefined();
  });

  it("parses ordinary text as a message", () => {
    expect(parseInput("refactor the parser module")).toEqual({
      kind: "message",
      text: "refactor the parser module",
    });
  });

  it("parses slash commands with and without args", () => {
    expect(parseInput("/symbolic")).toEqual({ kind: "command", name: "symbolic", args: "" });
    expect(parseInput("/mode symbolic-recursive")).toEqual({ kind: "command", name: "mode", args: "symbolic-recursive" });
    expect(parseInput("/MODE")).toEqual({ kind: "command", name: "mode", args: "" });
  });

  it("recognizes exactly the three mode commands", () => {
    expect(resolveModeCommand("direct")).toBe("direct");
    expect(resolveModeCommand("symbolic")).toBe("symbolic");
    expect(resolveModeCommand("symbolic-recursive")).toBe("symbolic-recursive");
    expect(resolveModeCommand("auto")).toBeUndefined();
    expect(resolveModeCommand("mode")).toBeUndefined();
  });

  it("help text lists every registered command", () => {
    const help = helpText();
    expect(help).toContain("/direct");
    expect(help).toContain("/symbolic");
    expect(help).toContain("/symbolic-recursive");
    expect(help).toContain("/mode");
    expect(help).toContain("/skills");
    expect(help).toContain("/clear");
    expect(help).toContain("/quit");
  });
});
