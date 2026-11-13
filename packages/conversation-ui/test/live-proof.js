import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
export const INPUT = 'Synthetic task marker: ALPHA\n';
export const hash = value => createHash('sha256').update(value).digest('hex');
export function verifyLiveProof(state, files) {
  assert.equal(state.run?.outcome?.status, 'complete');
  const route = state.traces.find(t => t.kind === 'provider_route');
  assert.equal(route?.provider, 'zai_coding', 'Missing or wrong observed provider');
  assert.equal(route?.selected_model, 'glm-5.3-flash', 'Missing or wrong observed model');
  const tools = state.tools;
  assert.deepEqual(tools.map(t => t.name), ['workspace_read','workspace_create','workspace_modify','workspace_write','workspace_read']);
  const contents = [INPUT,'ALPHA','BETA','GAMMA','GAMMA'];
  for (const [i,t] of tools.entries()) {
    const path = i === 0 ? 'input.txt' : 'result.txt';
    assert.equal(t.status,'finished');
    assert.equal(t.outcome?.status,'ok','Finished tool must have successful outcome');
    assert.equal(t.arguments?.path,path);
    assert.equal(t.output?.path,path);
    assert.equal(t.output?.sha256,hash(contents[i]));
    assert.equal(t.output?.bytes,Buffer.byteLength(contents[i]));
    if (i === 0 || i === 4) assert.equal(t.output.content,contents[i]);
    else assert.equal(t.arguments.content,contents[i]);
    if (i === 2 || i === 3) assert.equal(t.arguments.before,hash(contents[i-1]));
  }
  assert.deepEqual(Object.keys(files).sort(),['input.txt','result.txt']);
  assert.equal(files['input.txt'],INPUT);
  assert.equal(files['result.txt'],'GAMMA');
  return route;
}
