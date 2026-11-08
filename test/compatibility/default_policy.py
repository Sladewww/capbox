#!/usr/bin/env python3
"""Probe the default host policy without changing sysctls or unloading AppArmor."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='capbox-default-policy-') as temporary:
    workspace = Path(temporary) / 'workspace'
    workspace.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith('CAPBOX_')}
    cli = [str(REPO / 'bin/capbox'), '--root', str(workspace)]
    init = subprocess.run(cli + ['init', '--agent', '--distro', 'alpine'], env=env,
                          capture_output=True, text=True, timeout=900)
    print(init.stdout, init.stderr)
    init.check_returncode()
    bwrap = subprocess.run(['bwrap', '--unshare-user', '--uid', '0', '--gid', '0',
                            '--ro-bind', '/', '/', '--', '/bin/true'],
                           capture_output=True, text=True, timeout=30)
    execution = subprocess.run(cli + ['exec', '--', 'true'], env=env,
                               capture_output=True, text=True, timeout=60)
    print(execution.stdout, execution.stderr)
    assert 'Traceback' not in execution.stderr, execution.stderr
    if bwrap.returncode == 0:
        execution.check_returncode()
        result = 'execution-passed'
    else:
        assert execution.returncode != 0, 'host refuses namespaces but CapBox reported success'
        assert any(word in execution.stderr.lower() for word in
                   ['permission', 'permitted', 'userns', 'namespace', '命名空间', '权限']), execution.stderr
        result = 'host-refusal-reported'
    summary = {'host': os.uname().release, 'policy_result': result,
               'bwrap_exit': bwrap.returncode, 'capbox_exit': execution.returncode}
    print(json.dumps(summary))
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as f:
            f.write('Default host policy: `' + json.dumps(summary) + '`\n')
