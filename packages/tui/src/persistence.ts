import { closeSync, chmodSync, mkdirSync, openSync, realpathSync } from "node:fs";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

function projectKey(projectRoot: string): string {
  return createHash("sha256").update(realpathSync(projectRoot)).digest("hex").slice(0, 32);
}

/** Stable identity lets a later TUI process reopen this workspace conversation. */
export function workspaceSessionId(projectRoot: string): string {
  return `tui-${projectKey(projectRoot)}`;
}

/**
 * Prepare a private per-workspace conversation store. An explicit store path
 * stays under operator control; the default is private local application state.
 */
export function prepareConversationStore(
  env: NodeJS.ProcessEnv = process.env,
  stateHome = env.XDG_STATE_HOME ?? join(homedir(), ".local", "state"),
  projectRoot = process.cwd(),
): string {
  if (env.AGENTPROLOG_CONVERSATION_STORE) return env.AGENTPROLOG_CONVERSATION_STORE;

  const directory = join(stateHome, "agentprolog");
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  chmodSync(directory, 0o700);
  const storePath = join(directory, `${projectKey(projectRoot)}.db`);
  const fd = openSync(storePath, "a", 0o600);
  closeSync(fd);
  chmodSync(storePath, 0o600);
  return storePath;
}
