import { safe, publicValue } from './render.js';
import isFullwidthCodePoint from './vendor/unicode-width/index.js';
// Presentation clock only. Never estimates hidden reasoning tokens or inspects it.
export class Activity {
  constructor(now=()=>Date.now()) { this.now=now;this.started=null;this.tokens=null;this.run=null;this.turns=[]; }
  consume(view,frame) {
    if(frame?.kind==='snapshot') { this.started=view.state?.status==='running'?this.now():null;this.run=view.state?.run?.run_id;this.tokens=null;this.turns=[]; }
    if(frame?.event_type==='run_started') { this.started=this.now();this.run=frame.payload?.run_id;this.tokens=null;this.turns.push({at:view.state?.messages?.length??0,text:frame.payload?.objective});this.turns=this.turns.slice(-8); }
    if(frame?.event_type==='usage') {
      const u=frame.payload;
      if(u?.tokens_known===false) {this.tokens=null;return;}
      const value=u?.total_tokens;
      if(Number.isSafeInteger(value)&&value>=0)this.tokens=value;
      else if(Number.isSafeInteger(u?.input_tokens)&&Number.isSafeInteger(u?.output_tokens)&&u.input_tokens>=0&&u.output_tokens>=0)this.tokens=u.input_tokens+u.output_tokens;
    }
  }
  elapsed() { return this.started===null?null:Math.max(0,(this.now()-this.started)/1000); }
}
const clip=(s,n)=>safe(s).slice(0,n);
// Unicode grapheme boundaries prevent splitting combining/emoji sequences.
// East Asian W/F widths use the complete Unicode 17 normative table.
// Ambiguous-width characters use the common one-column terminal policy.
// ZWJ emoji rendering varies by emulator (VTE may draw separate glyphs). Show
// joined components separated by a space rather than undercount their cells.
// This is presentation only; canonical transcript content remains unchanged.
const segmenter=new Intl.Segmenter(undefined,{granularity:'grapheme'});
const segments=text=>Array.from(segmenter.segment(safe(text).replaceAll('\t','    ').replaceAll('\u200d',' ')),x=>x.segment);
const cellWidth=cluster=>{
 if(/\p{Emoji_Presentation}|\uFE0F|\u20E3/u.test(cluster))return 2;
 const bases=Array.from(cluster).filter(c=>!/[\p{Mark}\p{Default_Ignorable_Code_Point}]/u.test(c));
 if(!bases.length)return 0;
 return bases.some(c=>isFullwidthCodePoint(c.codePointAt(0)))?2:1;
};
export const displayWidth=text=>segments(text).reduce((n,c)=>n+cellWidth(c),0);
const fit=(text,width)=>{
 let out='',n=0;for(const c of segments(text)){const w=cellWidth(c);if(n+w>width)break;out+=c;n+=w;}
 return out+' '.repeat(Math.max(0,width-n));
};
export function wrapText(text,width) {
 const rows=[];for(const line of safe(text).split('\n')){
  let out='',n=0;for(const c of segments(line)){const w=cellWidth(c);if(n+w>width){rows.push(out);out='';n=0;}out+=c;n+=w;}rows.push(out);
 }return rows;
}
// Bounded presentation-only scrollback. Never sends commands to the session.
// Pausing freezes just transcript lines; live authority/status is still rendered.
export class TranscriptViewport {
 constructor(){this.live=[];this.frozen=null;this.top=0;this.rows=1;}
 select(lines,rows){
  this.live=lines;this.rows=Math.max(1,rows);
  const source=this.frozen??lines,max=Math.max(0,source.length-this.rows);
  const start=this.frozen?Math.min(this.top,max):max;
  return source.slice(start,start+this.rows);
 }
 page(direction){
  if(direction<0&&!this.frozen){this.frozen=this.live.slice();this.top=Math.max(0,this.frozen.length-this.rows);}
  if(!this.frozen)return;
  this.top=Math.max(0,this.top+direction*Math.max(1,this.rows-2));
  if(this.top>=Math.max(0,this.frozen.length-this.rows))this.bottom();
 }
 bottom(){this.frozen=null;this.top=0;}
 get paused(){return this.frozen!==null;}
}
export function renderChat(view,connected=true,activity=new Activity(),color=false,layout={}) {
 const cols=Math.max(20,Math.min(240,layout.columns??96));
 const height=Math.max(10,Math.min(100,layout.rows??30))-2;
 const side=cols>=110?29:0, gap=side?3:0,main=cols-4-side-gap;
 const s=view.state??{},running=s.status==='running'&&!s.run?.outcome;
 const pending=(s.approvals??[]).filter(x=>x.status==='pending'),questions=(s.questions??[]).filter(x=>x.status==='pending');
 const tools=(s.tools??[]).filter(x=>x.status==='running');
 const status=!connected?'Disconnected':pending.length?'Awaiting approval':questions.length?'Awaiting your answer':running?(tools.length?'Working':'Thinking'):(s.run?.outcome?.status??s.status??'Connecting');
 const elapsed=activity.elapsed();
 const timing=elapsed===null?'elapsed unknown':`${elapsed.toFixed(1)}s observed`;
 const usage=activity.tokens===null?'tokens pending':`${activity.tokens} reported total tokens`;
 const accent=x=>color?`\x1b[38;5;80m${x}\x1b[0m`:x;
 const muted=x=>color?`\x1b[38;5;245m${x}\x1b[0m`:x;
 const lines=[accent('  '+fit('AGENTPROLOG  /  DSH',cols-4)),muted('  '+fit((layout.profile??s.run?.profile??'Native Prolog workspace')+(layout.viewport?.paused?' · PAUSED TRANSCRIPT':''),cols-4)),muted('  '+'─'.repeat(cols-4))];
 const content=[];
 const all=s.messages??[];
 const messages=all.filter(m=>['user','assistant'].includes(m.role)).slice(-8);
 const objective=s.run?.objective;
 if(objective&&!activity.turns.length&&!messages.some(m=>m.role==='user'&&m.text===objective)){
  content.push('CURRENT REQUEST',...wrapText(clip(objective,16000),main),'');
 }
 for(const m of messages){
  for(const turn of activity.turns.filter(t=>t.at===all.indexOf(m)&&t.text))
   content.push('YOU',...wrapText(clip(turn.text,16000),main),'');
  content.push(m.role==='user'?'YOU':`AGENTPROLOG${m.status==='streaming'?'  · typing':''}`,...wrapText(clip(m.text,12000),main),'');
 }
 for(const turn of activity.turns.filter(t=>t.at>=all.length&&t.text))content.push('YOU',...wrapText(clip(turn.text,16000),main),'');
 if(!content.length)content.push('What are we building?','','Ask a question or describe a change.','Your configured tools and approvals stay in control.','','/ask NAME QUESTION   Consult a symbolic expert','/army tasks JSON     Delegate bounded tasks','/image PATH          Stage an image, not sent','/help                All commands');
 const rail=['SESSION',connected?'● Connected':'○ Disconnected',status,'', 'TOOLS',...(tools.length?tools.map(t=>'› '+clip(t.name,24)):['No tools running']),'','APPROVALS',pending.length?`${pending.length} waiting · /approve`:'None pending',questions.length?`${questions.length} questions · /answer`:'','CONTEXT','/inspect  Evidence & usage','/profile  Active capabilities','/handoff  Workflow summary'];
 const reserve=5,bodyRows=height-lines.length-reserve;
 // Latest output remains visible. Full canonical transcript stays in /inspect.
 const visible=layout.viewport?layout.viewport.select(content,bodyRows):content.slice(-bodyRows);
 for(let i=0;i<bodyRows;i++){
  const raw=visible[i]??'';
  const left=/^(YOU|CURRENT REQUEST|AGENTPROLOG)( |$)/.test(raw)?accent(fit(raw,main)):fit(raw,main);
  const right=side?muted(' │ '+fit(rail[i]??'',side)):'';
  lines.push('  '+left+right);
 }
 let notice=s.indeterminate_effects?.length?'Uncertain effects · /inspect before retrying':pending.length?`${pending.length} approval(s) waiting · /approve to inspect exact action`:questions.length?`${questions.length} question(s) waiting · /answer`:layout.viewport?.paused?'Viewing paused transcript · /bottom returns to live output':'';
 lines.push(muted('  '+fit(notice,cols-4)));
 const stateText=running?`${!connected?'Paused · connection lost':status} · ${usage} · ${timing}`:`${status} · ${usage}`;
 lines.push(accent('  '+fit(stateText,cols-4)));
 lines.push(muted('  '+'─'.repeat(cols-4)));
 lines.push(muted('  '+fit(layout.image?`Attached locally: ${layout.image} · /send-image QUESTION to transmit`:'Message the agent  ·  Enter send  ·  /help commands',cols-4)));
 lines.push(muted('  '+fit('PgUp/PgDn history   /bottom live   /inspect evidence   /cancel stop',cols-4)));
 return lines.join('\n');
}

export function approvalDetails(row) {
  return `Approval details\n${safe(JSON.stringify(publicValue(row),null,2))}`;
}
export function shouldRedraw(tty, interaction) {return !(tty&&interaction!==null);}
