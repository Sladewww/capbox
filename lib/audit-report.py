#!/usr/bin/env python3
"""Bounded audit snapshots rendered as a self-contained, read-only HTML report."""
import argparse
import base64
from collections import deque
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import uuid

SCHEMA = 'capbox.audit-report.v1'
MAX_SCAN = 32 * 1024 * 1024
MAX_LINE = 64 * 1024
MAX_PAYLOAD = 32 * 1024 * 1024
STRING_FIELDS = ('object', 'cmd', 'detail', 'profile', 'net', 'uid', 'distro')
SENSITIVE = (r'(?:[A-Za-z][A-Za-z0-9_-]{0,80}[_-])?'
             r'(?:password|passwd|pwd|token|secret|api[_-]?key|authorization|access[_-]?token|'
             r'client[_-]?secret|secret[_-]?access[_-]?key|access[_-]?key(?:[_-]?id)?|private[_-]?key)')


def utc(value, *, date_only=False):
    if not isinstance(value, str) or len(value) > 80:
        raise ValueError('时间必须为 ISO 8601 格式')
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        if not date_only or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
            raise ValueError('时间必须包含时区，例如 2026-11-08T00:00:00Z')
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('重复 JSON 键')
        result[key] = value
    return result


def integer(value):
    if len(value) > 20:
        raise ValueError('整数过长')
    return int(value)


def constant(_value):
    raise ValueError('非 JSON 数值')


def redact(value):
    value = re.sub(r'(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+', r'\1 [REDACTED]', value)
    value = re.sub(r'(?i)(https?://)[^\s/@]+@', r'\1[REDACTED]@', value)
    pattern = r'(?i)(\b' + SENSITIVE + r'\b[\s\"\x27]*[=:][\s]*)(?:\"[^\"]*\"|\x27[^\x27]*\x27|[^\s&;,]+)'
    value = re.sub(pattern, r'\1[REDACTED]', value)
    pattern = r'(?i)(--?' + SENSITIVE + r'\s+)(?:\"[^\"]*\"|\x27[^\x27]*\x27|[^\s]+)'
    return re.sub(pattern, r'\1[REDACTED]', value)


def parent_fd(path):
    """Pin each directory without following guest-writable symlink ancestors."""
    path = Path(os.path.abspath(path))
    if not path.name:
        raise ValueError('必须指定文件名')
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


def normalise(data, number, counters):
    if not isinstance(data, dict):
        raise ValueError('记录不是对象')
    timestamp = utc(data.get('ts'))
    for key, limit in (('kind', 64), ('status', 64)):
        value = data.get(key)
        if not isinstance(value, str) or not value.strip() or len(value) > limit:
            raise ValueError('记录缺少类型或状态')
    event = dict(id=number, ts=timestamp.isoformat(timespec='milliseconds').replace('+00:00', 'Z'),
                 time=round(timestamp.timestamp() * 1000), kind=data['kind'], status=data['status'])
    for key in STRING_FIELDS:
        value = data.get(key)
        if value is None:
            continue
        if not isinstance(value, str):
            counters['invalid_fields'] += 1
            continue
        clean = redact(value)
        if clean != value:
            counters['redacted_fields'] += 1
        if len(clean) > 2048:
            counters['truncated_fields'] += 1
            clean = clean[:2048] + '… [字段已截断]'
        event[key] = clean
    for key in ('exit', 'ms'):
        value = data.get(key)
        if value is None:
            continue
        valid = (type(value) in (int, float) and math.isfinite(value) and abs(value) <= 10**15
                 and (key != 'ms' or value >= 0) and (key != 'exit' or int(value) == value))
        if valid:
            event[key] = int(value) if key == 'exit' else value
        else:
            counters['invalid_fields'] += 1
    return event


