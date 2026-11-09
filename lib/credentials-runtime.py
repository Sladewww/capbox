#!/usr/bin/env python3
"""Host credential store and guest placeholder preparation for CapBox.

Real secret values stay on the host under the private per-project state directory.
Guests only receive opaque placeholders; the restricted net proxy rewrites matching
HTTP(S) request headers for allowlisted domains. No OAuth browser flows and no OS
keychain requirement in v1 (file store 0700/0600). Header rewrite only — not body
or query string.
"""
from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

SCHEMA = 'capbox.credentials.v1'
PLACEHOLDER_PREFIX = 'capbox-sec-'
SERVICES_FILE = Path(__file__).with_name('credentials-services.json')


class CredError(Exception):
    def __init__(self, message: str, code: int = 1):
        super().__init__(message)
        self.code = code


def die(message: str, code: int = 1) -> None:
    print('[capbox] 错误:', message, file=sys.stderr)
    raise SystemExit(code)


def private_root() -> Path:
    raw = os.environ.get('CAPBOX_CRED_PRIVATE') or os.environ.get('CAPBOX_AGENT_PRIVATE')
    if not raw:
        die('缺少宿主私有目录上下文（CAPBOX_CRED_PRIVATE）', 5)
    path = Path(raw)
    st = path.lstat()
    if path.is_symlink() or not path.is_dir() or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        die('宿主凭据目录必须由当前用户拥有、权限 0700 且不是符号链接', 1)
    return path


def cred_dir() -> Path:
    root = private_root() / 'credentials'
    if not root.exists():
        root.mkdir(mode=0o700)
    st = root.lstat()
    if root.is_symlink() or not root.is_dir() or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        die('credentials 目录权限不安全', 1)
    for name in ('secrets', 'custom', 'sessions', 'ca'):
        sub = root / name
        if not sub.exists():
            sub.mkdir(mode=0o700)
    return root


def load_services() -> Dict[str, Any]:
    with SERVICES_FILE.open(encoding='utf-8') as fh:
        return json.load(fh)


