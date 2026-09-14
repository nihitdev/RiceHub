#!/usr/bin/env python3
"""Live Linux API checks; temporary Git and hyprctl fixtures never reload the desktop."""
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/ricehub'
BASE = 'http://127.0.0.1:7070'


def request(path, method='GET', headers=None, body=None, status=200):
    req = urllib.request.Request(BASE + path, method=method, headers=headers or {}, data=body)
    try:
        response = urllib.request.urlopen(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        data = json.load(response)
        assert response.status == status, (path, response.status, data)
        assert response.headers['Cache-Control'] == 'no-store'
        return data


def start(env):
    with socket.socket() as probe:
        assert probe.connect_ex(('127.0.0.1', 7070)) != 0, 'Port 7070 is occupied; stop the dev backend first'
    process = subprocess.Popen([str(BINARY)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    for _ in range(100):
        if process.poll() is not None:
            raise AssertionError(process.stderr.read().decode())
        try:
            request('/api/system')
            # Ensure a preexisting listener did not answer for this process.
            time.sleep(.1)
            assert process.poll() is None, 'Port 7070 is occupied; stop the dev backend first'
            return process
        except (OSError, urllib.error.URLError):
            time.sleep(.05)
    process.terminate()
    process.wait()
    raise AssertionError('Backend startup timed out')


def stop(process):
    process.terminate()
    process.wait(timeout=5)
    process.stderr.close()


with tempfile.TemporaryDirectory(prefix='ricehub-test-') as temporary:
    root = Path(temporary)
    repo = root / 'config repo with spaces'
    repo.mkdir()
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL)
    git('init', '-b', 'test-branch')
    (repo / 'config').write_text('test fixture\n')
    git('add', '.')
    git('-c', 'user.name=RiceHub Test', '-c', 'user.email=test@localhost', 'commit', '-m', 'fixture')
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    marker = root / 'reload-called'
    fail_marker = root / 'reload-fail'
    command = bin_dir / 'hyprctl'
    command.write_text('#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\n'
                       'assert sys.argv[1:] == ["reload"]\n'
                       f'Path({str(marker)!r}).write_text("reload")\n'
                       f'sys.exit(1 if Path({str(fail_marker)!r}).exists() else 0)\n')
    command.chmod(0o755)
    env = dict(os.environ, RICEHUB_DOTFILES=str(repo), HYPRLAND_INSTANCE_SIGNATURE='test-fixture',
               PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])
    process = start(env)
    try:
        system = request('/api/system')
        assert system['kernel'] == platform.release(), system
        assert system['hostname'] == socket.gethostname(), system
        uptime = float(Path('/proc/uptime').read_text().split()[0])
        assert abs(system['uptime_seconds'] - uptime) < 5
        memory = request('/api/memory')
        total = int(next(line for line in Path('/proc/meminfo').read_text().splitlines()
                         if line.startswith('MemTotal:')).split()[1]) * 1024
        assert memory['total_bytes'] == total
        assert 0 <= memory['used_bytes'] <= total
        assert memory['used_bytes'] + memory['available_bytes'] == total
        cpu = request('/api/cpu')
        cores = sum(line.split(':')[0].strip() == 'processor'
                    for line in Path('/proc/cpuinfo').read_text().splitlines())
        assert cpu['logical_cores'] == cores and cores > 0
        clean = request('/api/dotfiles')
        assert clean['available'] and clean['branch'] == 'test-branch' and clean['changed_files'] == 0
        git('mv', 'config', 'renamed config')
        (repo / 'untracked').write_text('test\n')
        dirty = request('/api/dotfiles')
        assert dirty['dirty'] and dirty['changed_files'] == 2, dirty
        request('/api/nope', status=404)
        request('/api/system', method='POST', status=405)
        request('/api/hypr/reload', status=405)
        request('/api/hypr/reload', method='POST', status=403)
        action = {'X-RiceHub-Action': 'reload'}
        request('/api/hypr/reload', method='POST', headers={**action, 'Origin': 'https://evil.example'}, status=403)
        request('/api/hypr/reload', method='POST', headers=action, body=b'{}', status=400)
        request('/api/hypr/reload?command=anything', method='POST', headers=action, status=404)
        request('/api/system', headers={'Host': 'evil.example'}, status=403)
        assert not marker.exists(), 'Rejected requests must never execute commands'
        assert request('/api/hypr/reload', method='POST', headers={**action, 'Origin': 'http://127.0.0.1:5173'})['ok']
        assert marker.read_text() == 'reload'
        fail_marker.touch()
        assert request('/api/hypr/reload', method='POST', headers=action, status=503)['error_message'] == 'HyprlandReloadFailed'
    finally:
        stop(process)
    env.pop('HYPRLAND_INSTANCE_SIGNATURE')
    env['RICEHUB_DOTFILES'] = str(root / 'missing')
    process = start(env)
    try:
        assert not request('/api/system')['hyprland_available']
        assert request('/api/hypr/reload', method='POST', headers=action, status=503)['error_message'] == 'HyprlandUnavailable'
        assert not request('/api/dotfiles')['available']
    finally:
        stop(process)
    # Ordinary config directories are discoverable without Git or an explicit setting.
    env.pop('RICEHUB_DOTFILES')
    env.pop('XDG_CONFIG_HOME', None)
    env['HOME'] = str(root)
    config = root / '.config'
    config.mkdir()
    (config / 'hypr').mkdir()
    (config / 'settings.json').write_text('private contents must not be returned')
    (config / 'linked').symlink_to(config / 'hypr', target_is_directory=True)
    process = start(env)
    try:
        discovered = request('/api/dotfiles')
        assert discovered['available'] and discovered['path'] == str(config)
        assert discovered['entries'] == ['hypr', 'linked', 'settings.json'], discovered
        assert not discovered['git_available'] and discovered['error_message'] is None
    finally:
        stop(process)
    custom = root / 'xdg-config'
    custom.mkdir()
    (custom / 'kitty').mkdir()
    env['XDG_CONFIG_HOME'] = str(custom)
    process = start(env)
    try:
        discovered = request('/api/dotfiles')
        assert discovered['path'] == str(custom) and discovered['entries'] == ['kitty']
    finally:
        stop(process)
print('PASS: live Linux values, config discovery without Git, XDG override, Git metadata, and reload validation.')
