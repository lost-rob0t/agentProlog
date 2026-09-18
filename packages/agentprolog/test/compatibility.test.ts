import { describe, expect, it } from "vitest";

import { assertHarnessCompatibility, SUPPORTED_HARNESS } from "../src/compatibility.js";

const FIXED = Object.freeze({
  version: "0.1.2-rc.1",
  revision: "a66e4702047846cdaa10c66c9d3df3951f5ea70d",
});

const VULNERABLE = Object.freeze({
  version: "0.1.1-rc.2",
  revision: "b150a551b8d465e31e418e1b2eaf5e79bbb7d28e",
});

describe("DeepSeek Harness security compatibility", () => {
  it("pins the reviewed CVE-2026-82533 fixed host identity", () => {
    expect(SUPPORTED_HARNESS).toMatchObject(FIXED);
    expect(assertHarnessCompatibility(FIXED)).toBe(SUPPORTED_HARNESS);
  });

  it("rejects the vulnerable 0.1.1-rc.2 host", () => {
    expect(() => assertHarnessCompatibility(VULNERABLE)).toThrow(
      expect.objectContaining({ code: "harness_version_mismatch" }),
    );
  });

  it("rejects an unreviewed revision on the fixed version", () => {
    expect(() => assertHarnessCompatibility({ ...FIXED, revision: "unreviewed" })).toThrow(
      expect.objectContaining({ code: "harness_revision_mismatch" }),
    );
  });
});
