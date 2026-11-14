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
    if(line==='/draft-preview')return 'preview';
    if(line==='/draft-undo'){this.lines.pop();return 'preview';}
    if(line==='/draft-send'||line==='/draft-send-image'){
      if(!this.text.trim())throw new Error('Draft is empty.');
      if(this.text.trimStart().startsWith('/'))throw new Error('Draft must begin with an objective, not a native slash command.');
      return line==='/draft-send'?'send':'send-image';
    }
    const edit=/^\/draft-edit ([1-9][0-9]*) (.*)$/.exec(line);
    if(edit){const index=Number(edit[1])-1;if(index>=this.lines.length)throw new Error('No such draft line.');const next=[...this.lines];next[index]=edit[2];this.replace(next);return 'preview';}
    if(line.startsWith('/draft-'))throw new Error('Unknown draft control; use /draft-literal TEXT to insert it literally.');
    this.replace([...this.lines,line]);return 'append';
  }
  literal(line){this.replace([...this.lines,line]);}
  sent(){this.lines=[];this.active=false;}
}
