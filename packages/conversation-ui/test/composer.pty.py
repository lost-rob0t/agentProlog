"""Real PTY + production CLI; synthetic sidecar, no model or external service."""
import json, os, pty, select, subprocess, tempfile, time, pathlib, sys
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    log=pathlib.Path(tmp)/'commands.jsonl'
    master, slave=pty.openpty()
    p=subprocess.Popen([sys.argv[1],str(root/'src/cli.js'),'--sidecar',sys.argv[1],'--sidecar-arg',str(root/'test/fixtures/composer.mjs'),'--sidecar-arg',str(log)],stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
    os.close(slave)
    def expect(needle):
        data=b'';end=time.monotonic()+5
        while needle not in data and time.monotonic()<end:
            if select.select([master],[],[],.1)[0]:data+=os.read(master,65536)
        assert needle in data,(needle,data[-2000:])
    def line(text):os.write(master,text.encode()+b'\r')
    try:
        expect(b'  \xe2\x80\xba ')
        line('/compose');expect(b'draft 1>')
        line('Review this:');expect(b'draft 2>')
        line('  foo(X).');expect(b'draft 3>')
        line('');expect(b'draft 4>')
        line('/cancel');expect(b'draft 5>')
        assert not log.exists(),'draft executed a slash command'
        line('/draft-edit 2   bar(X).');expect(b'2:   bar(X).')
        line('/draft-pause');expect(b'  \xe2\x80\xba ')
        line('/compose');expect(b'draft 5>')
        line('/draft-send');expect(b'  \xe2\x80\xba ')
        commands=[json.loads(x) for x in log.read_text().splitlines()]
        assert len(commands)==1,commands
        assert commands[0]['payload']['objective']=='Review this:\n  bar(X).\n\n/cancel',commands
        line('/quit');p.wait(timeout=5)
    finally:
        if p.poll() is None:p.terminate();p.wait(timeout=5)
        os.close(master)
print('PTY multiline draft: pass')
