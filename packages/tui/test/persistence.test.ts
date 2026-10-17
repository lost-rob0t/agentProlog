import { chmodSync, mkdtempSync, mkdirSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { prepareConversationStore, workspaceSessionId } from "../src/persistence.js";

describe("TUI session persistence identity", () => {
  it("uses a stable workspace identity and a private state file", () => {
    const sandbox = mkdtempSync(join(tmpdir(), "agentprolog-persistence-"));
    const project = join(sandbox, "project");
    mkdirSync(project);
    const state = join(sandbox, "state");
    try {
      const sessionId = workspaceSessionId(project);
      expect(sessionId).toMatch(/^tui-[a-f0-9]{32}$/);
      expect(workspaceSessionId(project)).toBe(sessionId);

      const store = prepareConversationStore({}, state, project);
      expect(store).toBe(join(state, "agentprolog", `${sessionId.slice(4)}.db`));
      expect(statSync(join(state, "agentprolog")).mode & 0o777).toBe(0o700);
      expect(statSync(store).mode & 0o777).toBe(0o600);
    } finally {
      chmodSync(sandbox, 0o700);
      rmSync(sandbox, { recursive: true, force: true });
    }
  });

  it("honors an explicit conversation store path", () => {
    expect(prepareConversationStore({ AGENTPROLOG_CONVERSATION_STORE: "/operator/session.db" })).toBe(
      "/operator/session.db",
    );
  });
});
