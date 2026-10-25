import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

import {
  PROTOCOL,
  ProtocolError,
  applyFrame,
  createProjection,
  makeCommand,
  makeNegotiation,
} from "../src/index.js";

function snapshot(atSeq = 0) {
  return {
    protocol: PROTOCOL,
    kind: "snapshot",
    session_id: "session_1",
    snapshot_id: `snapshot_${atSeq}`,
    at_seq: atSeq,
    state: {
      status: "idle",
      run: null,
      messages: [],
      tools: [],
      approvals: [],
      questions: [],
      subagents: [],
      verification: [],
      usage: {},
      traces: [],
      indeterminate_effects: [],
      extensions: [],
    },
  };
}

function event(seq, eventType, payload = {}, extra = {}) {
  return {
    protocol: PROTOCOL,
    kind: "event",
    session_id: "session_1",
    seq,
    event_id: `evt_${seq}`,
    event_type: eventType,
    payload,
    ...extra,
  };
}

test("snapshot replaces the local projection at the canonical cursor", () => {
  const state = applyFrame(createProjection(), snapshot(4));

  assert.equal(state.sessionId, "session_1");
  assert.equal(state.cursor, 4);
  assert.equal(state.status, "idle");
});

test("duplicate replay events are ignored", () => {
  let state = applyFrame(createProjection(), snapshot());
  state = applyFrame(
    state,
    event(1, "run_started", { run_id: "run_1", task: "test" }),
  );

  const duplicate = applyFrame(
    state,
    event(1, "run_started", { run_id: "run_1", task: "changed" }),
  );

  assert.equal(duplicate, state);
  assert.equal(duplicate.run.task, "test");
});

test("forward sequence gaps fail closed", () => {
  const state = applyFrame(createProjection(), snapshot());

  assert.throws(
    () => applyFrame(state, event(2, "run_started", { run_id: "run_1" })),
    (error) =>
      error instanceof ProtocolError &&
      error.code === "sequence_gap" &&
      error.details.expected === 1,
  );
});

test("optional extensions advance the cursor and remain visible", () => {
  let state = applyFrame(createProjection(), snapshot());

  state = applyFrame(
    state,
    event(
      1,
      "future_hint",
      { canonical: { hint: "compact" } },
      {
        extension: {
          namespace: "example.ui",
          required: false,
        },
      },
    ),
  );

  assert.equal(state.cursor, 1);
  assert.equal(state.extensions.length, 1);
  assert.equal(state.extensions[0].event_type, "future_hint");
});

test("required unknown extensions fail closed", () => {
  const state = applyFrame(createProjection(), snapshot());

  assert.throws(
    () =>
      applyFrame(
        state,
        event(
          1,
          "future_authority",
          {},
          {
            extension: {
              namespace: "example.authority",
              required: true,
            },
          },
        ),
      ),
    (error) =>
      error instanceof ProtocolError &&
      error.code === "unsupported_required_extension",
  );
});

test("command builders preserve explicit correlation identifiers", () => {
  assert.deepEqual(
    makeNegotiation({
      requestId: "req_1",
      requiredCapabilities: ["approvals"],
      optionalCapabilities: ["mouse"],
    }),
    {
      protocol: PROTOCOL,
      kind: "negotiate",
      request_id: "req_1",
      payload: {
        protocol_versions: [PROTOCOL],
        required_capabilities: ["approvals"],
        optional_capabilities: ["mouse"],
      },
    },
  );

  assert.deepEqual(
    makeCommand({
      sessionId: "session_1",
      requestId: "req_2",
      command: "approval.decide",
      payload: {
        approval_id: "approval_1",
        decision: "allow_once",
      },
    }),
    {
      protocol: PROTOCOL,
      kind: "command",
      session_id: "session_1",
      request_id: "req_2",
      command: "approval.decide",
      payload: {
        approval_id: "approval_1",
        decision: "allow_once",
      },
    },
  );
});

test("pinned upstream golden fixture reduces without protocol drift", (t) => {
  const root = process.env.PROLOG_RLM_SOURCE;
  if (!root) {
    t.skip("PROLOG_RLM_SOURCE is not set");
    return;
  }

  const fixturePath = path.join(
    root,
    "test",
    "fixtures",
    "prolog_agent_ui_v1_session.ndjson",
  );
  const frames = fs
    .readFileSync(fixturePath, "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));

  let state = createProjection();
  for (const frame of frames) {
    state = applyFrame(state, frame);
  }

  assert.equal(state.sessionId, "fixture_session_1");
  assert.equal(state.cursor, 24);
  assert.equal(state.status, "finished");
  assert.equal(state.messages[0].text, "I will inspect the authority path.");
  assert.equal(state.tools.length, 3);
  assert.equal(state.approvals[0].decision, "allow_once");
  assert.equal(state.questions[0].answer, "authority");
  assert.equal(state.subagents[0].outcome, "ok");
  assert.equal(state.verification[0].outcome.status, "pass");
  assert.equal(state.usage.input_tokens, 1200);
  assert.equal(state.indeterminateEffects.length, 1);
  assert.equal(state.extensions.length, 1);
  assert.equal(state.run.outcome.status, "ok");
});
