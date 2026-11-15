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
from audit_store import TASK_ID, TASK_STATES, parent_fd, policy_summary, redact

SCHEMA = 'capbox.audit-report.v1'
MAX_SCAN = 32 * 1024 * 1024
MAX_LINE = 64 * 1024
MAX_PAYLOAD = 32 * 1024 * 1024
STRING_FIELDS = ('object', 'cmd', 'detail', 'profile', 'net', 'uid', 'distro')

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
    task_id, task_status = data.get('task_id'), data.get('task_status')
    if isinstance(task_id, str) and TASK_ID.fullmatch(task_id):
        event['task_id'] = task_id
        if event['kind'] == 'task' and isinstance(task_status, str) and task_status in TASK_STATES:
            event['task_status'] = task_status
            reason = data.get('failure_reason')
            if reason in ('launch_failed', 'execution_timeout', 'cancelled', 'nonzero_exit'):
                event['failure_reason'] = reason
            protection = data.get('protection')
            if isinstance(protection, dict):
                status = protection.get('status')
                if status in ('pending', 'verified', 'failed'):
                    proof = {'status': status}
                    for key in ('requested', 'effective'):
                        if key in protection:
                            proof[key] = policy_summary(protection[key])
                    check = protection.get('check')
                    if isinstance(check, str) and re.fullmatch(r'[a-z0-9_]{1,64}', check):
                        proof['check'] = check
                    checks = protection.get('checks')
                    if isinstance(checks, dict):
                        proof['checks'] = {
                            k: v for k, v in checks.items()
                            if re.fullmatch(r'[a-z0-9_]{1,64}', k)
                            and (type(v) is bool or type(v) is int
                                 or isinstance(v, str) and re.fullmatch(r'[A-Za-z0-9_. -]{1,64}', v))
                        }
                    event['protection'] = proof
            if task_status == 'preparing':
                event['policy'] = policy_summary(data.get('policy'))
                if type(data.get('isolated')) is bool:
                    event['isolated'] = data['isolated']
    elif task_id is not None:
        counters['invalid_fields'] += 1
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
    task = {'task_id': args.task_id} if args.task_id else None
    parent = None
    try:
        parent, name = parent_fd(path)
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except FileNotFoundError:
        if args.input:
            raise
        counters.update(source_missing=True, source_bytes=0, omitted_records=0)
        return [], counters, task
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
            if task is not None:
                if event.get('task_id') != args.task_id:
                    continue
                if 'task_status' in event:
                    task['status'] = event['task_status']
                    task['exit_code'] = event.get('exit')
                    if 'failure_reason' in event:
                        task['failure_reason'] = event['failure_reason']
                    for key in ('policy', 'isolated', 'protection'):
                        if key in event:
                            task[key] = event[key]
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
    return sorted(records, key=lambda event: (event['time'], event['id'])), counters, task


def enrich_task(task, private):
    if not private or 'status' not in task:
        return
    # agent-runtime.py is also the task CLI. Load it only for a local task query.
    import importlib.util
    spec = importlib.util.spec_from_file_location('capbox_agent_runtime',
                                                  Path(__file__).with_name('agent-runtime.py'))
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    try:
        job = runtime.job_path(runtime.private_dir(Path(private) / 'tasks'), task['task_id'])
        state = runtime.state_of(job)
        if state['status'] == 'lost' and task['status'] not in runtime.FINISHED:
            task.update(status='lost', exit_code=state['exit_code'])
        if not state['isolated'] or state['status'] not in runtime.FINISHED:
            return
        summary, _ = runtime.diff_summary(job)
    except (OSError, ValueError, KeyError, runtime.AgentError):
        return
    task['diff'] = {key: [redact(path)[:2048] for path in paths]
                    for key, paths in summary.items()}


