#!/usr/bin/env python3
"""Local task lifecycle, policy explanations and reviewable workspace copies.

Only exec launches guest commands. This host controller treats task output and
workspace contents as data, and never executes scripts supplied by the guest.
"""
import argparse
import base64
import ctypes
import fcntl
import fnmatch
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import selectors
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid
from urllib.parse import urlsplit

SCHEMA = 'capbox.agent.v1'
FINISHED = {'succeeded', 'failed', 'cancelled', 'timed_out'}
TERMINAL = FINISHED | {'lost'}
MAX_STREAM = 8 * 1024 * 1024
MAX_FILES = 10000
MAX_COPY = 100 * 1024 * 1024
EXCLUDED = {'.git', '.capbox', '.env', '.secrets', '.ssh', '.aws', '.azure',
            '.gnupg', '.kube', '.docker'}


class AgentError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def emit(value):
    print(json.dumps(dict(schema=SCHEMA, **value), ensure_ascii=True), flush=True)


def private_dir(path, create=False):
    path = Path(path).absolute()
    if create:
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            pass
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        raise AgentError('宿主任务目录必须由当前用户拥有、权限 0700 且不是符号链接')
    if path.resolve() != path:
        raise AgentError('宿主任务目录不能经过符号链接')
    return path


def read_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise AgentError('任务记录必须是普通文件')
        return json.load(f)


