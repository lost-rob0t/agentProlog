const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";
const RESET = "\x1b[0m";

export function styled(tty: boolean, code: string, text: string): string {
  return tty ? `${code}${text}${RESET}` : text;
}

export function dim(tty: boolean, text: string): string {
  return styled(tty, DIM, text);
}

export function bold(tty: boolean, text: string): string {
  return styled(tty, BOLD, text);
}

const SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"];

/**
 * In-progress turn indicator. On a TTY it animates one in-place line; on a
 * pipe it prints a single start marker so scripted runs stay parseable.
 */
export class Spinner {
  private readonly output: NodeJS.WritableStream;
  private readonly tty: boolean;
  private timer: NodeJS.Timeout | undefined;
  private startedAt = 0;
  private frame = 0;

  constructor(output: NodeJS.WritableStream, tty: boolean, private label: string) {
    this.output = output;
    this.tty = tty;
  }

  start(): void {
    this.startedAt = Date.now();
    if (!this.tty) {
      this.output.write(`${dim(false, `… ${this.label}`)}\n`);
      return;
    }
    this.timer = setInterval(() => this.render(), 120);
    this.render();
  }

  stop(): void {
    if (this.timer !== undefined) {
      clearInterval(this.timer);
      this.timer = undefined;
      this.output.write("\r\x1b[2K");
    }
  }

  private render(): void {
    const seconds = ((Date.now() - this.startedAt) / 1000).toFixed(1);
    const frame = SPINNER_FRAMES[this.frame % SPINNER_FRAMES.length]!;
    this.frame += 1;
    this.output.write(`\r\x1b[2K${dim(true, `${frame} ${this.label} (${seconds}s)`)}`);
  }
}
