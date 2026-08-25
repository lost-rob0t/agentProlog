import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const profileUrl = new URL("../../../profiles/agentprolog.patch.yml", import.meta.url);

test("profile replaces only the stock AgentFactory semantic owner", async () => {
  const text = await readFile(profileUrl, "utf8");
  assert.match(text, /- id: agent-loop\n\s+disabled: true/);
  assert.match(text, /id: agentprolog-agent-factory/);
  assert.match(text, /name: !!js process\.env\.AGENTPROLOG_DSH_PLUGIN/);
  assert.match(text, /command: !!js process\.env\.AGENTPROLOG_SIDECAR/);
  assert.match(text, /version: 0\.1\.1-rc\.2/);
  assert.match(text, /revision: b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/);

  const disabledRows = [...text.matchAll(/- id: ([^\n]+)\n\s+disabled: true/g)].map(match => match[1]);
  assert.deepEqual(disabledRows, ["agent-loop"]);
  assert.doesNotMatch(text, /dsh-agent-loop.*name:/);
  assert.doesNotMatch(text, /headless-runner.*name:/);
});
