// Optional real PTY/emulator test, not a mocked width calculation.
// Run interactively; uses standard ANSI cursor-position requests.
import assert from 'node:assert/strict';
import {displayWidth,wrapText} from '../src/presentation.js';
if(!process.stdin.isTTY||!process.stdout.isTTY)throw new Error('Run in an interactive terminal');
process.stdin.setRawMode(true);process.stdin.resume();
async function columns(text){return new Promise((resolve,reject)=>{
 let input='';const timer=setTimeout(()=>{process.stdin.off('data',read);reject(Error('terminal DSR timeout'));},3000);
 const read=chunk=>{input+=chunk;const m=/\x1b\[(\d+);(\d+)R/.exec(input);
  if(m){clearTimeout(timer);process.stdin.off('data',read);resolve(Number(m[2])-1);}};
 process.stdin.on('data',read);process.stdout.write('\r\x1b[2K'+text+'\x1b[6n');
});}
try{
 const results=[];
 for(const [text,expected] of [['\u{1B170}',2],['\u{17000}',2],['\u{16FE0}',2],['한글',4],['ＡＢＣ',6],['e\u0301',1],['a\tb',6],['🌌',2],['👩‍💻',5],['🇰🇷',2]]){
  const rendered=wrapText(text,60).join('');
  const actual=await columns(rendered);
  results.push({text,rendered,actual,expected,estimated:displayWidth(text)});
  assert.equal(actual,expected,text);
  assert.equal(displayWidth(text),actual,text);
 }
 console.log('\r\n'+JSON.stringify(results,null,2));
}finally{process.stdin.setRawMode(false);process.stdin.pause();}
