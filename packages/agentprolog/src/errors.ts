export class ProtocolError extends Error {
  readonly code: string;
  /** Structured code reported by the Prolog runtime, when the failure crossed the bridge. */
  runtimeCode?: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "ProtocolError";
    this.code = code;
  }
}

/** Rejected agentProlog reasoning mode (unknown or malformed). */
export class ModeError extends ProtocolError {
  constructor(message: string) {
    super("invalid_mode", message);
    this.name = "ModeError";
  }
}
