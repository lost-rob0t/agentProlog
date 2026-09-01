import { ProtocolError } from "./protocol.js";
import { SidecarTransport } from "./sidecar.js";
import { assertHarnessCompatibility } from "./compatibility.js";
import { PrologAgentFactory } from "./agent-factory.js";

export const name = "agentprolog-dsh-agent-factory";
export const inject = ["agents", "sessions"];
export const SERVICE_NAME = "agentPrologRlm";

/**
 * One out-of-tree DSH plugin owns both the persistent Prolog bridge and the
 * AgentFactory. DeepSeek Harness remains presentation/session infrastructure;
 * canonical agent semantics remain in Prolog-RLM.
 */
export async function apply(
  ctx,
  config = {},
  { Transport = SidecarTransport, Factory = PrologAgentFactory } = {},
) {
  if (!ctx || typeof ctx.effect !== "function") {
    throw new ProtocolError("cordis_context_required", "Cordis context with effect() is required");
  }
  if (!ctx.agents || typeof ctx.agents.setFactory !== "function" || !ctx.sessions) {
    throw new ProtocolError("dsh_services_required", "DSH agents and sessions services are required");
  }
  if (!config.command) {
    throw new ProtocolError("bridge_spawn_failed", "Nix-pinned sidecar command is required");
  }
  if (!config.harness) {
    throw new ProtocolError("harness_identity_required", "Pinned DeepSeek Harness version and revision are required");
  }

  // Developer-preview compatibility is fail-closed before spawning or
  // publishing anything into the DSH runtime.
  assertHarnessCompatibility(config.harness);

  const transport = new Transport({
    command: config.command,
    args: config.args ?? ["--stdio"],
    cwd: config.cwd,
    env: config.env ?? {},
    shutdownMs: config.shutdownMs ?? 2000,
  });

  // Cordis effect bodies run during load and return cleanup. The previous
  // bridge wrapper incorrectly supplied an async disposer as the effect body;
  // keep the unmanaged child process under the real Cordis lifecycle contract.
  ctx.effect(() => () => transport.stop("Cordis plugin unload"));

  let removeFactory;
  let removeService;
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

    const factory = new Factory(ctx, service);
    // AgentRegistry.setFactory fails when stock agent-loop is still mounted.
    // That is intentional: the Prolog profile must have exactly one factory.
    removeFactory = ctx.agents.setFactory(factory);
    removeService = ctx.provide(SERVICE_NAME, service);
    return { service, factory };
  } catch (error) {
    try { removeService?.(); } catch {}
    try { removeFactory?.(); } catch {}
    await transport.stop("plugin startup failed");
    throw error;
  }
}
