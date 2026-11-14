"""Verify the locked sandbox in the actual command process before releasing it."""
from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys


sys.path.insert(0, str(Path(__file__).resolve().parent))
import i18n

BWRAP = '/usr/bin/bwrap'
PROBE = '/run/capbox-agent-probe'
CAP_SYS_ADMIN = 1 << 21
PEER_CREDENTIALS = struct.Struct('3i')
PROBE_FAILURES = {
    b'procfs_read_only', b'procfs_submount', b'rootfs_read_only', b'workspace_read_only',
    b'capabilities', b'guest_identity', b'file_descriptors',
}


class LaunchError(Exception):
    """Fixed, machine-readable launch check name."""


def require(condition, check):
    if not condition:
        raise LaunchError(check)


def record(fd, phase, **fields):
    data = (json.dumps({'phase': phase, **fields}, separators=(',', ':')) + '\n').encode()
    if os.write(fd, data) != len(data):
        raise OSError('launch status write')


def host_evidence(pid, uid, gid):
    require(uid == os.getuid() and gid == os.getgid() and uid != 0, 'peer_identity')
    proc = Path(f'/proc/{pid}')
    for kind, outside in (('uid', uid), ('gid', gid)):
        mapped = (proc / f'{kind}_map').read_text().split()
        require(mapped == ['0', str(outside), '1'], f'{kind}_map')
    for ns in ('pid', 'net', 'user', 'mnt', 'ipc', 'uts'):
        try:
            actual = (proc / 'ns' / ns).readlink()
            host = (Path('/proc/self/ns') / ns).readlink()
        except OSError as exc:
            raise LaunchError(f'{ns}_namespace') from exc
        require(actual != host, f'{ns}_namespace')

    def status(path):
        return dict(line.split(':', 1) for line in path.read_text().splitlines() if ':' in line)

    process = status(proc / 'status')
    host = status(Path('/proc/self/status'))
    require(process.get('NoNewPrivs', '').strip() == '1', 'no_new_privileges')
    require(process.get('Seccomp', '').strip() == '2'
            and int(process.get('Seccomp_filters', '0')) > int(host.get('Seccomp_filters', '0')),
            'seccomp')
    require(not any(int(process.get(key, f'{CAP_SYS_ADMIN:x}'), 16) & CAP_SYS_ADMIN
                    for key in ('CapEff', 'CapPrm', 'CapBnd')), 'capabilities')


def prepare(argv, status_fd, helper, rootfs, workspace, probe_fd):
    try:
        bwrap = argv.index(BWRAP)
        split = argv.index('--', bwrap + 1)
    except ValueError as exc:
        raise LaunchError('final_argv') from exc

    # Reject all unrecognised or variable-length bwrap options, including argument
    # files, PID/user namespace FDs, network opts, capability resets and overlays.
    arity = {
        '--assert-userns-disabled': 0, '--cap-add': 1, '--cap-drop': 1,
        '--chdir': 1, '--clearenv': 0, '--dev': 1, '--die-with-parent': 0,
        '--disable-userns': 0, '--gid': 1, '--hostname': 1,
        '--json-status-fd': 1, '--proc': 1, '--remount-ro': 1,
        '--ro-bind': 2, '--bind': 2, '--seccomp': 1, '--setenv': 2,
        '--tmpfs': 1, '--uid': 1, '--unshare-ipc': 0, '--unshare-net': 0,
        '--unshare-pid': 0, '--unshare-user': 0, '--unshare-uts': 0,
    }
    options = {}
    i = bwrap + 1
    while i < split:
        arg = argv[i]
        n = arity.get(arg)
        require(n is not None and i + n < split, 'final_argv')
        options.setdefault(arg, []).append(tuple(argv[i + 1:i + n + 1]))
        i += n + 1

    for kind, value in {
        '--assert-userns-disabled': (), '--clearenv': (), '--die-with-parent': (),
        '--uid': ('0',), '--gid': ('0',), '--unshare-pid': (), '--unshare-user': (),
        '--unshare-ipc': (), '--unshare-uts': (), '--unshare-net': (),
        '--cap-add': ('ALL',), '--proc': ('/proc',), '--dev': ('/dev',),
        '--json-status-fd': (str(status_fd),),
    }.items():
        require(options.get(kind) == [value], 'final_argv')
    require(options.get('--disable-userns') and ('CAP_SYS_ADMIN',) in options.get('--cap-drop', []),
            'final_argv')
    require(('/proc',) in options.get('--remount-ro', []), 'final_argv')
    require(options.get('--ro-bind', []).count((rootfs, '/')) == 1, 'final_mounts')

    # Only the known built-in RO bind destinations may live outside the workspace.
    workspace_path = Path(workspace)
    workspace_readonly = os.environ.get('CAPBOX_TASK_WORKSPACE_READONLY') == '1'
    writable = set()
    if workspace_readonly:
        for relative in os.environ.get('CAPBOX_TASK_WRITE_DIRS', '').split('\n'):
            if not relative:
                continue
            require(all(p not in ('', '.', '..', '.capbox') for p in relative.split('/')),
                    'final_mounts')
            source = workspace_path / relative
            require(source.is_dir() and source.resolve() == source, 'final_mounts')
            writable.add((str(source), '/workspace/' + relative))
    else:
        writable.add((workspace, '/workspace'))
    binds = options.get('--bind', [])
    require(set(binds) == writable and len(binds) == len(writable), 'final_mounts')

    def exact_workspace_source(source, dest):
        if dest == '/workspace':
            return source == workspace
        rel = dest.removeprefix('/workspace/')
        return (all(p not in ('', '.', '..') for p in rel.split('/'))
                and source == str(workspace_path / rel)
                and Path(source).resolve() == Path(source))

    if workspace_readonly:
        require((workspace, '/workspace') in options.get('--ro-bind', []), 'final_mounts')
    landlock_paths = {'/run/capbox-landlock', '/run/capbox-landlock.rules'}
    for source, dest in options.get('--ro-bind', []):
        if dest in landlock_paths:
            landlock_paths.remove(dest)
        elif dest == '/workspace' or dest.startswith('/workspace/'):
            require(exact_workspace_source(source, dest)
                    or (source == '/dev/null' and dest.startswith('/workspace/')), 'final_mounts')
        else:
            require((source, dest) == (rootfs, '/'), 'final_mounts')
    require(not landlock_paths, 'landlock')
    for (dest,) in options.get('--tmpfs', []):
        require(dest in {'/tmp', '/run'} or dest.startswith('/workspace/'), 'final_mounts')
    require(('/run',) in options.get('--tmpfs', []), 'final_mounts')

    seccomp = options.get('--seccomp', [])
    require(len(seccomp) == 1 and seccomp[0][0].isdigit(), 'seccomp')
    guest = argv[split + 1:]
    require(guest[:4] == ['/run/capbox-landlock', '--rules', '/run/capbox-landlock.rules', '--']
            and len(guest) > 4, 'landlock')
    argv = [*argv[:split], '--ro-bind', helper, PROBE,
            '--setenv', 'CAPBOX_AGENT_WORKSPACE_READONLY', str(int(workspace_readonly)), '--',
            *guest[:4], PROBE, str(probe_fd), *guest[4:]]
    return argv, int(seccomp[0][0])


