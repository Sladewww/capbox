#!/usr/bin/env python3
"""A versioned, data-only package lock; never execute package-manager output."""
import argparse
import json
from pathlib import Path
import re
import sys

if sys.version_info < (3, 10):
    print('[capbox] 此功能需要宿主 Python 3.10 或更新版本', file=sys.stderr)
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
                raise ValueError('无法解析 apk 已安装包清单')
            name, version = match.groups()
        else:
            fields = line.split('\t')
            if len(fields) != 3:
                raise ValueError('无法解析 dpkg 已安装包清单')
            status, name, version = fields
            if status.strip() == 'rc':
                continue
            if status != 'ii ':
                raise ValueError(f'包 {name} 尚未完成配置')
        if not NAME.fullmatch(name) or not VERSION.fullmatch(version):
            raise ValueError('包清单中存在无效名称或版本')
        if name in result:
            raise ValueError(f'重复包名: {name}')
        result[name] = version
    if not result:
        raise ValueError('包清单为空，拒绝生成或验证锁文件')
    return result


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'包锁包含重复键: {key}')
        result[key] = value
    return result


def load(path, distro, architecture):
    try:
        obj = json.loads(path.read_text(), object_pairs_hook=unique_pairs)
    except (ValueError, OSError) as exc:
        raise ValueError('不是有效的严格包锁；旧版清单请重新 image lock save') from exc
    if not isinstance(obj, dict) or set(obj) != {'schema', 'distro', 'architecture', 'packages'}:
        raise ValueError('包锁字段不完整或包含未知字段')
    if type(obj['schema']) is not int or obj['schema'] != 1:
        raise ValueError('不支持的包锁 schema')
    if obj['distro'] != distro or obj['architecture'] != architecture:
        raise ValueError('包锁发行版或架构与目标环境不一致')
    packages = obj['packages']
    if not isinstance(packages, dict) or not packages or len(packages) > 20000:
        raise ValueError('包锁 packages 必须是非空包版本映射')
    for name, version in packages.items():
        if (not isinstance(name, str) or not isinstance(version, str)
                or not NAME.fullmatch(name) or not VERSION.fullmatch(version)):
            raise ValueError('包锁包含无效包名或版本')
    return packages


def main():
    parser = argparse.ArgumentParser()
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
            raise ValueError(f'包锁不能满足配方中的包要求: {requested}')
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
            raise ValueError(f'环境与包锁不一致：缺失 {missing}，额外 {extra}，版本差异 {mismatch}')
        print('OK package.lock')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as exc:
        print(f'[capbox] 包锁失败: {exc}', file=sys.stderr)
        sys.exit(2)
