// Local signals only. No network, shell hooks, OS permission or subscriptions.
export const NOTIFICATION_EVENTS = ['approval','question','complete','failed','cancelled'];
const labels = {approval:'Approval needed.',question:'Answer needed.',
  complete:'Run completed. External results may still need verification.',
  failed:'Run did not complete successfully.',cancelled:'Run cancelled.'};
export function notificationOptions(mode='off', events=NOTIFICATION_EVENTS.join(',')) {
  if (!['off','text','bell'].includes(mode)) throw new Error('--notify must be off, text or bell');
  const selected=events.split(',');
  if (!selected.length || selected.some(x=>!NOTIFICATION_EVENTS.includes(x)))
    throw new Error('--notify-on expects comma-separated approval,question,complete,failed,cancelled');
  return {mode,events:new Set(selected)};
}
export class Notifications {
  constructor(options, {write, isTTY=false}) {
    this.options=options; this.write=write; this.isTTY=isTTY; this.seen=new Set();
  }
  consume(view, frame) {
    if (this.options.mode==='off' || frame?.kind!=='event') return;
    const p=frame.payload;let kind, identity;
    if(frame.event_type==='approval_required') {kind='approval';identity=p.approval_id;}
    else if(frame.event_type==='question_required') {kind='question';identity=p.question_id;}
    else if(frame.event_type==='run_finished') {
      const status=p.outcome?.status;
      kind=['complete','completed','ok'].includes(status)?'complete':status==='cancelled'?'cancelled':'failed';
      identity=view.state?.run?.run_id ?? frame.event_id;
    } else return;
    if(!this.options.events.has(kind)) return;
    const key=JSON.stringify([frame.session_id,view.state?.run?.run_id,kind,identity]);
    if(this.seen.has(key)) return;
    this.seen.add(key);
    // Bound local deduplication. Protocol sequence checks reject actual replay.
    if(this.seen.size>256) this.seen.delete(this.seen.values().next().value);
    if(this.options.mode==='bell') {if(this.isTTY) this.write('\x07');}
    else this.write(`\n[AgentProlog] ${labels[kind]}\n`);
  }
}
