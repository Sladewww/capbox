#!/usr/bin/env python3
"""版本化的纯数据包锁；永不执行包管理器输出。"""
import argparse
import json
from pathlib import Path
import re
import sys

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
import i18n

if sys.version_info < (3, 10):
    print(i18n.t('pkglock.requires_python_3_10'), file=sys.stderr)
    sys.exit(5)


NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9.+_:-]*\Z')
VERSION = re.compile(r'[A-Za-z0-9][A-Za-z0-9.+_:~-]*\Z')


def installed(text, distro):
    result = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        if distro == 'alpine':
            match = re.fullmatch(r'(.+)-([0-9][^-]*-r[0-9]+)', line)
            if not match:
                raise ValueError(i18n.t('pkglock.cannot_parse_apk'))
            name, version = match.groups()
        else:
            fields = line.split('\t')
            if len(fields) != 3:
                raise ValueError(i18n.t('pkglock.cannot_parse_dpkg'))
            status, name, version = fields
            if status.strip() == 'rc':
                continue
            if status != 'ii ':
                raise ValueError(i18n.t('pkglock.package_not_configured', name=name))
        if not NAME.fullmatch(name) or not VERSION.fullmatch(version):
            raise ValueError(i18n.t('pkglock.invalid_name_or_version'))
        if name in result:
            raise ValueError(i18n.t('pkglock.duplicate_package', name=name))
        result[name] = version
    if not result:
        raise ValueError(i18n.t('pkglock.empty_inventory'))
    return result


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(i18n.t('pkglock.duplicate_key', field=key))
        result[key] = value
    return result


def load(path, distro, architecture):
    try:
        obj = json.loads(path.read_text(), object_pairs_hook=unique_pairs)
    except (ValueError, OSError) as exc:
        raise ValueError(i18n.t('pkglock.not_strict_lock')) from exc
    if not isinstance(obj, dict) or set(obj) != {'schema', 'distro', 'architecture', 'packages'}:
        raise ValueError(i18n.t('pkglock.fields_incomplete'))
    if type(obj['schema']) is not int or obj['schema'] != 1:
        raise ValueError(i18n.t('pkglock.unsupported_schema'))
    if obj['distro'] != distro or obj['architecture'] != architecture:
        raise ValueError(i18n.t('pkglock.distro_or_arch_mismatch'))
    packages = obj['packages']
    if not isinstance(packages, dict) or not packages or len(packages) > 20000:
        raise ValueError(i18n.t('pkglock.packages_must_be_nonempty_map'))
    for name, version in packages.items():
        if (not isinstance(name, str) or not isinstance(version, str)
                or not NAME.fullmatch(name) or not VERSION.fullmatch(version)):
            raise ValueError(i18n.t('pkglock.invalid_package_name_or_version'))
    return packages


def main():
    parser = i18n.I18nArgumentParser()
    parser.add_argument('action', choices=['save', 'validate', 'arguments', 'verify'])
    parser.add_argument('--distro', choices=['alpine', 'ubuntu'], required=True)
    parser.add_argument('--architecture', choices=['x86_64', 'aarch64'], required=True)
    parser.add_argument('file', type=Path)
    parser.add_argument('--require', action='append', default=[])
    args = parser.parse_args()
    if args.action == 'save':
        data = {'schema': 1, 'distro': args.distro, 'architecture': args.architecture,
                'packages': installed(sys.stdin.read(), args.distro)}
        print(json.dumps(data, sort_keys=True, indent=2))
        return
    packages = load(args.file, args.distro, args.architecture)
    for requested in args.require:
        name, separator, version = requested.partition('=')
        if name not in packages or (separator and packages[name] != version):
            raise ValueError(i18n.t('pkglock.cannot_satisfy_recipe', requested=requested))
    if args.action == 'arguments':
        for name, version in sorted(packages.items()):
            sys.stdout.buffer.write(f'{name}={version}'.encode() + b'\0')
    elif args.action == 'verify':
        actual = installed(sys.stdin.read(), args.distro)
        if actual != packages:
            missing = sorted(packages.keys() - actual.keys())
            extra = sorted(actual.keys() - packages.keys())
            mismatch = sorted(n for n in packages.keys() & actual.keys()
                              if packages[n] != actual[n])
            raise ValueError(i18n.t('pkglock.env_mismatch', missing=missing, extra=extra, mismatch=mismatch))
        print(i18n.t('pkglock.verify_ok'))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as exc:
        print(i18n.t('pkglock.failed', exc=exc), file=sys.stderr)
        sys.exit(2)
