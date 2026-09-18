import assert from "node:assert/strict";
import test from "node:test";

import {
  AGENTPROLOG_PROFILE_ID,
  PROLOG_RLM_RUNTIME_ID,
  ZARA_RUNTIME_PROTOCOL,
  advertiseAgentPrologProfile,
} from "../src/profile.js";

const runtime = (extra = {}) => ({
  id: PROLOG_RLM_RUNTIME_ID,
  protocol: ZARA_RUNTIME_PROTOCOL,
  runtime_version: "1.0.0",
  installed: true,
  available: true,
  provider_control: "runtime",
  model_control: "runtime",
  ...extra,
});

test("advertises AgentProlog as a profile over Prolog-RLM", () => {
  const profile = advertiseAgentPrologProfile(runtime());

  assert.equal(profile.id, AGENTPROLOG_PROFILE_ID);
  assert.equal(profile.requires_runtime, PROLOG_RLM_RUNTIME_ID);
  assert.equal(profile.runtime_id, PROLOG_RLM_RUNTIME_ID);
  assert.equal(profile.protocol, ZARA_RUNTIME_PROTOCOL);
  assert.equal(profile.available, true);
  assert.deepEqual(profile.capabilities, ["agent", "coding", "spec-plan-verify"]);
});

test("does not manufacture a profile when Prolog-RLM is unavailable", () => {
  assert.equal(advertiseAgentPrologProfile(runtime({ available: false })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ installed: false })), null);
});

test("fails closed for another runtime or protocol major", () => {
  assert.equal(advertiseAgentPrologProfile(runtime({ id: "agentprolog" })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ protocol: "ZARA-RUNTIME/2" })), null);
});

test("requires canonical runtime ownership before advertising the profile", () => {
  assert.equal(advertiseAgentPrologProfile(runtime({ provider_control: "zara" })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ provider_control: "mixed" })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ model_control: "zara" })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ model_control: "mixed" })), null);
});

test("requires canonical bounded runtime version identity", () => {
  assert.equal(advertiseAgentPrologProfile(runtime({ runtime_version: "" })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ runtime_version: "bad\nversion" })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ runtime_version: "bad\tversion" })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ runtime_version: " 1.0.0" })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ runtime_version: "1.0.0 " })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ runtime_version: "x".repeat(65) })), null);
});

test("profile projection does not leak runtime credentials or authority", () => {
  const profile = advertiseAgentPrologProfile(runtime({
    api_key: "TOP-SECRET",
    credential: "NOPE",
    principal_id: "admin",
    provider: { api_key: "TOP-SECRET" },
  }));
  const encoded = JSON.stringify(profile);

  assert.equal(encoded.includes("TOP-SECRET"), false);
  assert.equal(encoded.includes("NOPE"), false);
  assert.equal(Object.hasOwn(profile, "principal_id"), false);
  assert.equal(Object.hasOwn(profile, "provider"), false);
  assert.equal(Object.hasOwn(profile, "api_key"), false);
});