def snapshot(path, args):
    counters = dict(valid_records=0, matching_records=0, invalid_records=0, oversized_records=0,
                    incomplete_records=0, blank_lines=0, invalid_fields=0, redacted_fields=0,
                    truncated_fields=0, scanned_bytes=0, omitted_prefix_bytes=0, source_missing=False)
    records = deque(maxlen=args.limit)
    parent = None
    try:
        parent, name = parent_fd(path)
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except FileNotFoundError:
        if args.input:
            raise
        counters.update(source_missing=True, source_bytes=0, omitted_records=0)
        return [], counters
    finally:
        if parent is not None:
            os.close(parent)
    with os.fdopen(fd, 'rb') as incoming:
        info = os.fstat(incoming.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('审计源必须是普通文件')
        counters['source_bytes'] = info.st_size
        counters['_source_identity'] = (info.st_dev, info.st_ino)
        start = max(0, info.st_size - MAX_SCAN)
        incoming.seek(start)
        remaining = info.st_size - start

        def line():
            nonlocal remaining
            data = incoming.readline(min(MAX_LINE + 1, remaining)) if remaining else b''
            remaining -= len(data)
            counters['scanned_bytes'] += len(data)
            return data

        if start:
            # The first fragment may belong to an earlier record; omit it.
            fragment = line()
            start += len(fragment)
            while fragment and not fragment.endswith(b'\n'):
                fragment = line()
                start += len(fragment)
        counters['omitted_prefix_bytes'] = start
        number = 0
        while remaining:
            raw = line()
            if not raw:
                break
            number += 1
            if len(raw) > MAX_LINE:
                counters['oversized_records'] += 1
                while raw and not raw.endswith(b'\n'):
                    raw = line()
                continue
            if not raw.endswith(b'\n'):
                counters['incomplete_records'] += 1
                continue
            if not raw.strip():
                counters['blank_lines'] += 1
                continue
            try:
                data = json.loads(raw.decode('utf-8'), object_pairs_hook=unique,
                                  parse_int=integer, parse_constant=constant)
                event = normalise(data, number, counters)
            except (ValueError, UnicodeError, TypeError, OverflowError, RecursionError):
                counters['invalid_records'] += 1
                continue
            counters['valid_records'] += 1
            if args.since is not None and event['time'] < args.since:
                continue
            if args.until is not None and event['time'] >= args.until:
                continue
            if args.kind and event['kind'] not in args.kind:
                continue
            if args.status and event['status'] not in args.status:
                continue
            counters['matching_records'] += 1
            records.append(event)
    counters['omitted_records'] = counters['matching_records'] - len(records)
    return sorted(records, key=lambda event: (event['time'], event['id'])), counters


def render(document):
    template = Path(__file__).with_suffix('.html').read_text()
    for tag, directive in (('style', 'STYLE'), ('script', 'SCRIPT')):
        blocks = re.findall(r'<' + tag + r' data-app>(.*?)</' + tag + '>', template, re.S)
        if len(blocks) != 1:
            raise ValueError('报告模板不完整')
        digest = base64.b64encode(hashlib.sha256(blocks[0].encode()).digest()).decode()
        template = template.replace('@@' + directive + '_HASH@@', digest)
    encoded = json.dumps(document, ensure_ascii=True, allow_nan=False, separators=(',', ':'))
    # Inert JSON must never be allowed to close its script element.
    encoded = encoded.replace('<', r'\u003c').replace('>', r'\u003e').replace('&', r'\u0026')
    if len(encoded) > MAX_PAYLOAD:
        raise ValueError('报告数据超过 32MiB，请缩小 --limit 或时间范围')
    if template.count('@@DATA@@') != 1:
        raise ValueError('报告模板不完整')
    return template.replace('@@DATA@@', encoded).encode()


def publish(path, workspace, payload, force, source_identity):
    parent, name = parent_fd(path)
    temporary = '.capbox-audit-' + uuid.uuid4().hex
    try:
        actual = Path(os.readlink('/proc/self/fd/' + str(parent)))
        if actual.is_relative_to(workspace):
            raise ValueError('报告必须导出到工作区之外，避免 guest 改写报告')
        try:
            existing = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None:
            if (existing.st_dev, existing.st_ino) == source_identity:
                raise ValueError('输出不能覆盖审计源文件或其硬链接')
            if not force:
                raise ValueError('输出已存在；确认替换普通报告文件时使用 --force')
            if not stat.S_ISREG(existing.st_mode) or existing.st_uid != os.getuid():
                raise ValueError('只能替换当前用户拥有的普通文件')
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        with os.fdopen(fd, 'wb') as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        if force:
            os.replace(temporary, name, src_dir_fd=parent, dst_dir_fd=parent)
        else:
            os.link(temporary, name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
            os.unlink(temporary, dir_fd=parent)
        os.fsync(parent)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def main():
    parser = argparse.ArgumentParser(prog='capbox audit report', description='导出可搜索、筛选的离线 HTML 审计报告，不启动服务')
    parser.add_argument('--output', required=True, help='工作区外的 HTML 文件；父目录必须已存在')
    parser.add_argument('--input', help='显式读取其它普通 JSONL 审计文件；默认当前项目 logs/audit.jsonl')
    parser.add_argument('--limit', type=int, default=5000, help='保留扫描区域内最后 N 条匹配记录（1–20000，默认 5000）')
    parser.add_argument('--since', help='起始时间（包含）；ISO 8601 时区或 UTC 日期')
    parser.add_argument('--until', help='结束时间（不包含）；ISO 8601 时区或 UTC 日期')
    parser.add_argument('--kind', action='append', help='只导出此类型，可重复')
    parser.add_argument('--status', action='append', help='只导出此状态，可重复')
    parser.add_argument('--force', action='store_true', help='原子替换当前用户已有的普通输出文件')
    parser.add_argument('--json', action='store_true', help='输出机器可读的生成结果')
    args = parser.parse_args()
    if not 1 <= args.limit <= 20000:
        parser.error('--limit 必须是 1–20000')
    args.since = round(utc(args.since, date_only=True).timestamp() * 1000) if args.since else None
    args.until = round(utc(args.until, date_only=True).timestamp() * 1000) if args.until else None
    if args.since is not None and args.until is not None and args.since >= args.until:
        parser.error('--since 必须早于 --until')
    source = Path(args.input or os.environ['CAPBOX_AUDIT_REPORT_SOURCE']).absolute()
    workspace = Path(os.environ['CAPBOX_AUDIT_REPORT_WORKSPACE']).resolve()
    destination = Path(args.output).absolute()
    events, counters = snapshot(source, args)
    source_identity = counters.pop('_source_identity', None)
    document = dict(schema=SCHEMA, generated_at=datetime.now(timezone.utc).isoformat(),
                    project=workspace.name, source=source.name, events=events,
                    coverage=dict(counters, retained_events=len(events), limit=args.limit, max_scan_bytes=MAX_SCAN,
                                  filters=dict(since=args.since, until=args.until, kind=args.kind, status=args.status)))
    publish(destination, workspace, render(document), args.force, source_identity)
    result = dict(schema=SCHEMA, path=str(destination), events=len(events), coverage=document['coverage'])
    print(json.dumps(result, ensure_ascii=True) if args.json else '已生成审计报告: %s（%d 条事件）' % (destination, len(events)))
    return 0


if __name__ == '__main__':
    if sys.version_info < (3, 10):
        print('[capbox] 审计报告需要宿主 Python 3.10+', file=sys.stderr)
        sys.exit(5)
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, OverflowError) as error:
        print('[capbox] 审计报告失败: ' + str(error), file=sys.stderr)
        sys.exit(1)
