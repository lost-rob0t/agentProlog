import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

const FIXED = "0.1.2-rc.1";
const DSH_DIRECT = [
  "@deepseek-ai/dsh-agent",
  "@deepseek-ai/dsh-commands",
  "@deepseek-ai/dsh-llm",
  "@deepseek-ai/dsh-scope",
  "@deepseek-ai/dsh-session",
] as const;

describe("DeepSeek Harness dependency security pins", () => {
  it("uses exact reviewed direct package versions, never dist-tags or ranges", async () => {
    const pkg = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8")) as {
      dependencies: Record<string, string>;
    };
    expect(pkg.dependencies["@deepseek-ai/cordis"]).toBe("4.0.2");
    for (const name of DSH_DIRECT) expect(pkg.dependencies[name]).toBe(FIXED);
  });

  it("contains no vulnerable 0.1.1-rc.2 package in the resolved lock graph", async () => {
    const lock = await readFile(new URL("../../../pnpm-lock.yaml", import.meta.url), "utf8");
    expect(lock).not.toContain("0.1.1-rc.2");
    for (const name of DSH_DIRECT) expect(lock).toContain(`'${name}@${FIXED}':`);
  });
});
