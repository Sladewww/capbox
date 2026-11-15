"""Host-owned cgroup v2 lifecycle for locked Agent tasks."""
import os
from pathlib import Path
import re
import time

MOUNT = Path('/sys/fs/cgroup')
DEFAULTS = {'CPU_MAX': '100%', 'MEMORY_MAX': '512Mi', 'PIDS_MAX': '128', 'SWAP_MAX': ''}
FILES = {'CPU_MAX': 'cpu.max', 'MEMORY_MAX': 'memory.max', 'PIDS_MAX': 'pids.max',
         'SWAP_MAX': 'memory.swap.max'}
PAGE_SIZE = os.sysconf('SC_PAGE_SIZE')


def host_request():
    return {key: os.environ.get('CAPBOX_TASK_HOST_' + key, default)
            for key, default in DEFAULTS.items()}


def limits(request):
    cpu = re.fullmatch(r'([0-9]{1,5})%|([0-9]{1,12}) ([0-9]{1,6})', request['CPU_MAX'])
    pids = re.fullmatch(r'[0-9]{1,10}', request['PIDS_MAX'])
    if not cpu or not pids or not 0 < int(pids[0]) <= 2147483647:
        raise ValueError('cpu.max or pids.max')
    quota, period = ((int(cpu[1]) * 1000, 100000) if cpu[1] else
                     (int(cpu[2]), int(cpu[3])))
    if quota < 1000 or not 1000 <= period <= 1000000:
        raise ValueError('cpu.max')
    result = {'cpu.max': f'{quota} {period}', 'pids.max': str(int(pids[0]))}
    for key in ('MEMORY_MAX', 'SWAP_MAX'):
        raw = request[key]
        if key == 'SWAP_MAX' and not raw:
            continue
        match = re.fullmatch(r'([0-9]{1,16})([kmg]i?b?)?', raw, re.IGNORECASE)
        if not match:
            raise ValueError(FILES[key])
        unit = (match[2] or '').lower().removesuffix('b')
        power = {'': 0, 'k': 1, 'm': 2, 'g': 3}[unit[:1]]
        number = int(match[1]) * (1024 if unit.endswith('i') else 1000) ** power
        if number >= 2**63 or (number < PAGE_SIZE and key == 'MEMORY_MAX'):
            raise ValueError(FILES[key])
        result[FILES[key]] = str(number // PAGE_SIZE * PAGE_SIZE)
    return result


def membership(pid):
    with Path(f'/proc/{pid}/cgroup').open() as stream:
        for line in stream:
            if line.startswith('0::'):
                return line[3:].rstrip('\n')
    raise OSError('unified process membership unavailable')


def cgroup_parent():
    override = os.environ.get('CAPBOX_TASK_HOST_CGROUP_ROOT')
    parent = (Path(override) if override else
              (MOUNT / membership('self').lstrip('/')).parent).resolve()
    unified_mount = any(line.split()[4] == str(MOUNT) and ' - cgroup2 ' in line
                        for line in Path('/proc/self/mountinfo').read_text().splitlines())
    if (not unified_mount or not parent.is_relative_to(MOUNT)
            or not (parent / 'cgroup.controllers').is_file()):
        raise OSError('delegated cgroup v2 parent unavailable')
    return parent


def configure(parent, task_id):
    enabled = (parent / 'cgroup.subtree_control').read_text().split()
    if not {'cpu', 'memory', 'pids'}.issubset(enabled):
        raise OSError('cpu, memory and pids must be enabled in delegated parent')
    leaf = parent / ('capbox-task-' + task_id)
    leaf.mkdir()
    return leaf


def write_limits(leaf, expected):
    for name, value in expected.items():
        fd = os.open(leaf / name, os.O_WRONLY)
        with os.fdopen(fd, 'w') as control:
            control.write(value + '\n')
    actual = read_limits(leaf, expected)
    if actual != expected:
        raise OSError('kernel slot readback differs from request')
    # Open the real control before launching, so failure to clean up is a startup error.
    os.close(os.open(leaf / 'cgroup.kill', os.O_WRONLY))
    return actual


def read_limits(leaf, expected):
    return {name: (leaf / name).read_text().strip() for name in expected}


def verify(leaf, pid, expected):
    path = membership(pid)
    if (pid not in {int(item) for item in (leaf / 'cgroup.procs').read_text().split()}
            or path != '/' + str(leaf.relative_to(MOUNT))
            or read_limits(leaf, expected) != expected):
        raise OSError('task cgroup membership or limits could not be verified')
    return path


def join(leaf, expected):
    pid = os.getpid()
    (leaf / 'cgroup.procs').write_text(f'{pid}\n')
    return verify(leaf, pid, expected)


def kill(leaf):
    (leaf / 'cgroup.kill').write_text('1\n')


def cleanup(leaf):
    if not leaf.exists():
        return 'removed'
    try:
        events = leaf / 'cgroup.events'
        if 'populated 0' not in events.read_text().splitlines():
            kill(leaf)
        deadline = time.monotonic() + 3
        while 'populated 0' not in events.read_text().splitlines():
            if time.monotonic() >= deadline:
                return 'populated'
            time.sleep(0.05)
        leaf.rmdir()
        return 'removed'
    except OSError:
        return 'incomplete'
