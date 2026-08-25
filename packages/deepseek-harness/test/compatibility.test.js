import test from "node:test";
import assert from "node:assert/strict";
import { SUPPORTED_HARNESS, assertHarnessCompatibility } from "../src/compatibility.js";

test("pins the approved DeepSeek Harness rc2 release and tag commit", () => {
  assert.equal(SUPPORTED_HARNESS.version, "0.1.1-rc.2");
  assert.equal(SUPPORTED_HARNESS.revision, "b150a551b8d465e31e418e1b2eaf5e79bbb7d28e");
  assert.equal(SUPPORTED_HARNESS.node, "^22.19.0 || >=24.0.0");
});

test("accepts only the pinned DeepSeek Harness release and revision", () => {
  assert.equal(assertHarnessCompatibility(SUPPORTED_HARNESS), SUPPORTED_HARNESS);
});

test("fails closed when the Harness release changes", () => {
  assert.throws(
    () => assertHarnessCompatibility({ ...SUPPORTED_HARNESS, version: "0.1.2" }),
    error => error?.code === "harness_version_mismatch",
  );
});

test("fails closed when the Harness revision changes under the same release", () => {
  assert.throws(
    () => assertHarnessCompatibility({ ...SUPPORTED_HARNESS, revision: "deadbeef" }),
    error => error?.code === "harness_revision_mismatch",
  );
});