def write_json(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(value, f, ensure_ascii=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temporary, path)


def identity(pid):
    try:
        fields = Path('/proc/%d/stat' % pid).read_text().rsplit(') ', 1)[1].split()
        if fields[0] == 'Z':
            return None
        return {'pid': pid, 'start': fields[19],
                'pidns': os.readlink('/proc/%d/ns/pid' % pid),
                'boot': Path('/proc/sys/kernel/random/boot_id').read_text().strip()}
    except (OSError, IndexError, ValueError):
        return None


def alive(record):
    return bool(record and identity(record['pid']) == record)


def context():
    env = os.environ
    cfg = {k.removeprefix('CAPBOX_AGENT_CFG_'): v for k, v in env.items()
           if k.startswith('CAPBOX_AGENT_CFG_')}
    sources = {k.removeprefix('CAPBOX_AGENT_SOURCE_'): v for k, v in env.items()
               if k.startswith('CAPBOX_AGENT_SOURCE_')}
    return {'workspace': str(Path(env['CAPBOX_AGENT_WORKSPACE']).resolve()),
            'rootfs': env['CAPBOX_AGENT_ROOTFS'], 'cli': env['CAPBOX_AGENT_CLI'],
            'lib': env['CAPBOX_AGENT_LIB'], 'config': cfg, 'sources': sources,
            'allow_once': env.get('CAPBOX_AGENT_ALLOW_ONCE') == '1'}


def effective(ctx, args):
    cfg, sources = ctx['config'].copy(), ctx['sources'].copy()
    for key in ('NET', 'SECURITY_PROFILE'):
        attr = 'net' if key == 'NET' else 'profile'
        value = getattr(args, attr, None)
        if value is not None:
            cfg[key], sources[key] = value, 'command'
    if cfg.get('NET') == 'host':
        cfg['NET'] = 'open'
    profile = cfg.get('SECURITY_PROFILE', 'compat')
    ro = cfg.get('ROOTFS_RO', '0')
    if profile == 'strict' and sources.get('ROOTFS_RO', 'default') == 'default':
        ro = '1'
    fields = ['SECURITY_PROFILE', 'NET', 'NET_ALLOW', 'IDMAP', 'EXEC_UID', 'EXEC_GID',
              'MEMORY_MAX', 'CPU_MAX', 'PIDS_MAX', 'DISK_MAX', 'RESOURCES_MODE',
              'FS_HIDE', 'FS_BINDS', 'OVERLAY']
    values = {k: {'value': cfg.get(k, ''), 'source': sources.get(k, 'default')} for k in fields}
    values['ROOTFS_RO'] = {'value': ro, 'source': 'profile' if ro != cfg.get('ROOTFS_RO') else sources.get('ROOTFS_RO', 'default')}
    values['LANDLOCK'] = {'value': cfg.get('LANDLOCK') or ('on' if profile == 'strict' else 'off'),
                          'source': sources.get('LANDLOCK', 'default') if cfg.get('LANDLOCK') else 'profile'}
    return {'kind': 'policy', 'values': values,
            'scope': 'new oneshot launch; not an existing daemon',
            'limits': 'requested, verified by the exec launcher at startup',
            'notes': ['pkg install/update temporarily use network when NET=none',
                      'IDMAP auto/on may alter the nested-userns restriction; see doctor',
                      'rootfs RO may have an overlay; /workspace is writable by default']}


def net_module(ctx):
    spec = importlib.util.spec_from_file_location('capbox_net_policy', Path(ctx['lib']) / 'net-proxy.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def network_check(ctx, args):
    target = urlsplit(args.target)
    if target.scheme not in ('http', 'https') or not target.hostname or target.username or target.password:
        raise AgentError('只接受不含凭据的 http:// 或 https:// URL', 2)
    try:
        host, port = target.hostname, target.port or (443 if target.scheme == 'https' else 80)
    except ValueError as exc:
        raise AgentError('URL 端口无效', 2) from exc
    policy = effective(ctx, args)
    mode = policy['values']['NET']['value']
    result = {'kind': 'network_decision', 'host': host, 'port': port, 'mode': mode,
              'decision': 'deny', 'reason': 'network_none', 'connectivity_tested': False}
    if mode == 'open':
        result.update(decision='allow', reason='shared_host_network')
    elif mode == 'restricted':
        module = net_module(ctx)
        rules = module.parse_allowlist(ctx['config'].get('NET_ALLOW', ''))
        matches = [rule for rule in rules if module.host_allowed(host, [rule], port)]
        result.update(matched_rules=matches, reason='no_matching_host_port_rule')
        if matches:
            result.update(decision='conditional', reason='allowlist_match_dns_unchecked')
            if args.resolve:
                try:
                    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
                    addresses = sorted({item[4][0].split('%', 1)[0] for item in infos})
                    allowed = [ip for ip in addresses
                               if not module._ip_forbidden(module.ipaddress.ip_address(ip))
                               or module.host_allowed(ip, rules, port)]
                    result.update(addresses=addresses, allowed_addresses=allowed,
                                  decision='allow' if allowed else 'deny',
                                  reason='resolved_address_allowed' if allowed else 'resolved_addresses_blocked')
                except socket.gaierror:
                    result.update(decision='deny', reason='dns_resolution_failed')
    result['policy_source'] = policy['values']['NET']['source']
    result['notes'] = 'Policy preview only. DNS can change; the proxy rechecks at connection time. No TCP connection made.'
    return result


def clean_environment(ctx):
    # Keep the launch prerequisites, not host API keys, SSH agents or Git config.
    env = {k: os.environ[k] for k in ('PATH', 'HOME', 'LANG', 'TERM', 'XDG_RUNTIME_DIR', 'XDG_STATE_HOME') if k in os.environ}
    for k, value in ctx['config'].items():
        if k == 'ALLOW_OLD_BWRAP' or (k == 'ROOTFS_RO' and ctx['sources'].get(k, 'default') == 'default'):
            continue
        env['CAPBOX_' + k] = value
    # Explicit cgroup delegation is outside config.env in the existing launcher.
    if 'CAPBOX_CGROUP_ROOT' in os.environ:
        env['CAPBOX_CGROUP_ROOT'] = os.environ['CAPBOX_CGROUP_ROOT']
    return env


def safe_relative(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or any(p in ('', '.', '..') for p in name.split('/')):
        raise AgentError('工作副本文件路径无效')
    return path


def excluded(name):
    return any(part in EXCLUDED or part.startswith('.env.') or fnmatch.fnmatch(part, '*.pem')
               or fnmatch.fnmatch(part, '*.key') or part.startswith('id_rsa')
               for part in PurePosixPath(name).parts)


def read_regular(root, name):
    """Open every component relative to a pinned directory, never through links."""
    parts = safe_relative(name).parts
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, 'rb') as f:
            before = os.fstat(f.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                raise AgentError('只支持普通、非硬链接文件: ' + name)
            if before.st_size > MAX_COPY:
                raise AgentError('文件超过工作副本大小限制: ' + name)
            data = f.read(MAX_COPY + 1)
            after = os.fstat(f.fileno())
            signature = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            if len(data) > MAX_COPY or signature(before) != signature(after):
                raise AgentError('读取期间文件变化，请停止写入后重试: ' + name)
            return data, before
    finally:
        os.close(directory)


def regular_files(root):
    result, total = {}, 0
    for directory, dirs, files in os.walk(root, followlinks=False):
        relative = Path(directory).relative_to(root)
        dirs[:] = [d for d in dirs if not excluded((relative / d).as_posix())]
        for name in dirs + files:
            path = Path(directory) / name
            rel = path.relative_to(root).as_posix()
            if excluded(rel):
                continue
            st = path.lstat()
            if stat.S_ISDIR(st.st_mode):
                continue
            if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                raise AgentError('隔离副本只支持普通文件，不接受符号链接、硬链接或特殊文件: ' + rel)
            total += st.st_size
            if total > MAX_COPY or len(result) >= MAX_FILES:
                raise AgentError('工作副本超过 100MiB / 10000 文件的首版限制')
            data, st = read_regular(root, rel)
            result[rel] = {'sha256': hashlib.sha256(data).hexdigest(),
                           'executable': bool(st.st_mode & 0o111)}
    return result


def git(ctx, args, *, work=None, index=None, data=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith(('GIT_', 'CAPBOX_'))}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_ATTR_NOSYSTEM='1',
               GIT_TERMINAL_PROMPT='0', GIT_OPTIONAL_LOCKS='0')
    cmd = ['git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
           '-c', 'core.attributesFile=/dev/null', '-c', 'core.quotePath=true']
    if index:
        cmd += ['--git-dir=' + str(index), '--work-tree=' + str(work)]
    elif work:
        cmd += ['-C', str(work)]
    proc = subprocess.run(cmd + args, input=data, env=env, capture_output=True, timeout=30)
    if proc.returncode:
        raise AgentError('Git 工作副本操作失败（请确认项目是仓库根目录）')
    return proc.stdout


def is_git_workspace_root(ctx, source):
    try:
        top = Path(git(ctx, ['rev-parse', '--show-toplevel'], work=source).decode().strip()).resolve()
    except AgentError:
        return False
    return top == source.resolve()


def list_isolate_names(ctx, source):
    """Return relative paths for the isolate view: dirty Git tree or filesystem walk."""
    if is_git_workspace_root(ctx, source):
        # Tracked working-tree files plus untracked, still honoring .gitignore.
        # CapBox credential exclusions still win after this listing.
        raw = git(ctx, ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], work=source)
        names = []
        for item in raw.split(b'\0'):
            if not item:
                continue
            names.append(item.decode('utf-8', 'strict'))
        return sorted(set(names)), 'git'
    if not source.is_dir() or source.is_symlink():
        raise AgentError('--isolate 既不是可读的 Git 仓库根目录，也无法遍历工作区目录', 2)
    names = []
    for directory, dirs, files in os.walk(source, followlinks=False):
        relative = Path(directory).relative_to(source)
        dirs[:] = [d for d in dirs if not excluded((relative / d).as_posix())]
        for name in files:
            rel = (relative / name).as_posix() if str(relative) != '.' else name
            if excluded(rel):
                continue
            names.append(rel)
    if not names and not any(source.iterdir()):
        # Empty project is still a valid synthetic baseline.
        return [], 'fs'
    return sorted(set(names)), 'fs'


def is_overlay_whiteout(path):
    try:
        st = path.lstat()
    except OSError:
        return False
    if stat.S_ISCHR(st.st_mode) and os.major(st.st_rdev) == 0 and os.minor(st.st_rdev) == 0:
        return True
    return path.name.startswith('.wh.') and path.name != '.wh..wh..opq'


def merge_overlay_upper(upper, dest_rootfs):
    """Apply overlay upper onto an independent rootfs copy (copy-up + whiteouts)."""
    if upper.is_symlink() or not upper.is_dir():
        raise AgentError('--isolate 拒绝不安全的 overlay upper（符号链接或非目录）')
    for directory, dirs, files in os.walk(upper, followlinks=False, topdown=True):
        rel_dir = Path(directory).relative_to(upper)
        # Opaque directory marker used by some overlay implementations.
        opaque = Path(directory) / '.wh..wh..opq'
        if opaque.exists() or opaque.is_symlink():
            target_dir = dest_rootfs / rel_dir if str(rel_dir) != '.' else dest_rootfs
            if target_dir.exists():
                for child in list(target_dir.iterdir()):
                    if child.is_dir() and not child.is_symlink():
                        shutil.rmtree(child)
                    else:
                        child.unlink(missing_ok=True)
        for name in list(dirs) + list(files):
            src = Path(directory) / name
            rel = (rel_dir / name).as_posix() if str(rel_dir) != '.' else name
            if src.is_symlink():
                raise AgentError('--isolate overlay upper 含符号链接，已拒绝: ' + rel)
            if name == '.wh..wh..opq':
                continue
            if name.startswith('.wh.'):
                target_name = name[4:]
                target = dest_rootfs / rel_dir / target_name if str(rel_dir) != '.' else dest_rootfs / target_name
                if target.is_dir() and not target.is_symlink():
                    shutil.rmtree(target)
                elif target.exists() or target.is_symlink():
                    target.unlink()
                continue
            if is_overlay_whiteout(src):
                target = dest_rootfs / rel
                if target.is_dir() and not target.is_symlink():
                    shutil.rmtree(target)
                elif target.exists() or target.is_symlink():
                    target.unlink()
                continue
            st = src.lstat()
            dst = dest_rootfs / rel
            if stat.S_ISDIR(st.st_mode):
                dst.mkdir(parents=True, exist_ok=True)
                continue
            if not stat.S_ISREG(st.st_mode):
                raise AgentError('--isolate overlay upper 含不支持的特殊文件: ' + rel)
            dst.parent.mkdir(parents=True, exist_ok=True)
            if dst.exists() or dst.is_symlink():
                if dst.is_dir() and not dst.is_symlink():
                    shutil.rmtree(dst)
                else:
                    dst.unlink()
            shutil.copy2(src, dst)


def isolate(ctx, job):
    source = Path(ctx['workspace']).resolve()
    if not source.is_dir() or source.is_symlink():
        raise AgentError('--isolate 需要可读的工作区目录', 2)
    upper = Path(ctx['rootfs']).resolve().parent.parent / 'run/overlay/active/upper'
    if upper.exists() and upper.is_symlink():
        raise AgentError('--isolate 拒绝符号链接形式的 overlay upper')
    try:
        names, mode = list_isolate_names(ctx, source)
    except AgentError:
        raise
    except OSError as exc:
        raise AgentError('--isolate 无法枚举工作区文件') from exc
    view = job / 'workspace'
    view.mkdir(mode=0o755)  # enclosing job stays 0700; mapped non-root users can read the view
    baseline, skipped, total = {}, [], 0
    for name in names:
        relative = safe_relative(name)
        if excluded(name):
            skipped.append(name)
            continue
        src = source / relative
        if not src.exists() and not src.is_symlink():
            continue  # preserve a working-tree deletion of a tracked path
        try:
            data, st = read_regular(source, name)
        except OSError as exc:
            raise AgentError('源工作区包含符号链接或路径不可安全读取: ' + name) from exc
        total += st.st_size
        if total > MAX_COPY or len(baseline) >= MAX_FILES:
            raise AgentError('工作副本超过 100MiB / 10000 文件限制')
        dst = view / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        with dst.open('xb') as outgoing:
            outgoing.write(data)
        dst.chmod(0o755 if st.st_mode & 0o111 else 0o644)
        baseline[name] = {'sha256': hashlib.sha256(data).hexdigest(),
                          'executable': bool(st.st_mode & 0o111)}
    # Review metadata is outside the guest view. Never run Git using guest .git/config.
    # Non-Git and dirty Git both get a synthetic baseline so task diff keeps working.
    index = job / 'review.git'
    git(ctx, ['init', '--bare', str(index)])
    git(ctx, ['add', '--force', '--all', '--', '.'], work=view, index=index)
    write_json(job / 'baseline.json', baseline)
    write_json(job / 'isolate-meta.json', {'mode': mode,
                                           'overlay_merged': bool(upper.exists() and any(upper.iterdir()))})
    state = view / '.capbox'
    state.mkdir()
    (state / 'bin').mkdir()
    shutil.copy2(ctx['cli'], state / 'bin/capbox')
    shutil.copytree(ctx['lib'], state / 'lib', symlinks=False)
    (state / 'os').mkdir()
    # Private independent rootfs: no hardlinks to the live mutable image / upper.
    dest_rootfs = state / 'os' / ctx['config']['DISTRO']
    shutil.copytree(ctx['rootfs'], dest_rootfs, symlinks=True)
    if upper.exists() and upper.is_dir() and any(upper.iterdir()):
        merge_overlay_upper(upper, dest_rootfs)
    ctx = dict(ctx, workspace=str(view), rootfs=str(dest_rootfs))
    return ctx, skipped


def job_path(root, name):
    if not re.fullmatch(r'[0-9a-f]{32}', name):
        raise AgentError('无效 task ID', 2)
    try:
        return private_dir(root / name)
    except FileNotFoundError as exc:
        raise AgentError('找不到 task ID', 2) from exc


def state_of(job):
    state = read_json(job / 'state.json')
    if state['status'] not in TERMINAL and not alive(state.get('worker')):
        state = dict(state, status='lost', exit_code=125)
    return state


def public_state(job):
    result = state_of(job)
    result = {k: v for k, v in result.items() if k not in ('worker',)}
    result.update(output_bytes={s: (job / (s + '.log')).stat().st_size
                                if (job / (s + '.log')).exists() else 0
                                for s in ('stdout', 'stderr')})
    if result.get('status') == 'timed_out':
        result['hint'] = ('任务执行超时（timed_out / exit 124）。'
                          '查看 task logs，缩小命令，或提高 --timeout（MCP 受 --max-timeout 上限约束）。')
    elif result.get('status') == 'cancelled':
        result['hint'] = '任务已取消。可用 task logs 查看部分输出；需要时可重新 task start。'
    return result


def return_code(state):
    code = state.get('exit_code')
    return code if isinstance(code, int) and 0 <= code <= 255 else 125


def start_task(ctx, root, args):
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        raise AgentError('task start 缺少命令（用 -- 分隔）', 2)
    if not Path(ctx['rootfs']).is_dir():
        raise AgentError('rootfs 不存在，请先 init', 4)
    active = [d for d in root.iterdir() if d.is_dir() and not d.is_symlink()
              and re.fullmatch('[0-9a-f]{32}', d.name) and state_of(d)['status'] not in TERMINAL]
    if len(active) >= 8:
        raise AgentError('当前项目已有 8 个活动任务，请等待或取消后重试')
    task_id = uuid.uuid4().hex
    job = private_dir(root / task_id, create=True)
    state = {'task_id': task_id, 'status': 'preparing', 'created_at': time.time(),
             'exit_code': None, 'worker': identity(os.getpid()), 'isolated': args.isolate,
             'policy': effective(ctx, args), 'output_limit_per_stream': args.max_output_bytes}
    write_json(job / 'state.json', state)
    origin = ctx['workspace']
    launched = None
    try:
        skipped = []
        if args.isolate:
            ctx, skipped = isolate(ctx, job)
        env = clean_environment(ctx)
        env['CAPBOX_NET_SESSION'] = 'task-' + task_id
        argv = [ctx['cli'], '--root', ctx['workspace']]
        if ctx['allow_once']:
            argv += ['--allow-old-bwrap']
        # The controller owns the deadline. GNU timeout creates a separate process
        # group, which would otherwise escape cancellation of the CLI group.
        argv += ['exec', '--timeout', '0', '--cwd', args.cwd]
        if args.net:
            argv += ['--net', args.net]
        if args.profile:
            argv += ['--profile', args.profile]
        argv += ['--'] + command
        write_json(job / 'plan.json', {'argv': argv, 'env': env, 'timeout': args.timeout,
                                      'origin': origin, 'workspace': ctx['workspace'],
                                      'config': ctx['config'], 'sources': ctx['sources'],
                                      'skipped': skipped, 'max_output_bytes': args.max_output_bytes})
        # Worker lifetime is independent of this CLI. An outer supervisor can still
        # terminate the entire host session; state then becomes lost, never success.
        log = os.open(job / 'controller.log', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            worker = subprocess.Popen([sys.executable, '-I', str(Path(__file__).resolve()),
                                       '__worker', str(root), task_id],
                                      stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                      close_fds=True, start_new_session=True,
                                      env={k: os.environ[k] for k in ('PATH', 'HOME', 'LANG') if k in os.environ})
        finally:
            os.close(log)
        launched = worker
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            observed = read_json(job / 'state.json')
            if observed['status'] != 'preparing':
                emit(public_state(job))
                return 0
            if worker.poll() is not None:
                raise AgentError('任务监督器未启动；请查看私有 controller.log')
            time.sleep(0.02)
        raise AgentError('任务监督器启动超时')
    except BaseException:
        if launched is not None and launched.poll() is None:
            launched.kill()
            launched.wait()
        state.update(status='failed', exit_code=1, finished_at=time.time())
        write_json(job / 'state.json', state)
        raise


def pdeathsig(parent):
    # A dead controller must not leave its CLI/bwrap descendants running.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0 or os.getppid() != parent:
        os._exit(125)


def worker(root, task_id):
    job = job_path(root, task_id)
    lock = os.open(job / 'worker.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    state = read_json(job / 'state.json')
    if state['status'] != 'preparing':
        raise AgentError('任务已经提交给监督器')
    plan = read_json(job / 'plan.json')
    state.update(status='running', worker=identity(os.getpid()), started_at=time.time())
    write_json(job / 'state.json', state)
    proc, streams = None, {}
    dropped = {'stdout': 0, 'stderr': 0}
    reason, terminating_at = None, None
    start = time.monotonic()
    try:
        parent = os.getpid()
        proc = subprocess.Popen(plan['argv'], env=plan['env'], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True, close_fds=True,
                                preexec_fn=lambda: pdeathsig(parent))
        selector = selectors.DefaultSelector()
        for stream, pipe in (('stdout', proc.stdout), ('stderr', proc.stderr)):
            fd = os.open(job / (stream + '.log'), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            streams[stream] = [os.fdopen(fd, 'wb', buffering=0), 0]
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, stream)
        while selector.get_map() or proc.poll() is None:
            now = time.monotonic()
            if reason is None:
                if (job / 'cancel').exists():
                    reason = 'cancelled'
                elif plan['timeout'] and now - start >= plan['timeout']:
                    reason = 'timed_out'
                if reason:
                    terminating_at = now
                    try:
                        os.killpg(proc.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            if terminating_at and now - terminating_at > 1:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            for event, _mask in selector.select(0.05):
                data = os.read(event.fileobj.fileno(), 65536)
                if not data:
                    selector.unregister(event.fileobj)
                    event.fileobj.close()
                    continue
                stream = event.data
                output, size = streams[stream]
                keep = min(len(data), max(0, plan['max_output_bytes'] - size))
                output.write(data[:keep])
                streams[stream][1] += keep
                dropped[stream] += len(data) - keep
        code = proc.wait()
        code = 128 - code if code < 0 else code
        if reason == 'cancelled':
            code = 143
        elif reason == 'timed_out' or code == 124:
            reason, code = 'timed_out', 124
        state.update(status=reason or ('succeeded' if code == 0 else 'failed'), exit_code=code)
    except BaseException as exc:
        if proc is not None and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        state.update(status='failed', exit_code=125, error=type(exc).__name__)
    finally:
        for output, _size in streams.values():
            output.close()
        state.update(finished_at=time.time(), dropped_bytes=dropped)
        write_json(job / 'state.json', state)
        os.close(lock)
    return 0


def log_chunk(job, stream, offset, limit):
    path = job / (stream + '.log')
    data = b''
    size = 0
    if path.exists():
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as f:
            size = os.fstat(f.fileno()).st_size
            if offset > size:
                # Keep empty-read compatibility for clients that poll past EOF, but mark it.
                return {'task_id': job.name, 'stream': stream, 'offset': offset,
                        'next_offset': offset, 'data_base64': '',
                        'size': size, 'eof': True, 'cursor_past_eof': True,
                        'hint': '日志游标超出文件末尾（offset=%d, size=%d）；请用上一次的 next_offset，或从 0 重读'
                                % (offset, size)}
            f.seek(offset)
            data = f.read(limit)
    next_offset = offset + len(data)
    eof = next_offset >= size
    result = {'task_id': job.name, 'stream': stream, 'offset': offset,
              'next_offset': next_offset, 'data_base64': base64.b64encode(data).decode(),
              'size': size, 'eof': eof, 'cursor_past_eof': False}
    return result


def diff_task(ctx, job, as_json):
    state = state_of(job)
    if not state['isolated'] or state['status'] not in FINISHED:
        raise AgentError('diff 只支持已结束且非 lost 的隔离任务', 2)
    plan = read_json(job / 'plan.json')
    view, index = job / 'workspace', job / 'review.git'
    current = regular_files(view)
    baseline = read_json(job / 'baseline.json')
    new = sorted(set(current) - set(baseline))
    if new:
        payload = b''.join(name.encode() + b'\0' for name in new)
        git(ctx, ['add', '--intent-to-add', '--force', '--pathspec-from-file=-',
                  '--pathspec-file-nul'], work=view, index=index, data=payload)
    patch = git(ctx, ['diff', '--binary', '--no-ext-diff', '--no-textconv', '--', '.',
                      ':(exclude).capbox', ':(exclude).git'], work=view, index=index)
    if len(patch) > 16 * 1024 * 1024:
        raise AgentError('diff 超过 16MiB 限制，请缩小任务改动')
    origin = Path(plan['origin'])
    conflicts = []
    for name in set(baseline) | set(new):
        old = baseline.get(name)
        try:
            data, st = read_regular(origin, name)
            if old is None or hashlib.sha256(data).hexdigest() != old['sha256'] or bool(st.st_mode & 0o111) != old['executable']:
                conflicts.append(name)
        except (OSError, AgentError):
            if old is not None:
                conflicts.append(name)
    conflicts.sort()
    result = {'kind': 'workspace_diff', 'task_id': job.name, 'changed_files': sorted(
        name for name in set(current) | set(baseline) if current.get(name) != baseline.get(name)),
        'origin_changed': conflicts, 'patch_base64': base64.b64encode(patch).decode(),
        'notes': 'Export only; review the patch and source baseline before applying. CapBox never auto-applies isolate diffs — apply on the host only after review.'}
    if as_json:
        emit(result)
    else:
        sys.stdout.buffer.write(patch)
        if conflicts:
            print('宿主基线已有变化，请先解决冲突: ' + ', '.join(conflicts), file=sys.stderr)
    return 0


def nonnegative(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError('必须是非负整数')
    return number


def parser():
    p = argparse.ArgumentParser(prog='capbox', description='本地 Agent 任务与策略诊断')
    families = p.add_subparsers(dest='family', required=True)
    task = families.add_parser('task', help='可恢复任务；所有状态/结果为版本化 JSON')
    commands = task.add_subparsers(dest='action', required=True)
    start = commands.add_parser('start', help='启动独立监督的 exec 任务')
    start.add_argument('--json', action='store_true', help='结果默认即为版本化 JSON')
    start.add_argument('--timeout', type=nonnegative, default=600)
    start.add_argument('--cwd', default='/workspace')
    start.add_argument('--net', choices=['none', 'restricted', 'open', 'host'])
    start.add_argument('--profile', choices=['compat', 'untrusted', 'strict'])
    start.add_argument('--isolate', action='store_true', help='复制工作区文件与独立 rootfs（Git 脏树/非 Git/overlay 合并）；diff 后导出')
    start.add_argument('--max-output-bytes', type=nonnegative, default=MAX_STREAM)
    start.add_argument('command', nargs=argparse.REMAINDER)
    listing = commands.add_parser('list')
    listing.add_argument('--json', action='store_true')
    for action in ('status', 'wait', 'attach', 'cancel', 'logs', 'diff', 'rm'):
        cmd = commands.add_parser(action)
        cmd.add_argument('task_id')
        cmd.add_argument('--json', action='store_true', help='输出 JSON（attach 为 JSONL；logs/diff 的二进制用 base64）')
        if action in ('wait', 'attach'):
            cmd.add_argument('--timeout', type=nonnegative, default=0, help='客户端等待上限；到期返回124，不取消任务')
        if action == 'attach':
            cmd.add_argument('--stdout-offset', type=nonnegative, default=0)
            cmd.add_argument('--stderr-offset', type=nonnegative, default=0)
        if action == 'logs':
            cmd.add_argument('--stream', choices=['stdout', 'stderr'], default='stdout')
            cmd.add_argument('--offset', type=nonnegative, default=0)
            cmd.add_argument('--limit', type=nonnegative, default=65536)
    policy = families.add_parser('policy', help='解释新 oneshot 的请求策略；不改变配置')
    policies = policy.add_subparsers(dest='action', required=True)
    for action in ('show', 'check'):
        cmd = policies.add_parser(action)
        cmd.add_argument('--json', action='store_true')
        cmd.add_argument('--net', choices=['none', 'restricted', 'open', 'host'])
        cmd.add_argument('--profile', choices=['compat', 'untrusted', 'strict'])
        if action == 'check':
            cmd.add_argument('target')
            cmd.add_argument('--resolve', action='store_true', help='显式执行 DNS 查询，仍不会连接目标 TCP 端口')
    return p


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ['__worker']:
        return worker(private_dir(Path(argv[1])), argv[2])
    args = parser().parse_args(argv)
    ctx = context()
    if args.family == 'policy':
        result = network_check(ctx, args) if args.action == 'check' else effective(ctx, args)
        emit(result)
        return 1 if result.get('decision') == 'deny' else 0
    root = private_dir(private_dir(Path(os.environ['CAPBOX_AGENT_PRIVATE'])) / 'tasks', create=True)
    if args.action == 'start':
        if args.max_output_bytes > 64 * 1024 * 1024:
            raise AgentError('每路日志上限不能超过 64MiB', 2)
        return start_task(ctx, root, args)
    if args.action == 'list':
        jobs = [public_state(job_path(root, d.name)) for d in sorted(root.iterdir())
                if re.fullmatch('[0-9a-f]{32}', d.name)]
        emit({'kind': 'tasks', 'tasks': jobs})
        return 0
    job = job_path(root, args.task_id)
    if args.action == 'status':
        emit(public_state(job))
    elif args.action == 'cancel':
        if state_of(job)['status'] not in TERMINAL:
            fd = os.open(job / 'cancel', os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            os.close(fd)
        emit(public_state(job))
    elif args.action == 'logs':
        if args.limit > 1024 * 1024:
            raise AgentError('单次日志读取上限为 1MiB', 2)
        chunk = log_chunk(job, args.stream, args.offset, args.limit)
        if args.json:
            emit(chunk)
        else:
            sys.stdout.buffer.write(base64.b64decode(chunk['data_base64']))
    elif args.action in ('wait', 'attach'):
        offsets = {s: getattr(args, s + '_offset', 0) for s in ('stdout', 'stderr')}
        deadline = time.monotonic() + args.timeout if args.timeout else None
        while True:
            state = public_state(job)
            if args.action == 'attach':
                for stream in offsets:
                    while True:
                        chunk = log_chunk(job, stream, offsets[stream], 65536)
                        if chunk['next_offset'] == offsets[stream]:
                            break
                        offsets[stream] = chunk['next_offset']
                        if args.json:
                            emit(dict(type='output', **chunk))
                        else:
                            output = sys.stdout.buffer if stream == 'stdout' else sys.stderr.buffer
                            output.write(base64.b64decode(chunk['data_base64']))
                            output.flush()
            if state['status'] in TERMINAL:
                if args.action == 'wait' or args.json:
                    emit(dict(type='exit', **state))
                return return_code(state)
            if deadline and time.monotonic() >= deadline:
                if args.json or args.action == 'wait':
                    emit({'kind': 'wait_timeout', 'task_id': job.name, 'status': state['status'],
                          'hint': '客户端等待超时（未取消任务）。继续 status/logs/wait，或显式 cancel。'})
                return 124
            time.sleep(0.05)
    elif args.action == 'diff':
        return diff_task(ctx, job, args.json)
    elif args.action == 'rm':
        state = state_of(job)
        if state['status'] not in TERMINAL:
            raise AgentError('不能删除运行中的任务；请先 cancel/wait')
        if state['status'] == 'lost':
            raise AgentError('lost 任务需人工确认外层会话已结束，首版不自动清理')
        shutil.rmtree(job)
        emit({'kind': 'removed', 'task_id': args.task_id})
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except AgentError as exc:
        print('[capbox] ' + str(exc), file=sys.stderr)
        sys.exit(exc.code)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print('[capbox] 任务操作失败: ' + type(exc).__name__ + ': ' + str(exc), file=sys.stderr)
        sys.exit(1)
