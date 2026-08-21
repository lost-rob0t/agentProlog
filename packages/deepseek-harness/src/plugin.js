import { ProtocolError } from "./protocol.js";
import { SidecarTransport } from "./sidecar.js";
import { assertHarnessCompatibility } from "./compatibility.js";

export const SERVICE_NAME = "agentPrologRlm";

/**
 * Narrow Cordis-facing lifecycle wrapper.
 *
 * The context owns publication and cleanup; the transport owns the persistent
 * Prolog process. Runtime scheduling, authority, verification, evolution and
 * subagent decisions remain on the Prolog side of the protocol.
 */
export async function apply(ctx, config = {}, { Transport = SidecarTransport } = {}) {
  if (!ctx || typeof ctx.effect !== "function") {
    throw new ProtocolError("cordis_context_required", "Cordis context with effect() is required");
  }
  if (!config.command) {
    throw new ProtocolError("bridge_spawn_failed", "Nix-pinned sidecar command is required");
  }
  if (!config.harness) {
    throw new ProtocolError("harness_identity_required", "Pinned DeepSeek Harness version and revision are required");
  }

  // Fail before spawning any process or publishing any Cordis service. Harness
  // is developer preview; compatibility is an explicit host boundary, not a
  // best-effort warning after resources already exist.
  assertHarnessCompatibility(config.harness);

  const transport = new Transport({
    command: config.command,
    args: config.args ?? ["--stdio"],
    cwd: config.cwd,
    env: config.env ?? {},
    shutdownMs: config.shutdownMs ?? 2000,
  });

  let published = false;
  let removeService = null;

  const dispose = ctx.effect(async () => {
    if (published) {
      try { await removeService?.(); } finally { published = false; }
    }
    await transport.stop("Cordis plugin unload");
  });

  try {
    const description = await transport.start();
    const service = Object.freeze({
      request: frame => transport.request(frame),
      onEvent: listener => {
        transport.on("event", listener);
        return () => transport.off("event", listener);
      },
      describe: () => description,
      capabilities: () => Object.freeze({ ...(transport.bridge?.capabilities ?? {}) }),
    });

    if (typeof ctx.provide === "function") {
      removeService = await ctx.provide(SERVICE_NAME, service);
    } else if (typeof ctx.set === "function") {
      ctx.set(SERVICE_NAME, service);
      removeService = () => ctx.set(SERVICE_NAME, undefined);
    } else {
      throw new ProtocolError("cordis_service_api_required", "Cordis context cannot publish bridge service");
    }
    published = true;
    return { service, dispose };
  } catch (error) {
    await transport.stop("plugin startup failed");
    if (typeof dispose === "function") await dispose();
    throw error;
  }
}
