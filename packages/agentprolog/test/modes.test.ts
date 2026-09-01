import { describe, expect, it } from "vitest";

import { DEFAULT_MODE, isMode, modeLabel, parseMode, AGENTPROLOG_MODES } from "../src/modes.js";

describe("agentProlog modes", () => {
  it("exposes exactly the three supported modes", () => {
    expect([...AGENTPROLOG_MODES]).toEqual(["direct", "symbolic", "symbolic-recursive"]);
  });

  it("defaults to direct", () => {
    expect(DEFAULT_MODE).toBe("direct");
  });

  it("parses every supported mode", () => {
    for (const mode of AGENTPROLOG_MODES) {
      expect(parseMode(mode)).toBe(mode);
      expect(isMode(mode)).toBe(true);
    }
  });

  it("rejects invalid modes instead of coercing", () => {
    expect(() => parseMode("auto")).toThrow(/unknown agentProlog mode/);
    expect(() => parseMode("Symbolic")).toThrow(/unknown agentProlog mode/);
    expect(() => parseMode("")).toThrow(/unknown agentProlog mode/);
    expect(() => parseMode(undefined)).toThrow(/unknown agentProlog mode/);
    expect(() => parseMode(42)).toThrow(/unknown agentProlog mode/);
    expect(isMode("auto")).toBe(false);
  });

  it("labels modes for command results", () => {
    expect(modeLabel("direct")).toBe("direct");
    expect(modeLabel("symbolic")).toBe("symbolic");
    expect(modeLabel("symbolic-recursive")).toBe("symbolic-recursive");
  });
});
