#!/usr/bin/env python3
"""将有界审计快照渲染为自包含、只读的 HTML 报告。"""
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

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
import i18n

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
        raise ValueError(i18n.t('audit.time_must_be_iso8601'))
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        if not date_only or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
            raise ValueError(i18n.t('audit.time_must_include_timezone'))
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(i18n.t('audit.duplicate_json_key'))
        result[key] = value
    return result


def integer(value):
    if len(value) > 20:
        raise ValueError(i18n.t('audit.integer_too_long'))
    return int(value)


def constant(_value):
    raise ValueError(i18n.t('audit.not_a_json_number'))


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


def normalise(data, number, counters):
    if not isinstance(data, dict):
        raise ValueError(i18n.t('audit.record_not_an_object'))
    timestamp = utc(data.get('ts'))
    for key, limit in (('kind', 64), ('status', 64)):
        value = data.get(key)
        if not isinstance(value, str) or not value.strip() or len(value) > limit:
            raise ValueError(i18n.t('audit.record_missing_type_or_status'))
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
            clean = clean[:2048] + i18n.t('audit.field_truncated')
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
            raise ValueError(i18n.t('audit.source_must_be_regular_file'))
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
            # 首段碎片可能属于更早的记录；丢弃它。
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
            raise ValueError(i18n.t('audit.report_template_incomplete'))
        digest = base64.b64encode(hashlib.sha256(blocks[0].encode()).digest()).decode()
        template = template.replace('@@' + directive + '_HASH@@', digest)
    encoded = json.dumps(document, ensure_ascii=True, allow_nan=False, separators=(',', ':'))
    # 惰性 JSON 绝不能关闭其 script 元素。
    encoded = encoded.replace('<', r'\u003c').replace('>', r'\u003e').replace('&', r'\u0026')
    if len(encoded) > MAX_PAYLOAD:
        raise ValueError(i18n.t('audit.report_data_exceeds_32mib'))
    if template.count('@@DATA@@') != 1:
        raise ValueError(i18n.t('audit.report_template_incomplete'))
    return template.replace('@@DATA@@', encoded).encode()


def publish(path, workspace, payload, force, source_identity):
    parent, name = parent_fd(path)
    temporary = '.capbox-audit-' + uuid.uuid4().hex
    try:
        actual = Path(os.readlink('/proc/self/fd/' + str(parent)))
        if actual.is_relative_to(workspace):
            raise ValueError(i18n.t('audit.report_must_be_outside_workspace'))
        try:
            existing = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None:
            if (existing.st_dev, existing.st_ino) == source_identity:
                raise ValueError(i18n.t('audit.output_cannot_overwrite_source'))
            if not force:
                raise ValueError(i18n.t('audit.output_exists_use_force'))
            if not stat.S_ISREG(existing.st_mode) or existing.st_uid != os.getuid():
                raise ValueError(i18n.t('audit.can_only_replace_own_regular_file'))
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
    parser = i18n.I18nArgumentParser(prog='capbox audit report', description=i18n.t('audit.report_description'))
    parser.add_argument('--output', required=True, help=i18n.t('audit.help_output'))
    parser.add_argument('--input', help=i18n.t('audit.help_input'))
    parser.add_argument('--limit', type=int, default=5000, help=i18n.t('audit.help_limit'))
    parser.add_argument('--since', help=i18n.t('audit.help_since'))
    parser.add_argument('--until', help=i18n.t('audit.help_until'))
    parser.add_argument('--kind', action='append', help=i18n.t('audit.help_kind'))
    parser.add_argument('--status', action='append', help=i18n.t('audit.help_status'))
    parser.add_argument('--force', action='store_true', help=i18n.t('audit.help_force'))
    parser.add_argument('--json', action='store_true', help=i18n.t('audit.help_json'))
    args = parser.parse_args()
    if not 1 <= args.limit <= 20000:
        parser.error(i18n.t('audit.limit_must_be_1_20000'))
    args.since = round(utc(args.since, date_only=True).timestamp() * 1000) if args.since else None
    args.until = round(utc(args.until, date_only=True).timestamp() * 1000) if args.until else None
    if args.since is not None and args.until is not None and args.since >= args.until:
        parser.error(i18n.t('audit.since_must_precede_until'))
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
    print(json.dumps(result, ensure_ascii=True) if args.json else i18n.t('audit.report_generated', path=destination, count=len(events)))
    return 0


if __name__ == '__main__':
    if sys.version_info < (3, 10):
        print(i18n.t('audit.report_requires_python_3_10'), file=sys.stderr)
        sys.exit(5)
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, OverflowError) as error:
        print(i18n.t('audit.report_failed', error=error), file=sys.stderr)
        sys.exit(1)
