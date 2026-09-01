import { PassThrough, Writable } from "node:stream";

import { describe, expect, it } from "vitest";

import { SidecarTransport } from "@agentprolog/dsh";

const SIDECAR = process.env.AGENTPROLOG_SIDECAR;

describe.skipIf(!SIDECAR)("TUI headless smoke over the real sidecar (keyless)", () => {
  it("boots, switches modes, lists skills, and exits through the canonical protocol", async () => {
    const transport = new SidecarTransport({ command: SIDECAR! });
    const output = new Writable({
      write(chunk: unknown, _encoding, callback) {
        outputBuffer.text += String(chunk);
        callback();
      },
    });
    const outputBuffer = { text: "" };
    const input = new PassThrough();

    await transport.start();
    const sessionId = "tui-smoke";
    await transport.request({
      version: 1, request_id: "start-1", session_id: sessionId, operation: "session.start",
      payload: { cwd: process.cwd() },
    });

    const { App } = await import("../src/app.js");
    const { ModeRouter, executeTurnViaBridge } = await import("@agentprolog/dsh");
    const router = new ModeRouter({
      execute: (request, mode) =>
        executeTurnViaBridge(transport.activeBridge!, {
          sessionId: request.sessionId,
          text: request.text,
          mode,
          options: { provider: "openrouter" },
        }),
    });

    const app = new App({
      sessionId,
      transport,
      router,
      input,
      output,
      tty: false,
    });
    app.banner({
      runtime: "prolog-rlm",
      protocolVersion: 1,
      skills: [],
      sidecar: SIDECAR!,
    });

    const quit = new Promise<void>(resolve => {
      app.run(resolve);
    });

    input.write("/symbolic\n");
    await new Promise(resolve => setTimeout(resolve, 300));
    expect(outputBuffer.text).toContain("◈ Mode: symbolic");

    input.write("/skills\n");
    await new Promise(resolve => setTimeout(resolve, 400));
    expect(outputBuffer.text).toContain("no skills loaded");

    input.write("/quit\n");
    await quit;
    expect(outputBuffer.text).toContain("goodbye");
  }, 30000);
});
