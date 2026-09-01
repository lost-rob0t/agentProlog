import { ProtocolError } from "./errors.js";
import { PROTOCOL_VERSION, type RequestFrame } from "./protocol.js";

/** One skill root admitted into the sidecar catalog. */
export interface SkillRoot {
  /** Provenance label; only `project` and `external` are meaningful downstream. */
  readonly source: "project" | "external";
  /** Directory containing bounded SKILL.md packages. */
  readonly path: string;
}

export interface SkillSummary {
  readonly name: string;
  readonly description: string;
}

export interface SkillTransport {
  request: (frame: RequestFrame) => Promise<Record<string, unknown>>;
}

/**
 * Skill loading against the canonical Prolog-RLM skill boundary
 * (`rlm_skill`'s confined, bounded SKILL.md packages). Loading never grants
 * execution authority: skills enter the runtime catalog as prompt units and
 * are offered to every turn through the completion skill_catalog option.
 */
export async function loadSkillRoots(transport: SkillTransport, roots: readonly SkillRoot[]): Promise<SkillSummary[]> {
  const normalized = roots.map(root => {
    if (typeof root?.path !== "string" || root.path.length === 0) {
      throw new ProtocolError("invalid_skill_root", "skill root path must be a non-empty string");
    }
    return { source: root.source ?? "external", path: root.path };
  });
  if (normalized.length === 0) return [];
  const reply = (await transport.request({
    version: PROTOCOL_VERSION,
    request_id: `skill-load-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
    session_id: "bridge",
    operation: "skill.load",
    payload: { roots: normalized },
  })) as { payload?: { skills?: SkillSummary[] } };
  return reply.payload?.skills ?? [];
}

export async function listSkills(transport: SkillTransport): Promise<SkillSummary[]> {
  const reply = (await transport.request({
    version: PROTOCOL_VERSION,
    request_id: `skill-list-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
    session_id: "bridge",
    operation: "skill.list",
    payload: {},
  })) as { payload?: { skills?: SkillSummary[] } };
  return reply.payload?.skills ?? [];
}

/**
 * Resolve skill roots from the `AGENTPROLOG_SKILLS` environment variable
 * (colon-separated directories, marked `external`) plus explicit extra
 * directories (marked `project`). Missing entries are skipped silently so a
 * dev checkout without skills still boots.
 */
export function skillRootsFromEnv(envValue: string | undefined, extraPaths: readonly string[] = []): SkillRoot[] {
  const roots: SkillRoot[] = [];
  for (const path of envValue?.split(":") ?? []) {
    if (path.trim().length > 0) roots.push({ source: "external", path });
  }
  for (const path of extraPaths) {
    if (path.trim().length > 0) roots.push({ source: "project", path });
  }
  return roots;
}
