import assert from "node:assert/strict";
import test from "node:test";

import {
  AGENTPROLOG_PROFILE_ID,
  PROLOG_RLM_RUNTIME_ID,
  ZARA_RUNTIME_PROTOCOL,
  advertiseAgentPrologProfile,
  handshakeAgentPrologProfile,
} from "../src/profile.js";

const runtime = (extra = {}) => ({
  id: PROLOG_RLM_RUNTIME_ID,
  protocol: ZARA_RUNTIME_PROTOCOL,
  runtime_version: "1.0.0",
  installed: true,
  available: true,
  health: "ready",
  provider_control: "runtime",
  model_control: "runtime",
  profiles: [AGENTPROLOG_PROFILE_ID],
  ...extra,
});

const handshake = (extra = {}) => ({
  protocol: ZARA_RUNTIME_PROTOCOL,
  profile_id: AGENTPROLOG_PROFILE_ID,
  runtime_id: PROLOG_RLM_RUNTIME_ID,
  requires_runtime: PROLOG_RLM_RUNTIME_ID,
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

test("does not manufacture AgentProlog unless Prolog-RLM advertises that profile", () => {
  assert.equal(advertiseAgentPrologProfile(runtime({ profiles: [] })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ profiles: ["other-profile"] })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ profiles: undefined })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ profiles: AGENTPROLOG_PROFILE_ID })), null);
});

test("fails closed for malformed or duplicate advertised profile identities", () => {
  assert.equal(
    advertiseAgentPrologProfile(runtime({ profiles: [AGENTPROLOG_PROFILE_ID, null] })),
    null,
  );
  assert.equal(
    advertiseAgentPrologProfile(runtime({ profiles: [AGENTPROLOG_PROFILE_ID, ""] })),
    null,
  );
  assert.equal(
    advertiseAgentPrologProfile(runtime({ profiles: [AGENTPROLOG_PROFILE_ID, "bad\nprofile"] })),
    null,
  );
  assert.equal(
    advertiseAgentPrologProfile(runtime({ profiles: [AGENTPROLOG_PROFILE_ID, AGENTPROLOG_PROFILE_ID] })),
    null,
  );
  assert.notEqual(
    advertiseAgentPrologProfile(runtime({ profiles: ["other-profile", AGENTPROLOG_PROFILE_ID] })),
    null,
  );
});

test("requires a selectable Prolog-RLM health state", () => {
  assert.notEqual(advertiseAgentPrologProfile(runtime({ health: "busy" })), null);
  assert.notEqual(advertiseAgentPrologProfile(runtime({ health: "degraded" })), null);

  assert.equal(advertiseAgentPrologProfile(runtime({ health: "starting" })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ health: "failed" })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ health: "stopped" })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ health: undefined })), null);
  assert.equal(advertiseAgentPrologProfile(runtime({ health: "ready\nadmin" })), null);
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

test("handshake binds AgentProlog profile to canonical Prolog-RLM identity", () => {
  const profile = handshakeAgentPrologProfile(runtime(), handshake());

  assert.equal(profile.id, AGENTPROLOG_PROFILE_ID);
  assert.equal(profile.protocol, ZARA_RUNTIME_PROTOCOL);
  assert.equal(profile.runtime_id, PROLOG_RLM_RUNTIME_ID);
  assert.equal(profile.requires_runtime, PROLOG_RLM_RUNTIME_ID);
});

test("handshake fails closed on protocol, profile, or runtime substitution", () => {
  assert.equal(
    handshakeAgentPrologProfile(runtime(), handshake({ protocol: "ZARA-RUNTIME/2" })),
    null,
  );
  assert.equal(
    handshakeAgentPrologProfile(runtime(), handshake({ profile_id: "other-profile" })),
    null,
  );
  assert.equal(
    handshakeAgentPrologProfile(runtime(), handshake({ runtime_id: "agentprolog" })),
    null,
  );
  assert.equal(
    handshakeAgentPrologProfile(runtime(), handshake({ requires_runtime: "agentprolog" })),
    null,
  );
});

test("handshake cannot resurrect an unavailable, non-selectable, or unadvertised runtime", () => {
  assert.equal(
    handshakeAgentPrologProfile(runtime({ available: false }), handshake()),
    null,
  );
  assert.equal(
    handshakeAgentPrologProfile(runtime({ health: "failed" }), handshake()),
    null,
  );
  assert.equal(
    handshakeAgentPrologProfile(runtime({ profiles: [] }), handshake()),
    null,
  );
});

test("handshake never projects caller credentials, grants, or principal authority", () => {
  const profile = handshakeAgentPrologProfile(runtime(), handshake({
    api_key: "CALLER-SECRET",
    principal_id: "root",
    capabilities: ["shell", "filesystem", "principal-admin"],
    provider: { api_key: "CALLER-SECRET" },
  }));
  const encoded = JSON.stringify(profile);

  assert.equal(encoded.includes("CALLER-SECRET"), false);
  assert.equal(encoded.includes("root"), false);
  assert.equal(encoded.includes("shell"), false);
  assert.equal(encoded.includes("filesystem"), false);
  assert.deepEqual(profile.capabilities, ["agent", "coding", "spec-plan-verify"]);
  assert.equal(Object.hasOwn(profile, "principal_id"), false);
  assert.equal(Object.hasOwn(profile, "provider"), false);
  assert.equal(Object.hasOwn(profile, "api_key"), false);
});
