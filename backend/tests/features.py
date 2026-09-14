#!/usr/bin/env python3
"""Config write/control integration tests; all writes and external actions use isolated fixtures."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/ricehub'
BASE = 'http://127.0.0.1:7070'
HEADERS = {'Content-Type':'application/json', 'X-RiceHub-Action':'control'}

def call(path, payload=None, status=200, headers=None):
    request = urllib.request.Request(BASE + path, data=json.dumps(payload).encode() if payload is not None else None,
        headers=HEADERS if headers is None and payload is not None else headers or {})
    try: response = urllib.request.urlopen(request, timeout=15)
    except urllib.error.HTTPError as error: response = error
    with response:
        result = json.load(response)
        assert response.status == status, (path, response.status, result)
        return result

def url(kind, path): return '/api/config/' + kind + '?path=' + urllib.parse.quote(path, safe='')

def spawn(env):
    with socket.socket() as probe:
        assert probe.connect_ex(('127.0.0.1',7070)) != 0, 'Stop the backend on port 7070 first'
    process = subprocess.Popen([str(BINARY)],env=env,stderr=subprocess.PIPE)
    for _ in range(100):
        if process.poll() is not None: raise AssertionError(process.stderr.read().decode())
        try:
            call('/api/system')
            return process
        except (OSError, urllib.error.URLError): time.sleep(.05)
    process.terminate(); process.wait(); raise AssertionError('Server failed to start')

with tempfile.TemporaryDirectory(prefix='ricehub-features-') as directory:
    root = Path(directory)
    config = root/'config'; config.mkdir()
    (config/'app').mkdir()
    path = config/'app'/'settings.conf'
    original = 'theme = dark\nfont_size = 12\n'
    path.write_text(original); path.chmod(0o640)
    (config/'file with spaces.conf').write_text('x = 1\n')
    (config/'binary').write_bytes(b'\x00\xff')
    (config/'large').write_bytes(b'x' * (256*1024+1))
    (config/'readonly').write_text('keep\n'); (config/'readonly').chmod(0o444)
    (config/'hard').write_text('hard linked\n'); os.link(config/'hard',config/'hard2')
    (root/'outside').write_text('outside must stay unchanged')
    (config/'link').symlink_to(root/'outside')
    (config/'linked-dir').symlink_to(root,target_is_directory=True)
    os.mkfifo(config/'fifo')
    binaries = root/'bin'; binaries.mkdir()
    log = root/'commands.jsonl'
    fixture = (Path(__file__).parent/'fixtures/control_command.py').read_text()
    for name in ['wpctl','brightnessctl','systemctl','pacman','checkupdates','xdg-terminal-exec']:
        tool=binaries/name; tool.write_text(fixture); tool.chmod(0o755)
    env=dict(os.environ,RICEHUB_DOTFILES=str(config),PATH=str(binaries),RICEHUB_TEST_ROOT=str(root),WAYLAND_DISPLAY='fixture')
    process=spawn(env)
    try:
        listing=call(url('list',''))
        assert any(e['name']=='app' and e['kind']=='directory' for e in listing['entries'])
        assert any(e['name']=='link' and e['kind']=='symlink' for e in listing['entries'])
        file=call(url('file','app/settings.conf'))
        assert file['content']==original and file['editable']
        assert call(url('file','file with spaces.conf'))['content']=='x = 1\n'
        payload={'path':file['path'],'content':'theme = light\nfont_size = 14\n','revision':file['revision']}
        call('/api/config/save',payload,status=403,headers={'Content-Type':'application/json'})
        call('/api/config/save',payload,status=403,headers={**HEADERS,'Origin':'https://evil.example'})
        call('/api/config/save',{**payload,'unexpected':True},status=400)
        saved=call('/api/config/save',payload)
        assert saved['ok'] and path.read_text()==payload['content']
        backup=Path(saved['backup']); assert backup.read_text()==original
        assert backup.stat().st_mode&0o777==0o600 and path.stat().st_mode&0o777==0o640
        call('/api/config/save',payload,status=409)
        call('/api/config/save',{**payload,'revision':saved['revision']},status=400)
        reopened=call(url('file','app/settings.conf'))
        path.write_text('external edit\n')
        call('/api/config/save',{**payload,'revision':reopened['revision']},status=409)
        assert path.read_text()=='external edit\n'
        assert not any(e['name'].startswith('.ricehub-') for e in call(url('list','app'))['entries'])
        for bad in ['../outside','/etc/passwd','app/../../outside','.git/config','app//settings.conf','app/./settings.conf','app/\x00file']:
            call(url('file',bad),status=400)
        call(url('file','link'),status=403)
        call(url('file','linked-dir/outside'),status=503)
        for name in ['binary','fifo']: call(url('file',name),status=415)
        call(url('file','large'),status=413)
        for name in ['readonly','hard']:
            readonly=call(url('file',name)); assert not readonly['editable']
            call('/api/config/save',{'path':name,'content':'new','revision':readonly['revision']},status=403)
        assert (root/'outside').read_text()=='outside must stay unchanged'
        assert call('/api/controls/audio')['volume']==75
        assert call('/api/controls/audio',{'action':'volume','value':42})['volume']==42
        assert call('/api/controls/audio',{'action':'mute','value':1})['muted']
        call('/api/controls/audio',{'action':'volume','value':101},status=400)
        call('/api/controls/audio',{'action':'mute','value':2},status=400)
        assert call('/api/controls/brightness')['value']==80
        assert call('/api/controls/brightness',{'value':50})['value']==50
        call('/api/controls/brightness',{'value':0},status=400)
        assert len(call('/api/controls/services')['services'])==2
        call('/api/controls/services',{'unit':'fixture.service','action':'restart'})
        call('/api/controls/services',{'unit':'dbus.service','action':'stop'},status=403)
        call('/api/controls/services',{'unit':'unknown.service','action':'restart'},status=404)
        call('/api/controls/services',{'unit':'fixture.service; touch /tmp/oops','action':'restart'},status=400)
        call('/api/controls/services',{'unit':'fixture.service','action':'enable'},status=400)
        assert call('/api/controls/updates')['packages']==['fixture-package 1.0 -> 2.0']
        assert call('/api/controls/updates/check',{})['packages']==['fixture-package 1.0 -> 2.1']
        call('/api/controls/updates/apply',{'manager':'apt'},status=409)
        call('/api/controls/updates/apply',{'manager':'arch'},status=202)
        time.sleep(.1)
        calls=[json.loads(line) for line in log.read_text().splitlines()]
        assert ['xdg-terminal-exec','--hold','--title=RiceHub updates','--','sudo','pacman','-Syu'] in calls
        assert ['systemctl','--user','--no-block','restart','--','fixture.service'] in calls
        assert not any('unknown.service' in args for args in calls)
    finally:
        process.terminate(); process.wait(timeout=5)
        errors=process.stderr.read().decode(); process.stderr.close()
        assert 'panic' not in errors, errors
    # Exercise fallbacks with only their tool visible on PATH.
    for tool in ['pactl', 'apt', 'dnf']:
        fallback = root / ('fallback-' + tool); fallback.mkdir()
        executable = fallback / tool; executable.write_text(fixture); executable.chmod(0o755)
        env['PATH'] = str(fallback)
        process = spawn(env)
        try:
            if tool == 'pactl':
                assert call('/api/controls/audio')['tool'] == 'pactl'
                call('/api/controls/audio', {'action':'volume','value':42})
                call('/api/controls/audio', {'action':'mute','value':1})
            else:
                assert call('/api/controls/updates')['manager'] == tool
                assert call('/api/controls/updates/check', {})['packages']
        finally:
            process.terminate(); process.wait(timeout=5); process.stderr.close()
    empty=root/'empty-bin'; empty.mkdir(); env['PATH']=str(empty)
    process=spawn(env)
    try:
        for endpoint in ['audio','brightness','services','updates']:
            call('/api/controls/'+endpoint,status=503)
        assert call(url('file','app/settings.conf'))['content']=='external edit\n'
    finally:
        process.terminate(); process.wait(timeout=5); process.stderr.close()
print('PASS: config browse/read/save/backup/conflicts/confinement; audio, brightness, services, updates; missing tools. All mutations isolated.')
