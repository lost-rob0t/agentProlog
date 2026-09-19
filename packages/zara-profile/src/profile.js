const ZARA_RUNTIME_PROTOCOL = "ZARA-RUNTIME/1";
const PROLOG_RLM_RUNTIME_ID = "prolog-rlm";
const AGENTPROLOG_PROFILE_ID = "agentprolog";

const PROFILE_CAPABILITIES = Object.freeze([
  "agent",
  "coding",
  "spec-plan-verify",
]);

const SELECTABLE_RUNTIME_HEALTH = Object.freeze([
  "ready",
  "busy",
  "degraded",
]);

const PROFILE_DISPLAY_NAME = "AgentProlog";
const MAX_VERSION_LENGTH = 64;

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function boundedText(value) {
  if (typeof value !== "string") return null;
  if (value.length === 0 || value.length > MAX_VERSION_LENGTH) return null;
  if (value !== value.trim()) return null;
  for (const character of value) {
    const code = character.codePointAt(0);
    if (code < 0x20 || code === 0x7f) return null;
  }
  return value;
}

function advertisesAgentProlog(runtime) {
  if (!Array.isArray(runtime.profiles)) return false;
  return runtime.profiles.includes(AGENTPROLOG_PROFILE_ID);
}

function compatiblePrologRlm(runtime) {
  if (!isRecord(runtime)) return false;
  if (runtime.id !== PROLOG_RLM_RUNTIME_ID) return false;
  if (runtime.protocol !== ZARA_RUNTIME_PROTOCOL) return false;
  if (runtime.installed !== true || runtime.available !== true) return false;
  if (!SELECTABLE_RUNTIME_HEALTH.includes(runtime.health)) return false;
  if (runtime.provider_control !== "runtime") return false;
  if (runtime.model_control !== "runtime") return false;
  if (boundedText(runtime.runtime_version) === null) return false;
  if (!advertisesAgentProlog(runtime)) return false;
  return true;
}

export function advertiseAgentPrologProfile(runtime) {
  if (!compatiblePrologRlm(runtime)) return null;

  return Object.freeze({
    id: AGENTPROLOG_PROFILE_ID,
    display_name: PROFILE_DISPLAY_NAME,
    protocol: ZARA_RUNTIME_PROTOCOL,
    requires_runtime: PROLOG_RLM_RUNTIME_ID,
    runtime_id: PROLOG_RLM_RUNTIME_ID,
    runtime_version: runtime.runtime_version,
    available: true,
    capabilities: PROFILE_CAPABILITIES,
  });
}

export function handshakeAgentPrologProfile(runtime, request) {
  if (!isRecord(request)) return null;
  if (request.protocol !== ZARA_RUNTIME_PROTOCOL) return null;
  if (request.profile_id !== AGENTPROLOG_PROFILE_ID) return null;
  if (request.runtime_id !== PROLOG_RLM_RUNTIME_ID) return null;
  if (request.requires_runtime !== PROLOG_RLM_RUNTIME_ID) return null;

  return advertiseAgentPrologProfile(runtime);
}

export {
  AGENTPROLOG_PROFILE_ID,
  PROLOG_RLM_RUNTIME_ID,
  ZARA_RUNTIME_PROTOCOL,
};
