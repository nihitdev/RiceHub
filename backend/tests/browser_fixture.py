#!/usr/bin/env python3
"""Serve safe temporary config/control fixtures on port 7070 for manual browser testing."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile

with socket.socket() as probe:
    assert probe.connect_ex(('127.0.0.1',7070)) != 0, 'Stop the real backend first'

def stop(*_): raise KeyboardInterrupt
signal.signal(signal.SIGTERM, stop)
with tempfile.TemporaryDirectory(prefix='ricehub-browser-') as directory:
    root=Path(directory)
    config=root/'config'; (config/'demo').mkdir(parents=True)
    (config/'demo/settings.conf').write_text('theme = dark\nfont_size = 12\n')
    (config/'demo/second.conf').write_text('another = file\n')
    binaries=root/'bin'; binaries.mkdir()
    fixture=(Path(__file__).parent/'fixtures/control_command.py').read_text()
    for name in ['wpctl','brightnessctl','systemctl','pacman','checkupdates','xdg-terminal-exec']:
        executable=binaries/name; executable.write_text(fixture); executable.chmod(0o755)
    env=dict(os.environ,RICEHUB_DOTFILES=str(config),PATH=str(binaries),RICEHUB_TEST_ROOT=str(root),WAYLAND_DISPLAY='fixture')
    env.pop('HYPRLAND_INSTANCE_SIGNATURE',None)
    print(json.dumps({'fixture_root':str(root)}),flush=True)
    process=subprocess.Popen([str(Path(__file__).resolve().parents[1]/'zig-out/bin/ricehub')],env=env)
    try: process.wait()
    except KeyboardInterrupt: pass
    finally:
        process.terminate(); process.wait(timeout=5)
