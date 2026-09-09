import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import {
  SUPPORTED_HARNESS,
  assertHarnessCompatibility,
} from "../src/compatibility.js";

const VULNERABLE_HARNESS = Object.freeze({
  version: "0.1.1-rc.2",
  revision: "b150a551b8d465e31e418e1b2eaf5e79bbb7d28e",
});

describe("DeepSeek Harness security boundary", () => {
  it("accepts the reviewed fixed Harness identity", () => {
    expect(assertHarnessCompatibility(SUPPORTED_HARNESS)).toEqual(SUPPORTED_HARNESS);
  });

  it("rejects the AgentProlog pre-fix Harness identity as CVE-2026-82533", () => {
    expect(() => assertHarnessCompatibility(VULNERABLE_HARNESS)).toThrow(
      expect.objectContaining({
        code: "harness_security_blocked",
        message: expect.stringContaining("CVE-2026-82533"),
      }),
    );
  });

  it("does not retain vulnerable Harness package pins in manifests or lock data", () => {
    const manifest = readFileSync(new URL("../package.json", import.meta.url), "utf8");
    const lockfile = readFileSync(new URL("../../../pnpm-lock.yaml", import.meta.url), "utf8");

    expect(manifest).not.toContain("0.1.1-rc.2");
    expect(lockfile).not.toContain("0.1.1-rc.2");
    expect(manifest).toContain('"0.1.2-rc.1"');
  });
});
