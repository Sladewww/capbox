#!/usr/bin/env python3
"""本地任务生命周期、策略说明与可审阅的工作区副本。

只有 exec 会在 guest 内启动命令。本宿主控制器把任务输出与工作区内容当数据，
永不执行 guest 提供的脚本。
"""
import argparse
import base64
import ctypes
import errno
import fcntl
import fnmatch
import hashlib
import importlib.util
import io
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
import tarfile
import time
import uuid
from urllib.parse import urlsplit

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
import i18n
from audit_store import TASK_ID, policy_summary, task_event

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
        raise AgentError(i18n.t('task.host_task_dir_unsafe'))
    if path.resolve() != path:
        raise AgentError(i18n.t('task.host_task_dir_must_not_follow_symlink'))
    return path


def read_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise AgentError(i18n.t('task.record_must_be_regular_file'))
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
    requested = getattr(args, 'net_allow', None)
    if requested is not None:
        if cfg.get('NET') != 'restricted':
            raise AgentError(i18n.t('task.net_allow_requires_restricted'), 2)
        module = net_module(ctx)
        rules = module.parse_allowlist(requested)
        if not module.allowlist_subset(rules, module.parse_allowlist(cfg.get('NET_ALLOW', ''))):
            raise AgentError(i18n.t('task.net_allow_outside_host'), 2)
        cfg['NET_ALLOW'], sources['NET_ALLOW'] = ','.join(rules), 'command'
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
            'scope': i18n.t('policy.scope_new_oneshot'),
            'limits': i18n.t('policy.limits_checked_at_exec'),
            'notes': [i18n.t('policy.note_net_none_pkg'),
                      i18n.t('policy.note_idmap_auto_on'),
                      i18n.t('policy.note_readonly_rootfs_overlay')]}


