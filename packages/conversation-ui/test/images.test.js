import test from 'node:test';import assert from 'node:assert/strict';
import {mkdtemp,writeFile,symlink,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';
import {selectImage,MAX_IMAGE_BYTES} from '../src/images.js';
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=','base64');
test('explicit file selection produces exact bounded image bytes and basename',async t=>{
 const d=await mkdtemp(join(tmpdir(),'image-test-'));t.after(()=>rm(d,{recursive:true,force:true}));const p=join(d,'pixel.png');await writeFile(p,png);
 assert.deepEqual(await selectImage(p),{name:'pixel.png',mime:'image/png',data:png.toString('base64')});
 await symlink(p,join(d,'link.png'));await assert.rejects(selectImage(join(d,'link.png')));
 await writeFile(p,Buffer.alloc(MAX_IMAGE_BYTES+1));await assert.rejects(selectImage(p),/256 KiB/);
 await writeFile(p,'not an image');await assert.rejects(selectImage(p),/PNG\/JPEG/);
});
