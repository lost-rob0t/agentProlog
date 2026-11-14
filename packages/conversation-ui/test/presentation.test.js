import test from 'node:test';
import assert from 'node:assert/strict';
import {Activity,renderChat} from '../src/presentation.js';
const view=()=>({sessionId:'session',state:{status:'running',run:{run_id:'run'},usage:{},messages:[],tools:[],approvals:[],questions:[],indeterminate_effects:[]}});
test('thinking facade reports observed elapsed and only real usage',()=>{
 let now=1000;const a=new Activity(()=>now),v=view();a.consume(v,{event_type:'run_started',payload:{run_id:'run'}});now=2500;
 assert.match(renderChat(v,true,a),/Thinking · tokens pending · 1.5s observed/);
 a.consume(v,{event_type:'usage',payload:{total_tokens:42}});assert.match(renderChat(v,true,a),/42 reported total tokens/);
 a.consume(v,{event_type:'run_started',payload:{run_id:'next'}});assert.equal(a.tokens,null);
});
test('snapshot and disconnect do not invent historical timing or active work',()=>{
 const a=new Activity(()=>10),v=view();a.consume(v,{kind:'snapshot'});assert.match(renderChat(v,false,a),/Paused · connection lost/);assert.equal(a.tokens,null);
});
test('reasoning roles and tool payloads never appear in chat facade',()=>{
 const v=view();v.state.messages=[{role:'reasoning',text:'PRIVATE_MARKER'},{role:'assistant',text:'visible',status:'streaming'}];
 v.state.tools=[{name:'read',status:'running',output:{reasoning:'PRIVATE_MARKER'}}];
 const text=renderChat(v);assert.doesNotMatch(text,/PRIVATE_MARKER/);assert.match(text,/visible/);assert.match(text,/typing/);
});
test('waiting states take priority and injected terminal controls are removed',()=>{
 const v=view();v.state.approvals=[{status:'pending'}];v.state.messages=[{role:'assistant',text:'hi\x1b[31m'}];
 assert.match(renderChat(v),/Awaiting approval/);assert.doesNotMatch(renderChat(v),/\x1b/);
});
import {render} from '../src/render.js';
test('inspect hides explicit reasoning fields too',()=>{
 const v=view();Object.assign(v.state,{subagents:[],verification:[],extensions:[],traces:[{reasoning:'PRIVATE_MARKER'}],usage:{},tools:[{output:{reasoning_details:'PRIVATE_MARKER',exit_code:0}}]});
 v.state.messages=[{role:'analysis',text:'PRIVATE_MARKER'}];assert.doesNotMatch(render(v),/PRIVATE_MARKER/);assert.match(render(v),/exit_code/);
});

test('unknown usage clears a previous known count rather than reporting zero',()=>{
 const a=new Activity(),v=view();a.consume(v,{event_type:'usage',payload:{total_tokens:12,tokens_known:true}});
 assert.equal(a.tokens,12);a.consume(v,{event_type:'usage',payload:{total_tokens:0,tokens_known:false}});
 assert.equal(a.tokens,null);assert.match(renderChat(v,true,a),/tokens pending/);assert.doesNotMatch(renderChat(v,true,a),/0 reported total/);
});

import {approvalDetails,shouldRedraw} from '../src/presentation.js';
test('approval preview includes exact diff and arguments but not control codes or reasoning',()=>{
 const t=approvalDetails({id:'a',diff:{target:'file.js',old:'one',new:'two',argv:['--test']},reasoning:'PRIVATE_MARKER',prompt:'\x1b[31m'});
 assert.match(t,/file.js/);assert.match(t,/--test/);assert.match(t,/one/);assert.match(t,/two/);assert.doesNotMatch(t,/PRIVATE_MARKER|\x1b/);
});
test('TTY interaction remains visible across heartbeat; normal and piped renders continue',()=>{
 assert.equal(shouldRedraw(true,{kind:'approve',id:'a'}),false);
 assert.equal(shouldRedraw(true,{kind:'select'}),false);
 assert.equal(shouldRedraw(true,null),true);assert.equal(shouldRedraw(false,{kind:'approve'}),true);
});

