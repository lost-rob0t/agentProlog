import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyLiveProof, INPUT, hash } from './live-proof.js';
function fixture() {
 const contents=[INPUT,'ALPHA','BETA','GAMMA','GAMMA'];
 const names=['workspace_read','workspace_create','workspace_modify','workspace_write','workspace_read'];
 return {run:{outcome:{status:'complete'}},traces:[{kind:'provider_route',provider:'zai_coding',selected_model:'glm-5.3-flash'}],tools:names.map((name,i)=>({name,status:'finished',outcome:{status:'ok'},arguments:{path:i?'result.txt':'input.txt',content:contents[i],before:i>1?hash(contents[i-1]):'absent'},output:{path:i?'result.txt':'input.txt',content:contents[i],sha256:hash(contents[i]),bytes:Buffer.byteLength(contents[i])}}))};
}
const files={'input.txt':INPUT,'result.txt':'GAMMA'};
test('live proof requires ordered successful operations and observed provider/model',()=>verifyLiveProof(fixture(),files));
for(const [name,mutate] of [
 ['false finished',s=>delete s.tools[0].outcome],
 ['failed tool',s=>s.tools[2].outcome.status='failed'],
 ['wrong order',s=>s.tools.reverse()],
 ['wrong model',s=>s.traces[0].selected_model='fake'],
 ['missing model',s=>delete s.traces[0].selected_model],
 ['wrong provider',s=>s.traces[0].provider='fake'],
 ['missing readback',s=>s.tools.pop()],
 ['wrong input',s=>s.tools[0].output.content='invented'],
 ['wrong path',s=>s.tools[1].arguments.path='elsewhere'],
 ['wrong intermediate bytes',s=>s.tools[2].output.sha256=hash('ALPHA')]
]) test(`live proof rejects ${name}`,()=>{const s=fixture();mutate(s);assert.throws(()=>verifyLiveProof(s,files));});
test('live proof asserts actual final filesystem bytes',()=>assert.throws(()=>verifyLiveProof(fixture(),{...files,'result.txt':'BETA'})));
