export const PROTOCOL = "prolog_agent_ui_v1";

const KNOWN_EVENTS = new Set([
  "run_started",
  "message_started",
  "text_delta",
  "message_completed",
  "tool_started",
  "tool_output",
  "tool_finished",
  "approval_required",
  "approval_resolved",
  "question_required",
  "question_answered",
  "subagent_started",
  "subagent_finished",
  "verification",
  "usage",
  "trace",
  "effect_indeterminate",
  "run_finished",
]);

export class ProtocolError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "ProtocolError";
    this.code = code;
    this.details = details;
  }
}

export function createProjection() {
  return {
    protocol: PROTOCOL,
    sessionId: null,
    snapshotId: null,
    cursor: 0,
    status: "disconnected",
    run: null,
    messages: [],
    tools: [],
    approvals: [],
    questions: [],
    subagents: [],
    verification: [],
    usage: {},
    traces: [],
    indeterminateEffects: [],
    extensions: [],
    lastEventId: null,
  };
}

export function applyFrame(previous, frame) {
  assertObject(previous, "projection");
  assertFrame(frame);

  if (frame.kind === "snapshot") {
    return applySnapshot(frame);
  }

  if (frame.kind === "event") {
    return applyEvent(previous, frame);
  }

  return previous;
}

export function makeNegotiation({
  requestId,
  requiredCapabilities = [],
  optionalCapabilities = [],
}) {
  assertNonEmptyString(requestId, "requestId");

  return {
    protocol: PROTOCOL,
    kind: "negotiate",
    request_id: requestId,
    payload: {
      protocol_versions: [PROTOCOL],
      required_capabilities: [...requiredCapabilities],
      optional_capabilities: [...optionalCapabilities],
    },
  };
}

export function makeCommand({
  sessionId,
  requestId,
  command,
  payload = {},
}) {
  assertNonEmptyString(sessionId, "sessionId");
  assertNonEmptyString(requestId, "requestId");
  assertNonEmptyString(command, "command");
  assertObject(payload, "payload");

  return {
    protocol: PROTOCOL,
    kind: "command",
    session_id: sessionId,
    request_id: requestId,
    command,
    payload,
  };
}

function applySnapshot(frame) {
  assertNonEmptyString(frame.session_id, "snapshot.session_id");
  assertNonEmptyString(frame.snapshot_id, "snapshot.snapshot_id");
  assertCursor(frame.at_seq, "snapshot.at_seq");
  assertObject(frame.state, "snapshot.state");

  const state = frame.state;

  return {
    protocol: PROTOCOL,
    sessionId: frame.session_id,
    snapshotId: frame.snapshot_id,
    cursor: frame.at_seq,
    status: state.status ?? "unknown",
    run: clone(state.run ?? null),
    messages: cloneArray(state.messages),
    tools: cloneArray(state.tools),
    approvals: cloneArray(state.approvals),
    questions: cloneArray(state.questions),
    subagents: cloneArray(state.subagents),
    verification: cloneArray(state.verification),
    usage: cloneObject(state.usage),
    traces: cloneArray(state.traces),
    indeterminateEffects: cloneArray(state.indeterminate_effects),
    extensions: cloneArray(state.extensions),
    lastEventId: null,
  };
}

