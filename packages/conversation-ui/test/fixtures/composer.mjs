// Synthetic UI protocol fixture, not a production model.
import {createInterface} from 'node:readline';
import {readFileSync,appendFileSync} from 'node:fs';
const snapshot=JSON.parse(readFileSync(new URL('./session.ndjson',import.meta.url),'utf8').split('\n')[0]);
const send=f=>process.stdout.write(JSON.stringify(f)+'\n');
createInterface({input:process.stdin}).on('line',line=>{
 const f=JSON.parse(line);
 if(f.kind==='command')appendFileSync(process.argv[2],JSON.stringify(f)+'\n');
 send({protocol:f.protocol,kind:'result',session_id:snapshot.session_id,request_id:f.request_id,status:'ok',payload:{protocol:f.protocol}});
 if(f.kind==='negotiate')send(snapshot);
});