def html_escape(value):
    return (value.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;'))


def ui_strings(catalog):
    return {key[len('audit.html.'):]: value
            for key, value in catalog.items() if key.startswith('audit.html.')}


def stamp_template(template, catalog):
    template = template.replace('@@HTML_LANG@@', html_escape(i18n.get(catalog, 'audit.html.locale')))

    def stamp(match):
        return html_escape(i18n.get(catalog, match.group(1)))

    template = re.sub(r'@@(audit\.html\.[A-Za-z0-9_]+)@@', stamp, template)
    encoded = json.dumps(ui_strings(catalog), ensure_ascii=True, allow_nan=False, separators=(',', ':'))
    encoded = encoded.replace('<', r'\u003c').replace('>', r'\u003e').replace('&', r'\u0026')
    if template.count('@@I18N@@') != 1:
        raise ValueError(i18n.t('audit.report_template_incomplete'))
    return template.replace('@@I18N@@', encoded)


def render(document):
    template = Path(__file__).with_suffix('.html').read_text()
    template = stamp_template(template, i18n.catalog_for(i18n.resolve_lang()))
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
    argv = sys.argv[1:]
    action = argv.pop(0) if argv and argv[0] in ('query', 'report') else 'report'
    query = action == 'query'
    parser = i18n.I18nArgumentParser(prog='capbox audit ' + action,
                                     description=i18n.t('audit.query_description' if query else 'audit.report_description'))
    parser.add_argument('--task-id', required=query, help=i18n.t('audit.help_task_id'))
    if not query:
        parser.add_argument('--output', required=True, help=i18n.t('audit.help_output'))
        parser.add_argument('--force', action='store_true', help=i18n.t('audit.help_force'))
        parser.add_argument('--json', action='store_true', help=i18n.t('audit.help_json'))
    parser.add_argument('--input', help=i18n.t('audit.help_input'))
    parser.add_argument('--limit', type=int, default=5000, help=i18n.t('audit.help_limit'))
    parser.add_argument('--since', help=i18n.t('audit.help_since'))
    parser.add_argument('--until', help=i18n.t('audit.help_until'))
    parser.add_argument('--kind', action='append', help=i18n.t('audit.help_kind'))
    parser.add_argument('--status', action='append', help=i18n.t('audit.help_status'))
    args = parser.parse_args(argv)
    if args.task_id is not None and not TASK_ID.fullmatch(args.task_id):
        parser.error(i18n.t('task.invalid_task_id'))
    if not 1 <= args.limit <= 20000:
        parser.error(i18n.t('audit.limit_must_be_1_20000'))
    args.since = round(utc(args.since, date_only=True).timestamp() * 1000) if args.since else None
    args.until = round(utc(args.until, date_only=True).timestamp() * 1000) if args.until else None
    if args.since is not None and args.until is not None and args.since >= args.until:
        parser.error(i18n.t('audit.since_must_precede_until'))
    source = Path(args.input or os.environ['CAPBOX_AUDIT_REPORT_SOURCE']).absolute()
    workspace = Path(os.environ['CAPBOX_AUDIT_REPORT_WORKSPACE']).resolve()
    events, counters, task = snapshot(source, args)
    source_identity = counters.pop('_source_identity', None)
    document = dict(schema=SCHEMA, generated_at=datetime.now(timezone.utc).isoformat(),
                    project=workspace.name, source=source.name, events=events,
                    coverage=dict(counters, retained_events=len(events), limit=args.limit, max_scan_bytes=MAX_SCAN,
                                  filters=dict(since=args.since, until=args.until, kind=args.kind, status=args.status)))
    if task is not None:
        if not args.input:
            enrich_task(task, os.environ.get('CAPBOX_AUDIT_REPORT_PRIVATE'))
        document['task'] = task
        document['coverage']['filters']['task_id'] = args.task_id
    if query:
        encoded = json.dumps(document, ensure_ascii=True, allow_nan=False)
        if len(encoded) > MAX_PAYLOAD:
            raise ValueError(i18n.t('audit.report_data_exceeds_32mib'))
        print(encoded)
        return 0
    destination = Path(args.output).absolute()
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