function applyEvent(previous, frame) {
  assertNonEmptyString(frame.session_id, "event.session_id");
  assertNonEmptyString(frame.event_id, "event.event_id");
  assertNonEmptyString(frame.event_type, "event.event_type");
  assertEventSeq(frame.seq);

  if (previous.sessionId === null) {
    throw new ProtocolError(
      "snapshot_required",
      "Cannot apply an event before a canonical snapshot",
      { seq: frame.seq },
    );
  }

  if (previous.sessionId !== frame.session_id) {
    throw new ProtocolError(
      "session_mismatch",
      "Event session does not match the active canonical session",
      {
        expected: previous.sessionId,
        actual: frame.session_id,
      },
    );
  }

  if (frame.seq <= previous.cursor) {
    return previous;
  }

  const expected = previous.cursor + 1;
  if (frame.seq !== expected) {
    throw new ProtocolError(
      "sequence_gap",
      "Event stream has a forward sequence gap",
      { expected, actual: frame.seq },
    );
  }

  const next = structuredClone(previous);
  next.cursor = frame.seq;
  next.lastEventId = frame.event_id;

  if (!KNOWN_EVENTS.has(frame.event_type)) {
    applyExtension(next, frame);
    return next;
  }

  const payload = cloneObject(frame.payload);

  switch (frame.event_type) {
    case "run_started":
      next.status = "running";
      next.run = { ...payload, status: "running" };
      return next;

    case "message_started":
      upsert(next.messages, "message_id", payload.message_id, {
        ...payload,
        text: payload.text ?? "",
        status: "streaming",
      });
      return next;

    case "text_delta": {
      const message = requireItem(
        next.messages,
        "message_id",
        payload.message_id,
        "message_not_found",
      );
      message.text = `${message.text ?? ""}${payload.delta ?? ""}`;
      return next;
    }

    case "message_completed": {
      const message = requireItem(
        next.messages,
        "message_id",
        payload.message_id,
        "message_not_found",
      );
      message.status = "completed";
      return next;
    }

    case "tool_started":
      upsert(next.tools, "tool_id", payload.tool_id, {
        ...payload,
        outputs: [],
        status: "running",
      });
      return next;

    case "tool_output": {
      const tool = requireItem(
        next.tools,
        "tool_id",
        payload.tool_id,
        "tool_not_found",
      );
      tool.outputs ??= [];
      tool.outputs.push(clone(payload.output));
      return next;
    }

    case "tool_finished": {
      const tool = requireItem(
        next.tools,
        "tool_id",
        payload.tool_id,
        "tool_not_found",
      );
      tool.status = "finished";
      tool.outcome = clone(payload.outcome);
      return next;
    }

    case "approval_required":
      upsert(next.approvals, "approval_id", payload.approval_id, {
        ...payload,
        status: "pending",
      });
      return next;

    case "approval_resolved":
      resolveItem(
        next.approvals,
        "approval_id",
        payload.approval_id,
        "approval_not_found",
        { ...payload, status: "resolved" },
      );
      return next;

    case "question_required":
      upsert(next.questions, "question_id", payload.question_id, {
        ...payload,
        status: "pending",
      });
      return next;

    case "question_answered":
      resolveItem(
        next.questions,
        "question_id",
        payload.question_id,
        "question_not_found",
        { ...payload, status: "answered" },
      );
      return next;

    case "subagent_started":
      upsert(next.subagents, "subagent_id", payload.subagent_id, {
        ...payload,
        status: "running",
      });
      return next;

    case "subagent_finished":
      resolveItem(
        next.subagents,
        "subagent_id",
        payload.subagent_id,
        "subagent_not_found",
        { ...payload, status: "finished" },
      );
      return next;

    case "verification":
      next.verification.push(payload);
      return next;

    case "usage":
      next.usage = payload;
      return next;

    case "trace":
      next.traces.push(payload);
      return next;

    case "effect_indeterminate":
      next.indeterminateEffects.push(payload);
      return next;

    case "run_finished":
      next.status = "finished";
      next.run = {
        ...(next.run ?? {}),
        status: "finished",
        outcome: clone(payload.outcome),
      };
      return next;

    default:
      throw new ProtocolError(
        "unhandled_known_event",
        "Known event is missing a projection handler",
        { eventType: frame.event_type },
      );
  }
}

function applyExtension(next, frame) {
  assertObject(frame.extension, "event.extension");

  if (frame.extension.required === true) {
    throw new ProtocolError(
      "unsupported_required_extension",
      "Required extension event is not supported",
      {
        eventType: frame.event_type,
        namespace: frame.extension.namespace ?? null,
      },
    );
  }

  next.extensions.push({
    event_id: frame.event_id,
    event_type: frame.event_type,
    extension: clone(frame.extension),
    payload: cloneObject(frame.payload),
  });
}

function upsert(items, key, id, value) {
  assertNonEmptyString(id, key);

  const index = items.findIndex((item) => item?.[key] === id);
  if (index === -1) {
    items.push(clone(value));
    return;
  }

  items[index] = {
    ...items[index],
    ...clone(value),
  };
}

function resolveItem(items, key, id, errorCode, value) {
  const item = requireItem(items, key, id, errorCode);
  Object.assign(item, clone(value));
}

function requireItem(items, key, id, errorCode) {
  assertNonEmptyString(id, key);

  const item = items.find((candidate) => candidate?.[key] === id);
  if (item) {
    return item;
  }

  throw new ProtocolError(
    errorCode,
    `Referenced ${key} does not exist in canonical projection`,
    { [key]: id },
  );
}

function assertFrame(frame) {
  assertObject(frame, "frame");

  if (frame.protocol !== PROTOCOL) {
    throw new ProtocolError(
      "protocol_mismatch",
      "Unsupported frontend protocol",
      {
        expected: PROTOCOL,
        actual: frame.protocol ?? null,
      },
    );
  }

  assertNonEmptyString(frame.kind, "frame.kind");
}

function assertCursor(value, name) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new TypeError(`${name} must be a non-negative safe integer`);
  }
}

function assertEventSeq(value) {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new TypeError("event.seq must be a positive safe integer");
  }
}

function assertObject(value, name) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${name} must be an object`);
  }
}

function assertNonEmptyString(value, name) {
  if (typeof value !== "string" || value.length === 0) {
    throw new TypeError(`${name} must be a non-empty string`);
  }
}

function clone(value) {
  if (value === undefined) {
    return undefined;
  }

  return structuredClone(value);
}

function cloneArray(value) {
  if (value === undefined) {
    return [];
  }

  if (!Array.isArray(value)) {
    throw new TypeError("snapshot collection must be an array");
  }

  return clone(value);
}

function cloneObject(value) {
  if (value === undefined) {
    return {};
  }

  assertObject(value, "object");
  return clone(value);
}
