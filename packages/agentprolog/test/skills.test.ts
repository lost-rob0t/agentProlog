import { describe, expect, it } from "vitest";

import { PROTOCOL_VERSION, type RequestFrame } from "../src/protocol.js";
import { loadSkillRoots, skillRootsFromEnv, type SkillRoot, type SkillSummary } from "../src/skills.js";

type TransportStub = { request: (frame: RequestFrame) => Promise<Record<string, unknown>>; sent: RequestFrame[] };

function stubTransport(respond: (frame: RequestFrame) => Record<string, unknown>): TransportStub {
  const sent: RequestFrame[] = [];
  return {
    sent,
    request: async frame => {
      sent.push(frame);
      return respond(frame);
    },
  };
}

describe("skill loading", () => {
  it("parses AGENTPROLOG_SKILLS as colon-separated external roots", () => {
    expect(skillRootsFromEnv("/a/skills:/b/skills")).toEqual([
      { source: "external", path: "/a/skills" },
      { source: "external", path: "/b/skills" },
    ]);
    expect(skillRootsFromEnv(undefined)).toEqual([]);
    expect(skillRootsFromEnv("::")).toEqual([]);
  });

  it("marks explicit extra paths as project roots", () => {
    expect(skillRootsFromEnv("/env/root", ["./skills", ""])).toEqual([
      { source: "external", path: "/env/root" },
      { source: "project", path: "./skills" },
    ]);
  });

  it("loadSkillRoots shapes the canonical skill.load frame", async () => {
    const transport = stubTransport(() => ({
      payload: { skills: [{ name: "demo-skill", description: "a demo" }] },
    }));
    const skills: SkillSummary[] = await loadSkillRoots(transport, [
      { source: "project", path: "test/fixtures/skills" },
    ]);
    expect(transport.sent[0]).toMatchObject({
      version: PROTOCOL_VERSION,
      operation: "skill.load",
      payload: { roots: [{ source: "project", path: "test/fixtures/skills" }] },
    });
    expect(skills).toEqual([{ name: "demo-skill", description: "a demo" }]);
  });

  it("rejects an empty root path before sending anything", async () => {
    const transport = stubTransport(() => ({}));
    await expect(loadSkillRoots(transport, [{ source: "external", path: "" }])).rejects.toMatchObject({
      code: "invalid_skill_root",
    });
    expect(transport.sent).toHaveLength(0);
  });

  it("loadSkillRoots with no roots is a local no-op", async () => {
    const transport = stubTransport(() => {
      throw new Error("must not be called");
    });
    expect(await loadSkillRoots(transport, [])).toEqual([]);
    expect(transport.sent).toHaveLength(0);
  });
});
