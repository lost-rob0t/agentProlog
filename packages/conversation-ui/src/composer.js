// Explicit, in-memory multiline drafts. Never interpret ordinary slash lines.
export class Composer {
  constructor(){this.lines=[];this.active=false;this.sending=false;}
  get text(){return this.lines.join('\n');}
  replace(lines){
    const text=lines.join('\n');
    if(lines.length>256||[...text].length>16000||Buffer.byteLength(text,'utf8')>16384)throw new Error('Draft limit: 256 lines / 16,000 characters / 16 KiB UTF-8.');
    this.lines=lines;
  }
  input(line){
    if(this.sending)throw new Error('Draft send is pending; wait for its result.');
    if(line==='/draft-pause'){this.active=false;return 'pause';}
    if(line==='/draft-discard'){this.lines=[];this.active=false;return 'discard';}
    const preview=/^\/draft-preview(?: ([1-9][0-9]*)(?: ([1-9][0-9]*))?)?$/.exec(line);
    if(preview){
      const start=preview[1]===undefined?1:Number(preview[1]);
      const end=preview[2]===undefined?Math.min(this.lines.length,start+19):Number(preview[2]);
      if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start>Math.max(1,this.lines.length)||end<start&&this.lines.length>0||end>this.lines.length||end-start>=50)throw new Error('Preview range must name existing lines, at most 50 at a time.');
      return {kind:'preview',start,end};
    }
    if(line==='/draft-undo'){this.lines.pop();return 'preview';}
    if(line==='/draft-send'||line==='/draft-send-image'){
      if(!this.text.trim())throw new Error('Draft is empty.');
      if(this.text.trimStart().startsWith('/'))throw new Error('Draft must begin with an objective, not a native slash command.');
      return line==='/draft-send'?'send':'send-image';
    }
    const edit=/^\/draft-edit ([1-9][0-9]*) (.*)$/.exec(line);
    if(edit){const index=Number(edit[1])-1;if(index>=this.lines.length)throw new Error('No such draft line.');const next=[...this.lines];next[index]=edit[2];this.replace(next);return 'preview';}
    const insert=/^\/draft-insert ([1-9][0-9]*) (.*)$/.exec(line);
    if(insert){
      const index=Number(insert[1])-1;
      if(!Number.isSafeInteger(index)||index>this.lines.length)throw new Error('Insert position must be 1 through the next draft line.');
      const next=[...this.lines];next.splice(index,0,insert[2]);this.replace(next);
      return {kind:'preview',start:Math.max(1,index-2),end:Math.min(this.lines.length,index+4)};
    }
    const remove=/^\/draft-delete ([1-9][0-9]*)$/.exec(line);
    if(remove){
      const index=Number(remove[1])-1;
      if(!Number.isSafeInteger(index)||index>=this.lines.length)throw new Error('No such draft line.');
      const next=[...this.lines];next.splice(index,1);this.replace(next);
      return {kind:'preview',start:Math.max(1,Math.min(index-2,this.lines.length)),end:Math.min(this.lines.length,index+4)};
    }
    if(line.startsWith('/draft-'))throw new Error('Unknown draft control; use /draft-literal TEXT to insert it literally.');
    this.replace([...this.lines,line]);return 'append';
  }
  literal(line){this.replace([...this.lines,line]);}
  sent(){this.lines=[];this.active=false;}
}
