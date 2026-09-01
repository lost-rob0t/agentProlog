#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";

import {
  executeTurnViaBridge,
  loadSkillRoots,
  ModeRouter,
  PROTOCOL_VERSION,
  SidecarTransport,
  skillRootsFromEnv,
  type SkillSummary,
} from "@agentprolog/dsh";
import { App } from "./app.js";

/** Minimal .env reader (KEY=VALUE lines); never overrides existing env. */
function loadEnvFile(path: string): void {
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const separator = trimmed.indexOf("=");
    if (separator <= 0) continue;
    const key = trimmed.slice(0, separator).trim();
    const value = trimmed.slice(separator + 1).trim();
    if (process.env[key] === undefined) process.env[key] = value;
  }
}

function directoryExists(path: string): boolean {
  try {
    return existsSync(path);
  } catch {
    return false;
  }
}

async function main(): Promise<number> {
  loadEnvFile(".env");
  const sidecarCommand = process.env.AGENTPROLOG_SIDECAR ?? "agentprolog-sidecar";
  const model = process.env.AGENTPROLOG_MODEL ?? process.env.OPENROUTER_MODEL ?? null;
  const sessionId = `tui-${Date.now().toString(36)}`;

  const transport = new SidecarTransport({ command: sidecarCommand });
  let description: Awaited<ReturnType<SidecarTransport["start"]>>;
  try {
    description = await transport.start();
  } catch (error) {
    process.stderr.write(
      `agentprolog-tui: cannot start the Prolog sidecar (${sidecarCommand}).\n` +
        "Run inside the flake dev shell (nix develop / direnv) or set AGENTPROLOG_SIDECAR.\n" +
        `reason: ${error instanceof Error ? error.message : String(error)}\n`,
    );
    return 1;
  }

  await transport.request({
    version: PROTOCOL_VERSION,
    request_id: `start-${Date.now().toString(36)}`,
    session_id: sessionId,
    operation: "session.start",
    payload: { cwd: process.cwd() },
  });

  const skillRoots = skillRootsFromEnv(process.env.AGENTPROLOG_SKILLS, [
    directoryExists("skills") ? "skills" : "",
  ]);
  let skills: SkillSummary[] = [];
  if (skillRoots.length > 0) {
    try {
      skills = await loadSkillRoots(transport, skillRoots);
    } catch (error) {
      // Dev-loop friendliness: a broken skills directory must not block the
      // session; the failure is loud, not silent.
      process.stderr.write(
        `agentprolog-tui: skill loading failed: ${error instanceof Error ? error.message : String(error)}\n`,
      );
    }
  }

  const router = new ModeRouter({
    execute: (request, mode) =>
      executeTurnViaBridge(transport.activeBridge!, {
        sessionId: request.sessionId,
        text: request.text,
        mode,
        options: { provider: "openrouter", ...(model === null ? {} : { model }) },
      }),
  });

  const app = new App({
    sessionId,
    transport,
    router,
    input: process.stdin,
    output: process.stdout,
    tty: Boolean(process.stdout.isTTY),
  });
  app.banner({
    runtime: String(description.payload.runtime),
    protocolVersion: description.payload.protocol_version,
    skills: skills.map(skill => skill.name),
    sidecar: sidecarCommand,
  });

  if (process.env.AGENTPROLOG_VERBOSE) {
    transport.onEvent(event => {
      process.stdout.write(`\n${JSON.stringify(event)}\n`);
    });
  }

  await new Promise<void>(resolve => {
    app.run(resolve);
  });
  return 0;
}

main()
  .then(code => process.exit(code))
  .catch((error: unknown) => {
    process.stderr.write(`agentprolog-tui: fatal: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  });
