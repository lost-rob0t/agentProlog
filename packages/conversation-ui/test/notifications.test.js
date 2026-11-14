import test from 'node:test';
import assert from 'node:assert/strict';
import {Notifications,notificationOptions} from '../src/notifications.js';
const view={state:{run:{run_id:'r'}}};
function fixture(mode='text',events,tty=false) {
 const output=[];const n=new Notifications(notificationOptions(mode,events),{write:x=>output.push(x),isTTY:tty});
 return {n,output};
}
const event=(event_type,payload={})=>({kind:'event',session_id:'s',event_id:'e',event_type,payload});
test('notifications default off and snapshots never alert',()=>{
 const {n,output}=fixture('off');n.consume(view,event('approval_required',{approval_id:'a'}));assert.deepEqual(output,[]);
 const t=fixture();t.n.consume(view,{kind:'snapshot'});assert.deepEqual(t.output,[]);
});
test('filters and deduplicates without leaking event contents',()=>{
 const {n,output}=fixture('text','approval');
 const f=event('approval_required',{approval_id:'a',prompt:'PRIVATE',diff:'SECRET'});
 n.consume(view,f);n.consume(view,f);n.consume(view,event('question_required',{question_id:'q'}));
 assert.deepEqual(output,['\n[AgentProlog] Approval needed.\n']);
});
test('completion distinguishes failed cancelled and successful',()=>{
 const {n,output}=fixture();
 for(const status of ['complete','failed','cancelled']) n.consume(view,event('run_finished',{outcome:{status}}));
 assert.match(output[0],/External results may still need verification/);
 assert.match(output[1],/did not complete/);assert.match(output[2],/cancelled/);
});
test('bell is opt-in and never emitted into redirected output',()=>{
 const f=event('question_required',{question_id:'q'});const a=fixture('bell',undefined,false);
 a.n.consume(view,f);assert.deepEqual(a.output,[]);
 const b=fixture('bell',undefined,true);b.n.consume(view,f);assert.deepEqual(b.output,['\x07']);
});
test('rejects invalid config before connecting',()=>{
 assert.throws(()=>notificationOptions('shell'));assert.throws(()=>notificationOptions('text','approval,secret'));
 assert.throws(()=>notificationOptions('text',''));
});
test('new run identities alert independently and retention is bounded',()=>{
 const {n,output}=fixture();
 for(let i=0;i<300;i++) n.consume({state:{run:{run_id:`r${i}`}}},event('run_finished',{outcome:{status:'complete'}}));
 assert.equal(output.length,300);assert.equal(n.seen.size,256);
});

test('reused approval IDs in a new run are not suppressed',()=>{
 const {n,output}=fixture();const f=event('approval_required',{approval_id:'approval_1'});
 n.consume({state:{run:{run_id:'first'}}},f);n.consume({state:{run:{run_id:'second'}}},f);
 assert.equal(output.length,2);
});