def launch(status_fd, helper, rootfs, workspace, argv):
    host, guest = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    with host, guest:
        host.setsockopt(socket.SOL_SOCKET, socket.SO_PASSCRED, 1)
        host.settimeout(30)
        argv, seccomp_fd = prepare(argv, status_fd, helper, rootfs, workspace, guest.fileno())
        with subprocess.Popen(argv, pass_fds=(status_fd, seccomp_fd, guest.fileno())) as proc:
            guest.close()
            try:
                data, ancillary, flags, _address = host.recvmsg(
                    64, socket.CMSG_SPACE(PEER_CREDENTIALS.size))
                require(data, 'bubblewrap_or_landlock_setup')
                if data in PROBE_FAILURES:
                    raise LaunchError(data.decode('ascii'))
                require(data == b'ready' and flags == 0 and len(ancillary) == 1, 'probe_protocol')
                level, kind, value = ancillary[0]
                require(level == socket.SOL_SOCKET and kind == socket.SCM_CREDENTIALS
                        and len(value) == PEER_CREDENTIALS.size, 'probe_protocol')
                pid, uid, gid = PEER_CREDENTIALS.unpack(value)
                require(pid > 0, 'peer_identity')
                host_evidence(pid, uid, gid)
                record(status_fd, 'protection_verified', checks={
                    'profile': 'strict', 'uid_map': 'single', 'gid_map': 'single',
                    'network': 'none', 'pid_namespace': 'private', 'procfs': 'read-only',
                    'rootfs': 'read-only', 'landlock': 'on', 'seccomp': 'on',
                    'workspace': ('read-only' if os.environ.get('CAPBOX_TASK_WORKSPACE_READONLY') == '1'
                                  else 'writable'),
                })
                host.sendall(b'1')
            finally:
                # EOF causes the gate to exit even when verification raises.
                host.close()
            code = proc.wait()
    return code if code >= 0 else 128 - code


def main():
    status_fd = int(sys.argv[1])
    try:
        return launch(status_fd, *sys.argv[2:5], sys.argv[5:])
    except (OSError, ValueError, LaunchError) as exc:
        check = str(exc) if isinstance(exc, LaunchError) else 'verification_unavailable'
        record(status_fd, 'protection_failed', check=check)
        print(i18n.t('launch.agent_protection_failed', check=check), file=sys.stderr)
        return 5


if __name__ == '__main__':
    raise SystemExit(main())
