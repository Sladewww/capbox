"""Shared JSONL safety and redaction for host task auditing and reports."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import stat
import sys

import i18n

TASK_ID = re.compile(r'[0-9a-f]{32}')
TASK_STATES = {'preparing', 'running', 'succeeded', 'failed', 'cancelled', 'timed_out', 'lost'}
POLICY_FIELDS = (
    'SECURITY_PROFILE', 'NET', 'NET_ALLOW', 'IDMAP', 'EXEC_UID', 'EXEC_GID',
    'MEMORY_MAX', 'CPU_MAX', 'PIDS_MAX', 'DISK_MAX', 'RESOURCES_MODE',
    'FS_HIDE', 'FS_BINDS', 'OVERLAY', 'ROOTFS_RO', 'LANDLOCK',
    'WORKSPACE_READONLY', 'WRITE_DIRS',
)
SENSITIVE = (r'(?:[A-Za-z][A-Za-z0-9_-]{0,80}[_-])?'
             r'(?:password|passwd|pwd|token|secret|api[_-]?key|authorization|access[_-]?token|'
             r'client[_-]?secret|secret[_-]?access[_-]?key|access[_-]?key(?:[_-]?id)?|private[_-]?key)')


def redact(value):
    value = re.sub(r'(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+', r'\1 [REDACTED]', value)
    value = re.sub(r'(?i)(https?://)[^\s/@]+@', r'\1[REDACTED]@', value)
    pattern = r'(?i)(\b' + SENSITIVE + r'\b[\s\"\x27]*[=:][\s]*)(?:\"[^\"]*\"|\x27[^\x27]*\x27|[^\s&;,]+)'
    value = re.sub(pattern, r'\1[REDACTED]', value)
    pattern = r'(?i)(--?' + SENSITIVE + r'\s+)(?:\"[^\"]*\"|\x27[^\x27]*\x27|[^\s]+)'
    return re.sub(pattern, r'\1[REDACTED]', value)


def parent_fd(path):
    """钉住每一级目录，不跟随 guest 可写的符号链接祖先。"""
    path = Path(os.path.abspath(path))
    if not path.name:
        raise ValueError(i18n.t('audit.filename_required'))
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd, path.name
    except BaseException:
        os.close(fd)
        raise


def policy_summary(values):
    if not isinstance(values, dict):
        return {}
    result = {}
    for key in POLICY_FIELDS:
        item = values.get(key)
        if isinstance(item, dict) and isinstance(item.get('value'), str):
            source = item.get('source')
            if source in ('default', 'env', 'file', 'user', 'command', 'profile', 'host'):
                result[key] = {'value': redact(item['value'])[:512], 'source': source}
    return result


def append(path, line):
    # The shell emits a complete record before opening the persistent stream.
    parent, name = parent_fd(path)
    try:
        fd = os.open(name, os.O_WRONLY | os.O_APPEND | os.O_CREAT |
                     os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise ValueError(i18n.t('audit.source_must_be_regular_file'))
            # One O_APPEND write prevents interleaving between task workers.
            if os.write(fd, line) != len(line):
                raise OSError('short audit write')
        finally:
            os.close(fd)
    finally:
        os.close(parent)


def append_event(path, event):
    event = dict(ts=datetime.now(timezone.utc).isoformat(timespec='milliseconds'), **event)
    if 'detail' in event:
        event['detail'] = redact(event['detail'])
    try:
        append(path, (json.dumps(event, ensure_ascii=True) + '\n').encode())
    except (OSError, ValueError):
        pass  # Audit is best effort.


def task_event(path, config, state, status, **fields):
    if config.get('AUDIT', 'summary') in ('0', 'off', 'false', 'no', 'NONE', 'none'):
        return
    if 'cmd' in fields:
        fields['cmd'] = redact(fields['cmd'])
    event = dict(kind='task', status=status, task_id=state['task_id'],
                 task_status=state['status'], distro=config['DISTRO'], **fields)
    if 'observation' in fields:
        event.pop('task_status')
    elif state.get('failure_reason'):
        event['failure_reason'] = state['failure_reason']
        event['detail'] = state['failure_reason']
    if 'protection' in state:
        event['protection'] = state['protection']
    if 'observation' not in fields and state['exit_code'] is not None:
        event['exit'] = state['exit_code']
    append_event(path, event)


if __name__ == '__main__':
    try:
        if len(sys.argv) == 4 and TASK_ID.fullmatch(sys.argv[2]):
            append_event(sys.argv[1], dict(kind='resources', status='ok',
                                          task_id=sys.argv[2], detail=sys.argv[3]))
        else:
            append(sys.argv[1], sys.stdin.buffer.read())
    except (OSError, ValueError):
        sys.exit(1)
