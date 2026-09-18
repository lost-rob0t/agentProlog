import { ProtocolError } from "./errors.js";

// Security compatibility target. DeepSeek Harness <= 0.1.1-rc.2 is affected
// by CVE-2026-82533, so host identity remains an exact, fail-closed gate before
// plugin startup/publication. Review every future release explicitly; dist-tags
// are not a security boundary.
export const SUPPORTED_HARNESS = Object.freeze({
  version: "0.1.2-rc.1",
  revision: "a66e4702047846cdaa10c66c9d3df3951f5ea70d",
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
