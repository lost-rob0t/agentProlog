import { ProtocolError } from "./errors.js";

// Required compatibility target from prolog-rlm#184 / agentProlog#7. DeepSeek
// Harness is a developer preview, so the plugin fails closed instead of
// silently widening its supported host surface. Bump both sides together with
// the prolog-rlm pin in flake.nix.
export const SUPPORTED_HARNESS = Object.freeze({
  version: "0.1.1-rc.2",
  revision: "b150a551b8d465e31e418e1b2eaf5e79bbb7d28e",
  node: "^22.19.0 || >=24.0.0",
});

export interface HarnessIdentity {
  readonly version: string;
  readonly revision: string;
}

export function assertHarnessCompatibility(host: HarnessIdentity | undefined): HarnessIdentity {
  if (!host) {
    throw new ProtocolError("harness_identity_required", "Pinned DeepSeek Harness version and revision are required");
  }
  if (host.version !== SUPPORTED_HARNESS.version) {
    throw new ProtocolError("harness_version_mismatch", `unsupported DeepSeek Harness version: ${host.version ?? "unknown"}`);
  }
  if (host.revision !== SUPPORTED_HARNESS.revision) {
    throw new ProtocolError("harness_revision_mismatch", `unsupported DeepSeek Harness revision: ${host.revision ?? "unknown"}`);
  }
  return SUPPORTED_HARNESS;
}
