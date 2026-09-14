#!/usr/bin/python3
import json, os, sys
from pathlib import Path
name=Path(sys.argv[0]).name; args=sys.argv[1:]
root=Path(os.environ['RICEHUB_TEST_ROOT'])
with (root/'commands.jsonl').open('a') as log: log.write(json.dumps([name,*args])+'\n')
if name=='wpctl':
    statefile=root/'audio.json'
    state=json.loads(statefile.read_text()) if statefile.exists() else {'volume':75,'muted':False}
    if args[0]=='get-volume': print(f"Volume: {state['volume']/100:.2f}" + (' [MUTED]' if state['muted'] else ''))
    elif args[0]=='set-volume': state['volume']=int(args[-1].rstrip('%'))
    elif args[0]=='set-mute': state['muted']=args[-1]=='1'
    else: sys.exit(4)
    statefile.write_text(json.dumps(state))
elif name=='pactl':
    if args[0]=='get-sink-volume': print('Volume: front-left: 49152 / 75% / -7.5 dB')
    elif args[0]=='get-sink-mute': print('Mute: no')
    else: assert args in [['set-sink-volume','@DEFAULT_SINK@','42%'],['set-sink-mute','@DEFAULT_SINK@','1']]
elif name=='apt':
    assert args==['list','--upgradable']; print('Listing...\nfixture/stable 2.0 amd64 [upgradable from: 1.0]')
elif name=='dnf':
    assert args in [['--cacheonly','check-upgrade'],['--refresh','check-upgrade']]
    print('fixture.x86_64 2.0 updates'); sys.exit(100)
elif name=='brightnessctl':
    statefile=root/'brightness'
    value=int(statefile.read_text()) if statefile.exists() else 80
    if args[-1]=='info': print(f'test_backlight,backlight,{value},{value}%,100')
    else:
        assert args[:2]==['--class=backlight','set']; statefile.write_text(args[-1].rstrip('%'))
elif name=='systemctl':
    assert args[0]=='--user'
    if 'list-units' in args:
        print(json.dumps([{'unit':'fixture.service','load':'loaded','active':'active','sub':'running','description':'Safe fixture'}, {'unit':'dbus.service','load':'loaded','active':'active','sub':'running','description':'Protected bus'}]))
    else: assert args[1:] in [['--no-block',a,'--','fixture.service'] for a in ('start','stop','restart')]
elif name=='pacman':
    assert args==['-Qu']; print('fixture-package 1.0 -> 2.0')
elif name=='checkupdates':
    assert args==['--nocolor']; print('fixture-package 1.0 -> 2.1')
elif name=='xdg-terminal-exec':
    assert args==['--hold','--title=RiceHub updates','--','sudo','pacman','-Syu']
else: sys.exit(5)
