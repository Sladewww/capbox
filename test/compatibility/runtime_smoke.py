#!/usr/bin/env python3
"""No skips: run the supported guest/architecture and a delegated multi-UID path."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--require-multi', action='store_true')
args = parser.parse_args()
distro = os.environ.get('CAPBOX_SMOKE_DISTRO', 'alpine')
env = {k: v for k, v in os.environ.items() if not k.startswith('CAPBOX_')}
env['CAPBOX_LANG'] = 'zh'
with tempfile.TemporaryDirectory(prefix='capbox-compat-') as temporary:
    workspace = Path(temporary) / 'workspace'
    workspace.mkdir()
    cli = [str(REPO / 'bin/capbox'), '--root', str(workspace)]

    def run(*command):
        result = subprocess.run(cli + list(command), env=env, text=True,
                                capture_output=True, timeout=900)
        print('$ capbox', *command, flush=True)
        print(result.stdout, end='', flush=True)
        print(result.stderr, end='', flush=True)
        result.check_returncode()
        return result.stdout.strip()

    run('init', '--distro', distro, '--trusted' if args.require_multi else '--agent')
    if args.require_multi:
        run('config', 'set', 'IDMAP', 'on')
        run('config', 'set', 'NET', 'none')
        doctor = run('doctor')
        assert 'UID 映射 multi' in doctor, doctor
        identity = run('exec', '--uid', '33', '--gid', '33', '--', 'id')
        assert 'uid=33' in identity and 'gid=33' in identity, identity
        run('exec', '--', 'sh', '-eu', '-c',
            'touch /tmp/mapped; chown 33:33 /tmp/mapped; test "$(stat -c %u /tmp/mapped)" = 33')
    else:
        assert run('config', 'get', 'SECURITY_PROFILE') == 'untrusted'
        assert run('config', 'get', 'IDMAP') == 'off'
        assert run('config', 'get', 'RESOURCES_MODE') == 'require'
        assert run('exec', '--', 'id', '-u') == '0'
        run('exec', '--profile', 'strict', '--', 'true')
        guest_ns = run('exec', '--', 'readlink', '/proc/self/ns/net')
        assert guest_ns != os.readlink('/proc/self/ns/net'), guest_ns
        run('image', 'lock', 'save')
        run('image', 'lock', 'verify')
    task = json.loads(run('task', 'start', '--timeout', '15', '--', 'sh', '-c', 'printf agent-task'))['task_id']
    try:
        assert json.loads(run('task', 'wait', task, '--timeout', '20'))['status'] == 'succeeded'
        assert run('task', 'logs', task) == 'agent-task'
        assert json.loads(run('policy', 'show'))['values']['NET']['value'] == 'none'
    finally:
        run('task', 'cancel', task)
        run('task', 'rm', task)
    service = workspace / '.capbox/services/smoke.env'
    service.write_text('CMD=sleep 60\nNET=none\n' +
                       ('UID=33\nGID=33\nREQUIRE_IDMAP=1\n' if args.require_multi else ''))
    try:
        run('service', 'start', 'smoke')
        assert 'state=running' in run('service', 'status', 'smoke')
    finally:
        run('service', 'stop', 'smoke')
    summary = {'distro': distro, 'architecture': os.uname().machine,
               'multi_uid': args.require_multi, 'status': 'passed'}
    print(json.dumps(summary))
