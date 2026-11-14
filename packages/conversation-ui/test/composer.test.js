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