import {displayWidth,wrapText} from '../src/presentation.js';
test('adaptive editor fills viewport and hides raw session identifiers',()=>{
 for(const columns of [20,40,80,120]){
  const text=renderChat(view(),true,new Activity(),false,{columns,rows:24,profile:'local'});
  assert.equal(text.split('\n').length,22);
  for(const line of text.split('\n'))assert.ok(displayWidth(line)<=columns,line);
  assert.doesNotMatch(text,/session|run_id/);
  if(columns<110)assert.doesNotMatch(text,/APPROVALS/);
 }
});
test('long responses stay above anchored composer with Unicode-aware wrapping',()=>{
 const v=view();v.state.messages=[{role:'assistant',text:'🌌 café '.repeat(1000)}];
 const text=renderChat(v,true,new Activity(),false,{columns:60,rows:20});
 assert.equal(text.split('\n').length,18);
 assert.match(text.split('\n').slice(-2).join(' '),/Message the agent/);
 assert.ok(wrapText('🌌🌌🌌',4).every(x=>displayWidth(x)<=4));
});
test('observed user turns stay interleaved with their replies',()=>{
 const v=view(),a=new Activity();
 a.consume(v,{event_type:'run_started',payload:{objective:'first'}});
 v.state.messages.push({role:'assistant',text:'one'});
 a.consume(v,{event_type:'run_started',payload:{objective:'second'}});
 v.state.messages.push({role:'assistant',text:'two'});
 const text=renderChat(v,true,a);
 assert.ok(text.indexOf('first')<text.indexOf('one'));
 assert.ok(text.indexOf('one')<text.indexOf('second'));
 assert.ok(text.indexOf('second')<text.indexOf('two'));
});

test('terminal cell counts cover Hangul, fullwidth Latin, and grapheme clusters',()=>{
 // Literal independent expectations, not assertions against the same helper.
 for(const [text,width] of [['한글',4],['ＡＢＣ',6],['가나다',6],['日本語',6],
  ['e\u0301',1],['👩‍💻',5],['🇰🇷',2],['1️⃣',2],['가',2]]){
  assert.equal(displayWidth(text),width,text);
 }
 assert.deepEqual(wrapText('한글가나다',4),['한글','가나','다']);
 assert.deepEqual(wrapText('ＡＢＣＤ',4),['ＡＢ','ＣＤ']);
 assert.deepEqual(wrapText('👩‍💻🇰🇷e\u0301',2),['👩',' ','💻','🇰🇷','e\u0301']);
});
test('wide-text viewport uses expected terminal columns, not code point count',()=>{
 const v=view();v.state.messages=[{role:'assistant',text:'한글'.repeat(8)}];
 const rows=renderChat(v,true,new Activity(),false,{columns:20,rows:18}).split('\n');
 // 16 text cells available; each Korean syllable consumes two actual cells.
 assert.ok(rows.includes('  한글한글한글한글'));
 assert.equal(rows.length,16);
});

test('literal tabs are expanded to four spaces before layout or terminal output',()=>{
 assert.deepEqual(wrapText('a\tb',6),['a    b']);
 assert.equal(displayWidth('a\tb'),6);
 const v=view();v.state.messages=[{role:'assistant',text:'one\ttwo'}];
 assert.doesNotMatch(renderChat(v),/\t/);
 assert.match(renderChat(v),/one    two/);
});

test('Unicode wide scripts omitted by legacy tables consume two terminal cells',()=>{
 for(const cp of [0x1B170,0x17000,0x16FE0,0x18D00,0x1B132]){
  const text=String.fromCodePoint(cp);
  assert.equal(displayWidth(text),2,'U+'+cp.toString(16));
  assert.deepEqual(wrapText(text.repeat(3),4),[text.repeat(2),text]);
 }
});