def net_module(ctx):
    spec = importlib.util.spec_from_file_location('capbox_net_policy', Path(ctx['lib']) / 'net-proxy.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def network_check(ctx, args):
    target = urlsplit(args.target)
    if target.scheme not in ('http', 'https') or not target.hostname or target.username or target.password:
        raise AgentError(i18n.t('policy.url_must_be_http_without_credentials'), 2)
    try:
        host, port = target.hostname, target.port or (443 if target.scheme == 'https' else 80)
    except ValueError as exc:
        raise AgentError(i18n.t('policy.url_port_invalid'), 2) from exc
    policy = effective(ctx, args)
    mode = policy['values']['NET']['value']
    result = {'kind': 'network_decision', 'host': host, 'port': port, 'mode': mode,
              'decision': 'deny', 'reason': 'network_none', 'connectivity_tested': False}
    if mode == 'open':
        result.update(decision='allow', reason='shared_host_network')
    elif mode == 'restricted':
        module = net_module(ctx)
        rules = module.parse_allowlist(policy['values']['NET_ALLOW']['value'])
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
    result['notes'] = i18n.t('policy.preview_notes')
    return result


def clean_environment(ctx):
    # 只保留启动前置项，不含宿主 API 密钥、SSH agent 或 Git 配置。
    env = {k: os.environ[k] for k in ('PATH', 'HOME', 'LANG', 'TERM', 'XDG_RUNTIME_DIR', 'XDG_STATE_HOME') if k in os.environ}
    for k, value in ctx['config'].items():
        if k == 'ALLOW_OLD_BWRAP' or (k == 'ROOTFS_RO' and ctx['sources'].get(k, 'default') == 'default'):
            continue
        env['CAPBOX_' + k] = value
    # 显式 cgroup 委托在现有启动器中不走 config.env。
    if 'CAPBOX_CGROUP_ROOT' in os.environ:
        env['CAPBOX_CGROUP_ROOT'] = os.environ['CAPBOX_CGROUP_ROOT']
    return env


def safe_relative(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or any(p in ('', '.', '..') for p in name.split('/')):
        raise AgentError(i18n.t('task.work_copy_path_invalid'))
    return path


def excluded(name):
    return any(part in EXCLUDED or part.startswith('.env.') or fnmatch.fnmatch(part, '*.pem')
               or fnmatch.fnmatch(part, '*.key') or part.startswith('id_rsa')
               for part in PurePosixPath(name).parts)


def read_regular(root, name):
    """相对钉住的目录逐级打开每一段，从不跟随链接。"""
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
                raise AgentError(i18n.t('task.only_regular_non_hardlink', name=name))
            if before.st_size > MAX_COPY:
                raise AgentError(i18n.t('task.file_exceeds_work_copy_limit', name=name))
            data = f.read(MAX_COPY + 1)
            after = os.fstat(f.fileno())
            signature = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            if len(data) > MAX_COPY or signature(before) != signature(after):
                raise AgentError(i18n.t('task.file_changed_during_read', name=name))
            return data, before
    finally:
        os.close(directory)


def regular_files(root, *, require_readable=False):
    def unreadable(error):
        raise error

    result, total = {}, 0
    for directory, dirs, files in os.walk(
            root, followlinks=False, onerror=unreadable if require_readable else None):
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
                raise AgentError(i18n.t('task.isolate_only_regular_files', rel=rel))
            total += st.st_size
            if total > MAX_COPY or len(result) >= MAX_FILES:
                raise AgentError(i18n.t('task.work_copy_exceeds_first_edition_limit'))
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
        raise AgentError(i18n.t('task.git_work_copy_failed'))
    return proc.stdout


def is_git_workspace_root(ctx, source):
    try:
        top = Path(git(ctx, ['rev-parse', '--show-toplevel'], work=source).decode().strip()).resolve()
    except AgentError:
        return False
    return top == source.resolve()


def list_isolate_names(ctx, source):
    """返回 isolate 视图的相对路径：脏 Git 树或文件系统遍历。"""
    if is_git_workspace_root(ctx, source):
        # 已跟踪工作树文件 + 未跟踪文件，仍遵守 .gitignore。
        # 列出后 CapBox 凭据排除规则仍优先。
        raw = git(ctx, ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], work=source)
        names = []
        for item in raw.split(b'\0'):
            if not item:
                continue
            names.append(item.decode('utf-8', 'strict'))
        return sorted(set(names)), 'git'
    if not source.is_dir() or source.is_symlink():
        raise AgentError(i18n.t('task.isolate_not_git_or_traversable'), 2)
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
        # 空项目仍是合法的合成基线。
        return [], 'fs'
    return sorted(set(names)), 'fs'


def is_overlay_whiteout(st):
    return stat.S_ISCHR(st.st_mode) and os.major(st.st_rdev) == 0 and os.minor(st.st_rdev) == 0


def overlay_attribute(path, name):
    for namespace in ('user', 'trusted'):
        try:
            return os.getxattr(path, f'{namespace}.overlay.{name}', follow_symlinks=False)
        except OSError as exc:
            if exc.errno not in (errno.ENODATA, errno.ENOTSUP):
                raise
    return None


def remove_overlay_target(path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)


def merge_overlay_upper(upper, dest_rootfs):
    """Apply the supported copy-up and whiteout entries to a private rootfs."""
    if upper.is_symlink() or not upper.is_dir():
        raise AgentError(i18n.t('task.isolate_unsafe_overlay_upper'))

    for directory, dirs, files in os.walk(upper, followlinks=False):
        source = Path(directory)
        relative = source.relative_to(upper)
        target = dest_rootfs / relative
        if target.is_symlink() or (target.exists() and not target.is_dir()):
            remove_overlay_target(target)
        target.mkdir(exist_ok=True)
        if overlay_attribute(source, 'redirect') is not None:
            raise AgentError(i18n.t('task.isolate_overlay_upper_special', rel=relative))
        opaque_marker = source / '.wh..wh..opq'
        if ('.wh..wh..opq' in files and not opaque_marker.is_symlink()) or overlay_attribute(source, 'opaque') == b'y':
            for child in target.iterdir():
                remove_overlay_target(child)
        for name in dirs + files:
            src = source / name
            rel = relative / name
            if src.is_symlink():
                raise AgentError(i18n.t('task.isolate_overlay_upper_symlink', rel=rel))
            if name == '.wh..wh..opq' and name in files:
                continue
            st = src.lstat()
            if name.startswith('.wh.') and name in files:
                target_name = name[4:]
                if target_name in ('', '.', '..'):
                    raise AgentError(i18n.t('task.isolate_overlay_upper_special', rel=rel))
                remove_overlay_target(target / target_name)
            elif is_overlay_whiteout(st) or overlay_attribute(src, 'whiteout') is not None:
                remove_overlay_target(target / name)
            elif stat.S_ISREG(st.st_mode) and overlay_attribute(src, 'metacopy') is None:
                dst = target / name
                remove_overlay_target(dst)
                shutil.copy2(src, dst)
            elif not stat.S_ISDIR(st.st_mode) or name.startswith('.wh.'):
                raise AgentError(i18n.t('task.isolate_overlay_upper_special', rel=rel))


def isolate(ctx, job):
    source = Path(ctx['workspace']).resolve()
    if not source.is_dir() or source.is_symlink():
        raise AgentError(i18n.t('task.isolate_needs_readable_workspace'), 2)
    upper = Path(ctx['rootfs']).resolve().parent.parent / 'run/overlay/active/upper'
    if any(path.is_symlink() for path in (upper, *upper.parents[:3])):
        raise AgentError(i18n.t('task.isolate_rejects_symlink_overlay_upper'))
    if upper.exists() and not upper.is_dir():
        raise AgentError(i18n.t('task.isolate_unsafe_overlay_upper'))
    try:
        names, mode = list_isolate_names(ctx, source)
    except AgentError:
        raise
    except OSError as exc:
        raise AgentError(i18n.t('task.isolate_cannot_enumerate_workspace')) from exc
    view = job / 'workspace'
    view.mkdir(mode=0o755)  # 外层 job 仍为 0700；映射后的非 root 用户可读该视图
    baseline, skipped, total = {}, [], 0
    for name in names:
        relative = safe_relative(name)
        if excluded(name):
            skipped.append(name)
            continue
        src = source / relative
        if not src.exists() and not src.is_symlink():
            continue  # 保留已跟踪路径在工作树上的删除
        try:
            data, st = read_regular(source, name)
        except OSError as exc:
            raise AgentError(i18n.t('task.source_workspace_symlink_or_unreadable', name=name)) from exc
        total += st.st_size
        if total > MAX_COPY or len(baseline) >= MAX_FILES:
            raise AgentError(i18n.t('task.work_copy_exceeds_limit'))
        dst = view / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        with dst.open('xb') as outgoing:
            outgoing.write(data)
        dst.chmod(0o755 if st.st_mode & 0o111 else 0o644)
        baseline[name] = {'sha256': hashlib.sha256(data).hexdigest(),
                          'executable': bool(st.st_mode & 0o111)}
    # 审阅元数据在 guest 视图外。从不使用 guest 的 .git/config 跑 Git。
    # 非 Git 与脏 Git 都给合成基线，保证 task diff 可用。
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
    # 私有独立 rootfs：不硬链到线上可变镜像 / upper。
    dest_rootfs = state / 'os' / ctx['config']['DISTRO']
    shutil.copytree(ctx['rootfs'], dest_rootfs, symlinks=True)
    if upper.exists() and upper.is_dir() and any(upper.iterdir()):
        merge_overlay_upper(upper, dest_rootfs)
    ctx = dict(ctx, workspace=str(view), rootfs=str(dest_rootfs))
    return ctx, skipped


def job_path(root, name):
    if not TASK_ID.fullmatch(name):
        raise AgentError(i18n.t('task.invalid_task_id'), 2)
    try:
        return private_dir(root / name)
    except FileNotFoundError as exc:
        raise AgentError(i18n.t('task.task_id_not_found'), 2) from exc


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
        result['hint'] = i18n.t('task.hint_timed_out')
    elif result.get('status') == 'cancelled':
        result['hint'] = i18n.t('task.hint_cancelled')
    return result


def return_code(state):
    code = state.get('exit_code')
    return code if isinstance(code, int) and 0 <= code <= 255 else 125


def start_task(ctx, root, args):
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        raise AgentError(i18n.t('task.start_missing_command'), 2)
    policy = effective(ctx, args)
    if not Path(ctx['rootfs']).is_dir():
        raise AgentError(i18n.t('task.rootfs_missing_run_init'), 4)
    active = [d for d in root.iterdir() if d.is_dir() and not d.is_symlink()
              and re.fullmatch('[0-9a-f]{32}', d.name) and state_of(d)['status'] not in TERMINAL]
    if len(active) >= 8:
        raise AgentError(i18n.t('task.too_many_active_tasks'))
    task_id = uuid.uuid4().hex
    job = private_dir(root / task_id, create=True)
    state = {'task_id': task_id, 'status': 'preparing', 'created_at': time.time(),
             'exit_code': None, 'worker': identity(os.getpid()), 'isolated': args.isolate,
             'policy': policy, 'output_limit_per_stream': args.max_output_bytes}
    write_json(job / 'state.json', state)
    config = ctx['config']
    audit_path = os.environ['CAPBOX_AGENT_AUDIT_PATH']
    audit_command = os.environ.get('CAPBOX_AGENT_AUDIT_CMD')
    submission = {'policy': policy_summary(state['policy']['values']), 'isolated': args.isolate}
    if audit_command:
        submission['cmd'] = audit_command
    task_event(audit_path, config, state, 'start', **submission)
    origin = ctx['workspace']
    launched = None
    try:
        skipped = []
        if args.isolate:
            ctx, skipped = isolate(ctx, job)
        env = clean_environment(ctx)
        env['CAPBOX_NET_ALLOW'] = policy['values']['NET_ALLOW']['value']
        env['CAPBOX_NET_SESSION'] = 'task-' + task_id
        env['CAPBOX_TASK_LAUNCH_STATUS'] = str(job / 'launch.jsonl')
        env['CAPBOX_TASK_AUDIT_ID'] = task_id
        env['CAPBOX_TASK_AUDIT_PATH'] = audit_path
        argv = [ctx['cli'], '--root', ctx['workspace']]
        if ctx['allow_once']:
            argv += ['--allow-old-bwrap']
        # 截止时间由本控制器掌握。GNU timeout 会另建进程组，
        # 否则取消 CLI 进程组时它会漏网。
        argv += ['exec', '--timeout', '0', '--cwd', args.cwd]
        if args.net:
            argv += ['--net', args.net]
        if args.profile:
            argv += ['--profile', args.profile]
        argv += ['--'] + command
        write_json(job / 'plan.json', {'argv': argv, 'env': env, 'timeout': args.timeout,
                                      'origin': origin, 'workspace': ctx['workspace'], 'audit_path': audit_path,
                                      'config': ctx['config'], 'sources': ctx['sources'],
                                      'skipped': skipped, 'max_output_bytes': args.max_output_bytes})
        # worker 生命周期独立于本 CLI。外层监督器仍可结束整个宿主会话；
        # 那时状态变为 lost，绝不会标成成功。
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
                raise AgentError(i18n.t('task.supervisor_did_not_start'))
            time.sleep(0.02)
        raise AgentError(i18n.t('task.supervisor_start_timed_out'))
    except BaseException:
        if launched is not None and launched.poll() is None:
            launched.kill()
            launched.wait()
        state.update(status='failed', exit_code=1, finished_at=time.time(), failure_reason='launch_failed')
        task_event(audit_path, config, state, 'fail')
        write_json(job / 'state.json', state)
        raise


def pdeathsig(parent):
    # 控制器死后不能留下仍在跑的 CLI/bwrap 子进程。
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0 or os.getppid() != parent:
        os._exit(125)


def launch_outcome(job, code):
    """The host launcher writes a marker before bubblewrap setup and bwrap reports exit."""
    try:
        with (job / 'launch.jsonl').open() as stream:
            if stream.readline() != 'supported\n':
                return None
            for line in stream:
                if line == 'unsupported\n':
                    return None
                record = json.loads(line)
                if 'exit-code' in record:
                    return 'nonzero_exit' if record['exit-code'] == code else None
            return 'launch_failed'
    except (OSError, ValueError):
        return None


def worker(root, task_id):
    job = job_path(root, task_id)
    lock = os.open(job / 'worker.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    state = read_json(job / 'state.json')
    if state['status'] != 'preparing':
        raise AgentError(i18n.t('task.already_submitted_to_supervisor'))
    plan = read_json(job / 'plan.json')
    state.update(status='running', worker=identity(os.getpid()), started_at=time.time())
    audit_path = plan.get('audit_path')
    if audit_path:
        task_event(audit_path, plan['config'], state, 'start')
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
        elif reason == 'timed_out':
            code = 124
        state.update(status=reason or ('succeeded' if code == 0 else 'failed'), exit_code=code)
        if reason:
            state['failure_reason'] = {'cancelled': 'cancelled', 'timed_out': 'execution_timeout'}[reason]
        elif code:
            outcome = launch_outcome(job, code)
            if outcome:
                state['failure_reason'] = outcome
    except BaseException as exc:
        if proc is not None and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        state.update(status='failed', exit_code=125, error=type(exc).__name__)
        if proc is None:
            state['failure_reason'] = 'launch_failed'
    finally:
        for output, _size in streams.values():
            output.close()
        state.update(finished_at=time.time(), dropped_bytes=dropped)
        if audit_path:
            task_event(audit_path, plan['config'], state,
                       'ok' if state['exit_code'] == 0 else 'fail')
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
                # 兼容越过 EOF 轮询的客户端空读，但打上标记。
                return {'task_id': job.name, 'stream': stream, 'offset': offset,
                        'next_offset': offset, 'data_base64': '',
                        'size': size, 'eof': True, 'cursor_past_eof': True,
                        'hint': i18n.t('task.hint_log_cursor_past_eof', offset=offset, size=size)}
            f.seek(offset)
            data = f.read(limit)
    next_offset = offset + len(data)
    eof = next_offset >= size
    result = {'task_id': job.name, 'stream': stream, 'offset': offset,
              'next_offset': next_offset, 'data_base64': base64.b64encode(data).decode(),
              'size': size, 'eof': eof, 'cursor_past_eof': False}
    return result


SECRET_PATTERNS = {
    'private_key': re.compile(
        rb'-----BEGIN (?:(?:RSA |DSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY|PGP PRIVATE KEY BLOCK)-----'),
    'github_token': re.compile(
        rb'(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{82})'
        rb'(?![A-Za-z0-9_])'),
}
# Public report labels are independent of the pattern objects and input bytes.
SCAN_TYPES = ('private_key', 'github_token')
MAX_SCAN_FINDINGS = 1000
HUNK = re.compile(rb'^@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)(?:,[0-9]+)? @@')


def scan_path(name):
    for pattern in SECRET_PATTERNS.values():
        name = pattern.sub(b'[REDACTED]', name)
    return name.decode('utf-8', 'replace')


def scan_patch(stats, patch):
    # NUL-delimited numstat and patch sections share Git's file order.
    # File names never need to be parsed from quoted patch headers.
    paths = iter(stats.split(b'\0')[:-1])
    sections = []
    for record in paths:
        added, removed, name = record.split(b'\t', 2)
        if not name:  # rename or copy: old and new paths are separate fields
            next(paths)
            name = next(paths)
        sections.append((scan_path(name), added == removed == b'-'))

    sections = iter(sections)
    findings, skipped = [], []
    truncated = False
    line_number, binary = None, True
    deleted = False
    for line in io.BytesIO(patch):
        if line.startswith(b'diff --git '):
            section = next(sections, None)
            if section is None:
                raise AgentError(i18n.t('task.scan_patch_unreadable'))
            name, binary = section
            line_number = None
            deleted = False
        elif binary:
            if line.startswith(b'deleted file mode '):
                deleted = True
            elif line == b'GIT binary patch\n' and not deleted:
                skipped.append({'path': name, 'reason': 'binary'})
        else:
            hunk = HUNK.match(line)
            if hunk:
                line_number = int(hunk[1])
            elif line_number is not None and line.startswith(b'+'):
                for kind in SCAN_TYPES:
                    if SECRET_PATTERNS[kind].search(line[1:]):
                        if len(findings) < MAX_SCAN_FINDINGS:
                            findings.append({'path': name, 'line': line_number,
                                             'type': kind})
                        else:
                            truncated = True
                line_number += 1
            elif line_number is not None and line.startswith(b' '):
                line_number += 1
    if next(sections, None) is not None:
        raise AgentError(i18n.t('task.scan_patch_unreadable'))
    status = 'findings' if findings else 'incomplete' if skipped else 'clean'
    return {'status': status, 'findings': findings, 'skipped': skipped,
            'findings_truncated': truncated}


def report_scan(scan):
    for finding in scan['findings']:
        location = json.dumps(finding['path'], ensure_ascii=True)
        kind = 'private_key' if finding['type'] == 'private_key' else 'github_token'
        print(f"{location}:{finding['line']}: {kind}", file=sys.stderr)
    for skipped in scan['skipped']:
        location = json.dumps(skipped['path'], ensure_ascii=True)
        print(f"{location}: {i18n.t('task.scan_binary_skipped')}", file=sys.stderr)
    if scan['findings_truncated']:
        print(i18n.t('task.scan_findings_truncated', limit=MAX_SCAN_FINDINGS), file=sys.stderr)
    print(i18n.t('task.scan_' + scan['status']), file=sys.stderr)


def diff_summary(job, scan_secrets=False):
    state = state_of(job)
    if not state['isolated'] or state['status'] not in FINISHED:
        raise AgentError(i18n.t('task.diff_only_finished_isolated'), 2)
    plan = read_json(job / 'plan.json')
    view = job / 'workspace'
    try:
        if scan_secrets and not stat.S_ISDIR(view.lstat().st_mode):
            raise AgentError(i18n.t('task.scan_workspace_unreadable'))
        current = regular_files(view, require_readable=scan_secrets)
    except (OSError, AgentError) as exc:
        if not scan_secrets:
            raise
        if isinstance(exc, AgentError):
            raise AgentError(scan_path(str(exc).encode('utf-8', 'surrogateescape')), exc.code) from exc
        raise AgentError(i18n.t('task.scan_workspace_unreadable')) from exc
    baseline = read_json(job / 'baseline.json')
    new = sorted(set(current) - set(baseline))
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
    changed = sorted(name for name in set(current) | set(baseline)
                     if current.get(name) != baseline.get(name))
    return {'changed_files': changed, 'origin_changed': conflicts}, new


def diff_task(ctx, job, as_json, scan_secrets):
    summary, new = diff_summary(job, scan_secrets)
    view, index = job / 'workspace', job / 'review.git'
    if new:
        payload = b''.join(name.encode() + b'\0' for name in new)
        git(ctx, ['add', '--intent-to-add', '--force', '--pathspec-from-file=-',
                  '--pathspec-file-nul'], work=view, index=index, data=payload)
    diff_args = ['diff', '--binary', '--no-ext-diff', '--no-textconv']
    if scan_secrets:
        diff_args += ['--numstat', '-z']
    patch = git(ctx, diff_args + ['--', '.', ':(exclude).capbox', ':(exclude).git'],
                work=view, index=index)
    if scan_secrets:
        stats, separator, patch = patch.partition(b'\0\0')
        if not separator and stats:
            raise AgentError(i18n.t('task.scan_patch_unreadable'))
        if separator:
            stats += b'\0'
    if len(patch) > 16 * 1024 * 1024:
        raise AgentError(i18n.t('task.diff_exceeds_16mib'))
    if scan_secrets:
        scan = scan_patch(stats, patch)
        if scan['status'] != 'clean':
            if as_json:
                emit({'kind': 'workspace_diff_scan', 'task_id': job.name, 'scan': scan})
            else:
                report_scan(scan)
            return 3
    conflicts = summary['origin_changed']
    result = {'kind': 'workspace_diff', 'task_id': job.name, **summary, 'patch_base64': base64.b64encode(patch).decode(),
        'notes': i18n.t('task.diff_export_notes')}
    if scan_secrets:
        result['scan'] = scan
    if as_json:
        emit(result)
    else:
        sys.stdout.buffer.write(patch)
        if scan_secrets:
            report_scan(scan)
            conflicts = [scan_path(os.fsencode(name)) for name in conflicts]
        if conflicts:
            print(i18n.t('task.host_baseline_changed', conflicts=', '.join(conflicts)), file=sys.stderr)
    return 0


def nonnegative(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError(i18n.t('task.must_be_nonnegative_integer'))
    return number


def parser():
    p = i18n.I18nArgumentParser(prog='capbox', description=i18n.t('task.parser_description'))
    families = p.add_subparsers(dest='family', required=True)
    task = families.add_parser('task', help=i18n.t('task.help_family'))
    commands = task.add_subparsers(dest='action', required=True)
    start = commands.add_parser('start', help=i18n.t('task.help_start'))
    start.add_argument('--json', action='store_true', help=i18n.t('task.help_start_json'))
    start.add_argument('--timeout', type=nonnegative, default=600)
    start.add_argument('--cwd', default='/workspace')
    start.add_argument('--net', choices=['none', 'restricted', 'open', 'host'])
    start.add_argument('--net-allow', help=i18n.t('task.help_net_allow'))
    start.add_argument('--profile', choices=['compat', 'untrusted', 'strict'])
    start.add_argument('--isolate', action='store_true', help=i18n.t('task.help_isolate'))
    start.add_argument('--max-output-bytes', type=nonnegative, default=MAX_STREAM)
    start.add_argument('command', nargs=argparse.REMAINDER)
    listing = commands.add_parser('list')
    listing.add_argument('--json', action='store_true')
    for action in ('status', 'wait', 'attach', 'cancel', 'logs', 'diff', 'rm'):
        cmd = commands.add_parser(action)
        cmd.add_argument('task_id')
        cmd.add_argument('--json', action='store_true', help=i18n.t('task.help_json'))
        if action in ('wait', 'attach'):
            cmd.add_argument('--timeout', type=nonnegative, default=0, help=i18n.t('task.help_wait_timeout'))
        if action == 'attach':
            cmd.add_argument('--stdout-offset', type=nonnegative, default=0)
            cmd.add_argument('--stderr-offset', type=nonnegative, default=0)
        if action == 'diff':
            cmd.add_argument('--scan-secrets', action='store_true',
                             help=i18n.t('task.help_scan_secrets'))
        if action == 'logs':
            cmd.add_argument('--stream', choices=['stdout', 'stderr'], default='stdout')
            cmd.add_argument('--offset', type=nonnegative, default=0)
            cmd.add_argument('--limit', type=nonnegative, default=65536)
    checkpoint = commands.add_parser('checkpoint', help=i18n.t('task.help_checkpoint'))
    checkpoint.add_argument('task_id')
    checkpoint.add_argument('output')
    restore = commands.add_parser('restore', help=i18n.t('task.help_restore_checkpoint'))
    restore.add_argument('source')
    restore.add_argument('destination')
    restore.add_argument('--manifest-sha256')
    policy = families.add_parser('policy', help=i18n.t('policy.help_family'))
    policies = policy.add_subparsers(dest='action', required=True)
    for action in ('show', 'check'):
        cmd = policies.add_parser(action)
        cmd.add_argument('--json', action='store_true')
        cmd.add_argument('--net', choices=['none', 'restricted', 'open', 'host'])
        cmd.add_argument('--net-allow', help=i18n.t('task.help_net_allow'))
        cmd.add_argument('--profile', choices=['compat', 'untrusted', 'strict'])
        if action == 'check':
            cmd.add_argument('target')
            cmd.add_argument('--resolve', action='store_true', help=i18n.t('policy.help_resolve'))
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
            raise AgentError(i18n.t('task.log_limit_exceeds_64mib'), 2)
        return start_task(ctx, root, args)
    if args.action == 'list':
        jobs = [public_state(job_path(root, d.name)) for d in sorted(root.iterdir())
                if re.fullmatch('[0-9a-f]{32}', d.name)]
        emit({'kind': 'tasks', 'tasks': jobs})
        return 0
    if args.action in ('checkpoint', 'restore'):
        # Resolve modules from the running controller, never from archived data.
        def load(name):
            spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module

        envkit, checkpoint = load('envkit-runtime'), load('task-checkpoint')
        try:
            if args.action == 'checkpoint':
                result = checkpoint.capture(sys.modules[__name__], envkit, ctx,
                                            job_path(root, args.task_id), args.output)
            else:
                result = checkpoint.restore(sys.modules[__name__], envkit, ctx, args.source,
                                            args.destination, args.manifest_sha256)
        except (envkit.Failure, tarfile.TarError) as exc:
            raise AgentError(str(exc)) from exc
        emit(result)
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
            raise AgentError(i18n.t('task.single_log_read_limit_1mib'), 2)
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
                audit_path = os.environ['CAPBOX_AGENT_AUDIT_PATH']
                task_event(audit_path, ctx['config'], state, 'warn',
                           observation='client_wait_timeout', detail='client_wait_timeout')
                if args.json or args.action == 'wait':
                    emit({'kind': 'wait_timeout', 'failure_reason': 'client_wait_timeout',
                          'task_id': job.name, 'status': state['status'],
                          'hint': i18n.t('task.hint_client_wait_timeout')})
                return 124
            time.sleep(0.05)
    elif args.action == 'diff':
        return diff_task(ctx, job, args.json, args.scan_secrets)
    elif args.action == 'rm':
        state = state_of(job)
        if state['status'] not in TERMINAL:
            raise AgentError(i18n.t('task.cannot_remove_running'))
        if state['status'] == 'lost':
            raise AgentError(i18n.t('task.lost_requires_manual_confirm'))
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
    except (OSError, EOFError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print(i18n.t('task.operation_failed', type=type(exc).__name__, exc=exc), file=sys.stderr)
        sys.exit(1)
