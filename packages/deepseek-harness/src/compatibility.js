import { ProtocolError } from "./protocol.js";

// Required compatibility target. DeepSeek Harness is developer preview, so the
// plugin fails closed instead of silently widening its supported host surface.
export const SUPPORTED_HARNESS = Object.freeze({
  version: "0.1.1-rc.1",
  revision: "528c682e061696f5a160f363f236ecbf53cbd006",
  node: "^22.19.0 || >=24.0.0",
});

export function assertHarnessCompatibility(host = {}) {
  if (host.version !== SUPPORTED_HARNESS.version) {
    throw new ProtocolError(
      "harness_version_mismatch",
      `unsupported DeepSeek Harness version: ${host.version ?? "unknown"}`,
    );
  }
  if (host.revision !== SUPPORTED_HARNESS.revision) {
    throw new ProtocolError(
      "harness_revision_mismatch",
      `unsupported DeepSeek Harness revision: ${host.revision ?? "unknown"}`,
    );
  }
  return SUPPORTED_HARNESS;
}
