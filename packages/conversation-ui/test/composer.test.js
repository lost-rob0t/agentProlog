import test from 'node:test';
import assert from 'node:assert/strict';
import {Composer} from '../src/composer.js';
test('multiline draft preserves blank lines, indent and literal slash commands',()=>{
 const c=new Composer();c.active=true;
 for(const l of ['Explain this:','  foo(X) :-','', '/cancel','  bar(X).'])c.input(l);
 assert.equal(c.text,'Explain this:\n  foo(X) :-\n\n/cancel\n  bar(X).');
 assert.equal(c.input('/draft-send'),'send');assert.equal(c.lines.length,5);
 c.input('/draft-edit 2   baz(X) :-');assert.equal(c.lines[1],'  baz(X) :-');
 c.input('/draft-undo');assert.equal(c.lines.length,4);
 c.input('/draft-pause');assert.equal(c.active,false);assert.equal(c.lines.length,4);
 c.sent();assert.equal(c.text,'');
});
test('bounded atomic edits, empty and native command send rejection',()=>{
 const c=new Composer();assert.throws(()=>c.input('/draft-send'),/empty/);
 c.input('  /ask echo nope');assert.throws(()=>c.input('/draft-send'),/native/);
 c.input('/draft-discard');c.input('x');assert.throws(()=>c.input('é'.repeat(8192)),/limit/);assert.equal(c.text,'x');
 assert.throws(()=>c.input('/draft-edit 2 x'),/No such/);assert.equal(c.text,'x');
 c.sending=true;assert.throws(()=>c.input('/draft-discard'),/pending/);assert.equal(c.text,'x');
});
test('canonical character and local byte limits include exact boundary and separators',()=>{
 const c=new Composer();c.input('x'.repeat(16000));assert.equal(c.input('/draft-send'),'send');
 assert.throws(()=>c.input('/draft-edit 1 '+'x'.repeat(16001)),/16,000/);
 assert.equal(c.text.length,16000);
 assert.throws(()=>c.input(''),/16,000/); // joining newline counts
 c.sent();c.input('é'.repeat(8192));assert.equal(Buffer.byteLength(c.text),16384);
 assert.equal(c.input('/draft-send'),'send');assert.throws(()=>c.input(''),/16 KiB/);
 c.sent();c.input('🌌'.repeat(4096));assert.equal([...c.text].length,4096);
 assert.equal(c.input('/draft-send'),'send');assert.throws(()=>c.input(''),/16 KiB/);
});
test('insert and delete preserve exact lines, bounds and pending-send isolation',()=>{
 const c=new Composer();c.input('/draft-insert 1 first');c.input('/draft-insert 2 last');
 c.input('/draft-insert 2   middle');assert.deepEqual(c.lines,['first','  middle','last']);
 c.input('/draft-insert 3 ');assert.equal(c.lines[2],'');
 c.input('/draft-delete 2');assert.deepEqual(c.lines,['first','','last']);
 for(const bad of ['/draft-insert 5 x','/draft-delete 4','/draft-insert 0 x','/draft-delete 999999999999999999999'])assert.throws(()=>c.input(bad));
 assert.deepEqual(c.lines,['first','','last']);
 c.sending=true;assert.throws(()=>c.input('/draft-delete 1'),/pending/);c.sending=false;
 c.replace(Array(256).fill('x'));assert.throws(()=>c.input('/draft-insert 1 x'),/limit/);assert.equal(c.lines.length,256);
});
test('preview is bounded, validates ranges and never mutates the draft',()=>{
 const c=new Composer();assert.deepEqual(c.input('/draft-preview'),{kind:'preview',start:1,end:0});
 c.replace(Array.from({length:100},(_,i)=>String(i+1)));
 assert.deepEqual(c.input('/draft-preview'),{kind:'preview',start:1,end:20});
 assert.deepEqual(c.input('/draft-preview 80'),{kind:'preview',start:80,end:99});
 assert.deepEqual(c.input('/draft-preview 51 100'),{kind:'preview',start:51,end:100});
 for(const bad of ['/draft-preview 1 51','/draft-preview 3 2','/draft-preview 101','/draft-preview 99 101'])assert.throws(()=>c.input(bad),/range/);
 assert.equal(c.lines.length,100);
 c.replace(['only']);c.input('/draft-delete 1');assert.equal(c.text,'');
});
