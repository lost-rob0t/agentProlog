import { ProtocolError } from "./errors.js";

// DeepSeek Harness is a developer preview. AgentProlog therefore accepts one
// reviewed host identity only and fails closed before any sidecar process or
// Cordis service is published.
export const SUPPORTED_HARNESS = Object.freeze({
  version: "0.1.2-rc.1",
  revision: "a66e4702047846cdaa10c66c9d3df3951f5ea70d",
  node: "^22.19.0 || >=24.0.0",
});

// Keep known-bad identities machine-readable so a future compatibility bump
// cannot accidentally turn an old security advisory into a harmless-looking
// version mismatch. CVE-2026-82533 affects Harness 0.1.1-rc.2 and earlier; the
// immediately previous AgentProlog pin is recorded explicitly here.
export const BLOCKED_HARNESS_IDENTITIES = Object.freeze([
  Object.freeze({
    version: "0.1.1-rc.2",
    revision: "b150a551b8d465e31e418e1b2eaf5e79bbb7d28e",
    advisory: "CVE-2026-82533",
  }),
]);

export interface HarnessIdentity {
  readonly version: string;
  readonly revision: string;
}

export function assertHarnessCompatibility(host: HarnessIdentity | undefined): HarnessIdentity {
  if (!host) {
    throw new ProtocolError("harness_identity_required", "Pinned DeepSeek Harness version and revision are required");
  }

  const blocked = BLOCKED_HARNESS_IDENTITIES.find(identity =>
    identity.version === host.version && identity.revision === host.revision,
  );
  if (blocked) {
    throw new ProtocolError(
      "harness_security_blocked",
      `${blocked.advisory}: blocked DeepSeek Harness ${host.version} (${host.revision})`,
    );
  }

  if (host.version !== SUPPORTED_HARNESS.version) {
    throw new ProtocolError("harness_version_mismatch", `unsupported DeepSeek Harness version: ${host.version ?? "unknown"}`);
  }
  if (host.revision !== SUPPORTED_HARNESS.revision) {
    throw new ProtocolError("harness_revision_mismatch", `unsupported DeepSeek Harness revision: ${host.revision ?? "unknown"}`);
  }
  return SUPPORTED_HARNESS;
}
