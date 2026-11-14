import {open,lstat} from 'node:fs/promises';
import {constants} from 'node:fs';
import {basename} from 'node:path';
export const MAX_IMAGE_BYTES=256*1024;
export async function selectImage(path) {
 if(typeof path!=='string'||!path.trim())throw new Error('Select one local PNG or JPEG file.');
 const before=await lstat(path);if(!before.isFile())throw new Error('Select a regular image file, not a link or device.');
 const file=await open(path,constants.O_RDONLY|(constants.O_NOFOLLOW??0)|(constants.O_NONBLOCK??0));
 try {
  const st=await file.stat();if(st.ino!==before.ino||st.dev!==before.dev)throw new Error('Selected image changed while opening.');if(!st.isFile()||st.size<1||st.size>MAX_IMAGE_BYTES)throw new Error('Image must be a regular file, 1–256 KiB.');
  const bytes=Buffer.alloc(MAX_IMAGE_BYTES+1);let size=0;
  while(size<bytes.length){const r=await file.read(bytes,size,bytes.length-size,null);if(!r.bytesRead)break;size+=r.bytesRead;}
  if(size>MAX_IMAGE_BYTES)throw new Error('Image grew beyond the 256 KiB limit.');
  const data=bytes.subarray(0,size);let mime;
  if(data.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))mime='image/png';
  else if(data[0]===255&&data[1]===216&&data[2]===255)mime='image/jpeg';
  else throw new Error('Only PNG/JPEG signatures are supported; no URLs or SVG.');
  const name=basename(path);if(name.length>128||/[\x00-\x1f\x7f\\/]/.test(name))throw new Error('Unsupported image filename.');
  return {name,mime,data:data.toString('base64')};
 } finally {await file.close();}
}