def write_json(path: Path, value: Any) -> None:
    temporary = path.with_name(path.name + '.' + secrets.token_hex(8) + '.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        json.dump(value, fh, ensure_ascii=True, indent=2, sort_keys=True)
        fh.write('\n')
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(temporary, path)
    os.chmod(path, 0o600)


def read_json(path: Path) -> Any:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, encoding='utf-8') as fh:
        st = os.fstat(fh.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise CredError('凭据记录必须是普通文件')
        return json.load(fh)


def validate_host(host: str) -> str:
    host = (host or '').strip().lower().rstrip('.')
    if not host or len(host) > 253:
        raise CredError('无效 --host', 2)
    if host.startswith('*.'):
        base = host[2:]
        if '.' not in base or '*' in base or '/' in base or ':' in base:
            raise CredError('通配主机仅支持单标签 *.example.com', 2)
        return host
    if '*' in host or '/' in host or ':' in host or ' ' in host:
        raise CredError('主机名非法', 2)
    if not re.fullmatch(r'[a-z0-9]([a-z0-9.-]*[a-z0-9])?', host):
        raise CredError('主机名非法', 2)
    return host


def validate_env_name(name: str) -> str:
    if not re.fullmatch(r'[A-Z_][A-Z0-9_]{0,127}', name or ''):
        raise CredError('环境变量名非法', 2)
    return name


def read_secret_value(args: argparse.Namespace) -> Tuple[str, Optional[str]]:
    if getattr(args, 'command', None):
        return '', args.command
    if getattr(args, 'value_stdin', False):
        data = sys.stdin.buffer.read()
        if not data:
            raise CredError('stdin 为空', 2)
        return data.decode('utf-8', 'strict').rstrip('\n'), None
    if sys.stdin.isatty():
        value = getpass.getpass('Secret value: ')
        if not value:
            raise CredError('空密钥', 2)
        return value, None
    raise CredError('非交互环境请使用 --value-stdin 或 --command', 2)


def secret_path(kind: str, name: str) -> Path:
    root = cred_dir()
    if kind == 'service':
        return root / 'secrets' / (name + '.json')
    return root / 'custom' / (name + '.json')


def store_record(path: Path, record: Dict[str, Any]) -> None:
    write_json(path, record)
    print(json.dumps({'schema': SCHEMA, 'stored': path.stem, 'kind': record['kind'],
                      'env': record['env'], 'domains': record['domains'],
                      'placeholder_hint': PLACEHOLDER_PREFIX + '<32hex>'}, ensure_ascii=True))


def cmd_set(args: argparse.Namespace) -> int:
    services = load_services()
    if args.custom:
        if not args.host or not args.env:
            raise CredError('自定义密钥需要 --host 与 --env', 2)
        domains = [validate_host(h) for h in args.host]
        env_name = validate_env_name(args.env)
        value, command = read_secret_value(args)
        name = args.name or ('custom-' + hashlib.sha256(
            (env_name + '\0' + ','.join(domains)).encode()).hexdigest()[:12])
        if not re.fullmatch(r'[A-Za-z0-9._-]{1,64}', name):
            raise CredError('自定义密钥名非法', 2)
        record = {
            'schema': SCHEMA,
            'kind': 'custom',
            'name': name,
            'env': [env_name],
            'domains': domains,
            'header': args.header or 'Authorization',
            'format': args.format or 'Bearer %s',
            'value': value if command is None else None,
            'command': command,
            'refresh_seconds': 55 * 60 if command else None,
            'updated_at': time.time(),
        }
        store_record(secret_path('custom', name), record)
        return 0

    service = args.service
    if not service or service not in services:
        raise CredError('未知服务；可用: ' + ', '.join(sorted(services)), 2)
    meta = services[service]
    value, command = read_secret_value(args)
    record = {
        'schema': SCHEMA,
        'kind': 'service',
        'name': service,
        'env': list(meta['env']),
        'domains': list(meta['domains']),
        'header': meta.get('header', 'Authorization'),
        'format': meta.get('format', 'Bearer %s'),
        'value': value if command is None else None,
        'command': command,
        'refresh_seconds': 55 * 60 if command else None,
        'updated_at': time.time(),
    }
    store_record(secret_path('service', service), record)
    return 0


def iter_records() -> List[Dict[str, Any]]:
    root = cred_dir()
    out = []
    for folder, kind in ((root / 'secrets', 'service'), (root / 'custom', 'custom')):
        if not folder.is_dir():
            continue
        for path in sorted(folder.glob('*.json')):
            if path.is_symlink():
                continue
            try:
                rec = read_json(path)
            except (OSError, json.JSONDecodeError, CredError):
                continue
            if rec.get('kind') != kind:
                continue
            out.append(rec)
    return out


def cmd_ls(_args: argparse.Namespace) -> int:
    rows = []
    for rec in iter_records():
        preview = 'command' if rec.get('command') else 'stored'
        rows.append({
            'name': rec['name'],
            'kind': rec['kind'],
            'env': rec['env'],
            'domains': rec['domains'],
            'source': preview,
        })
    print(json.dumps({'schema': SCHEMA, 'secrets': rows}, ensure_ascii=True))
    return 0


def cmd_rm(args: argparse.Namespace) -> int:
    name = args.name
    removed = []
    for kind in ('service', 'custom'):
        path = secret_path(kind, name)
        if path.exists() and not path.is_symlink():
            path.unlink()
            removed.append(kind)
    if not removed:
        raise CredError('找不到密钥: ' + name, 2)
    print(json.dumps({'schema': SCHEMA, 'removed': name, 'kinds': removed}, ensure_ascii=True))
    return 0


def cmd_import(args: argparse.Namespace) -> int:
    services = load_services()
    targets = [args.service] if args.service else sorted(services)
    if args.service and args.service not in services:
        raise CredError('未知服务', 2)
    planned = []
    for name in targets:
        meta = services[name]
        value = None
        used = None
        for env_name in meta['env']:
            if env_name in os.environ and os.environ[env_name]:
                value = os.environ[env_name]
                used = env_name
                break
        if value is None:
            continue
        path = secret_path('service', name)
        exists = path.exists()
        if exists and not args.force:
            if not args.all:
                planned.append({'name': name, 'action': 'skip-exists', 'env': used})
            continue
        planned.append({'name': name, 'action': 'write', 'env': used})
        if args.dry_run:
            continue
        if not args.all and not args.force and sys.stdin.isatty():
            answer = input(f'Import {name} from {used}? [y/N] ').strip().lower()
            if answer not in ('y', 'yes'):
                planned[-1]['action'] = 'declined'
                continue
        record = {
            'schema': SCHEMA,
            'kind': 'service',
            'name': name,
            'env': list(meta['env']),
            'domains': list(meta['domains']),
            'header': meta.get('header', 'Authorization'),
            'format': meta.get('format', 'Bearer %s'),
            'value': value,
            'command': None,
            'refresh_seconds': None,
            'updated_at': time.time(),
            'imported_from': used,
        }
        write_json(path, record)
    print(json.dumps({'schema': SCHEMA, 'import': planned, 'dry_run': bool(args.dry_run)},
                     ensure_ascii=True))
    return 0


def resolve_secret(record: Dict[str, Any], cache: Dict[str, Tuple[str, float]]) -> str:
    name = record['name']
    if record.get('command'):
        now = time.time()
        hit = cache.get(name)
        refresh = record.get('refresh_seconds') or 0
        if hit and (refresh <= 0 or now - hit[1] < refresh):
            return hit[0]
        # Dynamic sources run on the host only; never mount this into the guest.
        proc = subprocess.run(
            ['/bin/bash', '-c', record['command']],
            capture_output=True, text=True, timeout=30,
            cwd=temp_safe_dir(),
            env={k: os.environ[k] for k in ('PATH', 'HOME', 'LANG', 'XDG_RUNTIME_DIR') if k in os.environ},
        )
        if proc.returncode != 0:
            raise CredError(f'动态密钥命令失败: {name}', 1)
        value = proc.stdout.strip()
        if not value:
            raise CredError(f'动态密钥命令无输出: {name}', 1)
        if refresh > 0:
            cache[name] = (value, now)
        return value
    value = record.get('value')
    if not value:
        raise CredError(f'密钥无值: {name}', 1)
    return value


def temp_safe_dir() -> str:
    base = Path(os.environ.get('TMPDIR') or '/tmp')
    path = base / ('capbox-cred-' + secrets.token_hex(8))
    path.mkdir(mode=0o700)
    return str(path)


def host_match(host: str, pattern: str) -> bool:
    host = host.lower().rstrip('.')
    pattern = pattern.lower().rstrip('.')
    if pattern.startswith('*.'):
        base = pattern[2:]
        return host.endswith('.' + base) and host != base
    return host == pattern


def allowlist_covers(domain: str, allow: List[str]) -> bool:
    for rule in allow:
        rule_host = rule.split(':', 1)[0].strip().lower()
        if host_match(domain, rule_host) or host_match(domain, rule_host.lstrip('*.')):
            # Also accept exact / wildcard allow rules via same single-label wildcard.
            if rule_host.startswith('*.'):
                if host_match(domain, rule_host):
                    return True
            elif domain == rule_host or domain.endswith('.' + rule_host):
                # CapBox NET_ALLOW exact host match (no automatic subdomain unless *. used).
                if domain == rule_host:
                    return True
        if domain == rule_host:
            return True
        if rule_host.startswith('*.') and host_match(domain, rule_host):
            return True
    return False


def placeholder() -> str:
    return PLACEHOLDER_PREFIX + secrets.token_hex(16)


def ensure_mitm_ca(ca_dir: Path) -> Tuple[Path, Path]:
    """Create a project-local MITM CA for credential HTTPS rewrite (host-only)."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    import datetime as dt

    key_path = ca_dir / 'ca.key'
    cert_path = ca_dir / 'ca.crt'
    if key_path.exists() and cert_path.exists() and not key_path.is_symlink() and not cert_path.is_symlink():
        return key_path, cert_path
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, u'CapBox Credential Proxy CA'),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, u'CapBox Local'),
    ])
    now = dt.datetime.now(dt.timezone.utc)
    ski = x509.SubjectKeyIdentifier.from_public_key(key.public_key())
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=5))
        .not_valid_after(now + dt.timedelta(days=825))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True, key_cert_sign=True, crl_sign=True,
                content_commitment=False, key_encipherment=False, data_encipherment=False,
                key_agreement=False, encipher_only=False, decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(ski, critical=False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()), critical=False)
        .sign(key, hashes.SHA256())
    )
    write_bytes = lambda p, data, mode: (
        os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode),
    )
    for path, data, mode in (
        (key_path, key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption()), 0o600),
        (cert_path, cert.public_bytes(serialization.Encoding.PEM), 0o600),
    ):
        if path.exists():
            path.unlink()
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
        with os.fdopen(fd, 'wb') as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
    return key_path, cert_path


def cmd_prepare(args: argparse.Namespace) -> int:
    """Prepare inject map + guest placeholder env for a restricted launch."""
    allow = [p.strip() for p in (args.allow or '').split(',') if p.strip()]
    if not allow:
        print(json.dumps({'schema': SCHEMA, 'active': False, 'reason': 'empty-allow'}, ensure_ascii=True))
        return 0
    records = iter_records()
    if not records:
        print(json.dumps({'schema': SCHEMA, 'active': False, 'reason': 'no-secrets'}, ensure_ascii=True))
        return 0
    inject: Dict[str, Any] = {'schema': SCHEMA, 'entries': []}
    guest_env: Dict[str, str] = {}
    skipped = []
    cache: Dict[str, Tuple[str, float]] = {}
    needs_mitm = False
    for rec in records:
        domains = [d for d in rec['domains'] if allowlist_covers(d, allow)]
        if not domains:
            skipped.append({'name': rec['name'], 'reason': 'domains-not-in-NET_ALLOW'})
            continue
        # Resolve once at prepare time for static values; commands resolved by proxy on demand.
        entry = {
            'name': rec['name'],
            'kind': rec['kind'],
            'env': rec['env'],
            'domains': domains,
            'header': rec.get('header', 'Authorization'),
            'format': rec.get('format', 'Bearer %s'),
            'command': rec.get('command'),
            'refresh_seconds': rec.get('refresh_seconds'),
            'placeholders': {},
        }
        if rec.get('command'):
            entry['value'] = None
        else:
            entry['value'] = resolve_secret(rec, cache)
        for env_name in rec['env']:
            token = placeholder()
            guest_env[env_name] = token
            entry['placeholders'][env_name] = token
        inject['entries'].append(entry)
        needs_mitm = True
    if not inject['entries']:
        print(json.dumps({'schema': SCHEMA, 'active': False, 'skipped': skipped}, ensure_ascii=True))
        return 0
    session = args.session or secrets.token_hex(8)
    root = cred_dir()
    session_dir = root / 'sessions' / session
    if session_dir.exists():
        shutil.rmtree(session_dir)
    session_dir.mkdir(mode=0o700)
    inject_path = session_dir / 'inject.json'
    env_path = session_dir / 'guest.env'
    write_json(inject_path, inject)
    # guest.env is NAME=placeholder lines only — never real secrets.
    fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        for key in sorted(guest_env):
            fh.write(f'{key}={guest_env[key]}\n')
    ca_cert = None
    if needs_mitm:
        key_path, cert_path = ensure_mitm_ca(root / 'ca')
        ca_cert = str(cert_path)
        # Bundle path for guest trust (system certs + CapBox CA) assembled by shell.
        inject['ca_cert'] = ca_cert
        inject['ca_key'] = str(key_path)
        write_json(inject_path, inject)
    result = {
        'schema': SCHEMA,
        'active': True,
        'session': session,
        'inject_map': str(inject_path),
        'guest_env_file': str(env_path),
        'ca_cert': ca_cert,
        'placeholders': guest_env,
        'skipped': skipped,
    }
    print(json.dumps(result, ensure_ascii=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog='capbox secret')
    sub = p.add_subparsers(dest='action', required=True)

    set_p = sub.add_parser('set', help='存储服务或自定义密钥（真实值仅在宿主）')
    set_p.add_argument('service', nargs='?', help='内置服务名（openai/anthropic/…）')
    set_p.add_argument('--custom', action='store_true')
    set_p.add_argument('--host', action='append', default=[])
    set_p.add_argument('--env')
    set_p.add_argument('--name')
    set_p.add_argument('--header')
    set_p.add_argument('--format')
    set_p.add_argument('--value-stdin', action='store_true')
    set_p.add_argument('--command')
    set_p.set_defaults(func=cmd_set)

    ls_p = sub.add_parser('ls')
    ls_p.set_defaults(func=cmd_ls)

    rm_p = sub.add_parser('rm')
    rm_p.add_argument('name')
    rm_p.set_defaults(func=cmd_rm)

    im_p = sub.add_parser('import')
    im_p.add_argument('service', nargs='?')
    im_p.add_argument('--all', action='store_true')
    im_p.add_argument('--force', action='store_true')
    im_p.add_argument('--dry-run', action='store_true')
    im_p.set_defaults(func=cmd_import)

    prep = sub.add_parser('prepare', help='内部：为 restricted 启动生成占位符与 inject map')
    prep.add_argument('--allow', required=True)
    prep.add_argument('--session')
    prep.set_defaults(func=cmd_prepare)
    return p


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args) or 0)
    except CredError as exc:
        die(str(exc), exc.code)
        return exc.code


if __name__ == '__main__':
    sys.exit(main())
