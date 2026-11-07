#!/usr/bin/env python3
"""Stage, verify and recover a stopped project's bin/lib without touching its data.

The journal and backups live outside the workspace. Each rename is same-filesystem;
completed steps can be reversed after interruption. Existing processes must be stopped.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import uuid

if sys.version_info < (3, 10):
    print('[capbox] 此功能需要宿主 Python 3.10 或更新版本', file=sys.stderr)
    sys.exit(5)


PARTS = ('bin', 'lib')


def real_directory(path: Path) -> Path:
    # Resolve only after rejecting links, including parent components.
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError(f'拒绝符号链接目录: {part}')
    if not path.is_dir():
        raise ValueError(f'目录不存在: {path}')
    return path.resolve()


def inventory(root: Path) -> dict[str, str]:
    result = {}
    for part in PARTS:
        real_directory(root / part)
        for folder, dirs, files in os.walk(root / part):
            for name in dirs + files:
                path = Path(folder) / name
                if path.is_symlink():
                    raise ValueError(f'运行文件不能是符号链接: {path}')
            for name in files:
                path = Path(folder) / name
                if not path.is_file():
                    raise ValueError(f'运行目录只接受普通文件: {path}')
                # Python bytecode is local cache, not part of a runtime bundle.
                if '__pycache__' in path.parts or path.suffix == '.pyc':
                    continue
                mode = stat.S_IMODE(path.stat().st_mode) & 0o111
                result[str(path.relative_to(root))] = (
                    hashlib.sha256(path.read_bytes()).hexdigest() + f':{mode:o}')
    if 'bin/capbox' not in result or 'lib/common.sh' not in result:
        raise ValueError('模板缺少 bin/capbox 或 lib/common.sh')
    return result


def version(root: Path) -> str:
    for name in ('lib/version.sh', 'lib/common.sh'):
        path = root / name
        if path.is_file():
            match = re.search(r'^readonly CAPBOX_VERSION="([0-9A-Za-z.+-]+)"$',
                              path.read_text(), re.M)
            if match:
                return match[1]
    return 'unknown'


def sync_directory(path: Path) -> None:
    fd = os.open(path, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def sync_tree(root: Path) -> None:
    for folder, _, files in os.walk(root, topdown=False):
        for name in files:
            with (Path(folder) / name).open('rb') as f:
                os.fsync(f.fileno())
        sync_directory(Path(folder))


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix('.tmp')
    with temporary.open('w') as f:
        json.dump(value, f, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    os.replace(temporary, path)
    sync_directory(path.parent)


def copy_runtime(source: Path, dest: Path) -> None:
    dest.mkdir(mode=0o700)
    for part in PARTS:
        shutil.copytree(source / part, dest / part,
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    if inventory(source) != inventory(dest):
        raise ValueError('复制后的运行文件哈希不一致')
    sync_tree(dest)
    sync_directory(dest.parent)


def smoke(root: Path, workspace: Path) -> None:
    if not os.access(root / 'bin/capbox', os.X_OK):
        raise ValueError('bin/capbox 缺少可执行权限')
    for path in [root / 'bin/capbox', *sorted((root / 'lib').rglob('*.sh'))]:
        subprocess.run(['bash', '-n', str(path)], check=True, capture_output=True)
    # Call from its own directory, so another project's lib cannot shadow the stage.
    env = {k: v for k, v in os.environ.items() if not k.startswith('CAPBOX_')}
    for args in [('version',), ('--help',)]:
        result = subprocess.run([str(root / 'bin/capbox'), '--root', str(root), *args], cwd=root, env=env,
                                text=True, capture_output=True, timeout=30, check=True)
        if args == ('version',) and result.stdout.strip() != f'CapBox {version(root)}':
            raise ValueError('运行时版本与模板元数据不一致')


def report(data: dict, as_json: bool) -> None:
    if as_json:
        print(json.dumps(data, ensure_ascii=False))
    else:
        for key, value in data.items():
            print(f'{key}: {value}')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['check', 'apply', 'rollback'])
    parser.add_argument('--target', type=Path, required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--private', type=Path, required=True)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--data-root', type=Path, required=True)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    target = real_directory(args.target.absolute())
    workspace = real_directory(args.workspace.absolute())
    private = real_directory(args.private.absolute())
    if private.is_relative_to(workspace):
        raise ValueError('备份目录不能位于工作区')
    if private.stat().st_uid != os.getuid() or stat.S_IMODE(private.stat().st_mode) != 0o700:
        raise ValueError('宿主备份目录所有者或权限不安全')
    data_root = args.data_root.absolute()
    if data_root.resolve().is_relative_to(workspace):
        raise ValueError('持久备份不能位于工作区')
    for part in (data_root, *data_root.parents):
        if part.is_symlink():
            raise ValueError('持久备份路径不能含符号链接')
    data_root.mkdir(parents=True, mode=0o700, exist_ok=True)
    if data_root.stat().st_uid != os.getuid() or stat.S_IMODE(data_root.stat().st_mode) != 0o700:
        raise ValueError('持久备份目录所有者或权限不安全')
    project_data = data_root / hashlib.sha256(str(target).encode()).hexdigest()[:32]
    if project_data.is_symlink():
        raise ValueError('项目备份目录不能是符号链接')
    project_data.mkdir(mode=0o700, exist_ok=True)
    if project_data.stat().st_uid != os.getuid() or stat.S_IMODE(project_data.stat().st_mode) != 0o700:
        raise ValueError('项目备份目录所有者或权限不安全')
    backups = project_data / 'upgrades'
    if backups.is_symlink():
        raise ValueError('备份目录不能是符号链接')
    backups.mkdir(mode=0o700, exist_ok=True)
    if backups.stat().st_uid != os.getuid() or stat.S_IMODE(backups.stat().st_mode) != 0o700:
        raise ValueError('备份目录所有者或权限不安全')
    journal = backups / 'transaction.json'
    if journal.is_symlink():
        raise ValueError('事务记录不能是符号链接')
    record = json.loads(journal.read_text()) if journal.exists() else None
    if record is not None:
        fields = {'id', 'phase', 'old_inventory', 'new_inventory', 'old_version', 'new_version'}
        if (not isinstance(record, dict) or set(record) != fields
                or not re.fullmatch(r'[a-f0-9]{32}', str(record['id']))
                or record['phase'] not in ('prepared', 'promoting', 'complete', 'rolled_back')
                or not isinstance(record['old_inventory'], dict)
                or not isinstance(record['new_inventory'], dict)):
            raise ValueError('升级事务记录格式无效，拒绝修改运行文件')
    marker = target / '.upgrade-in-progress'

    def begin_maintenance():
        if marker.is_symlink() or (marker.exists() and not marker.is_file()):
            raise ValueError('升级维护标记不安全')
        marker.touch(mode=0o600, exist_ok=True)
        with marker.open('rb') as f:
            os.fsync(f.fileno())
        sync_directory(target)


    def recover() -> None:
        nonlocal record
        if not record:
            raise ValueError('没有可回滚的升级记录')
        backup = backups / record['id']
        real_directory(backup)
        if inventory(backup) != record['old_inventory']:
            raise ValueError('备份完整性校验失败，拒绝回滚')
        begin_maintenance()
        # Recovery is idempotent and can be repeated after interruption.
        for part in PARTS:
            pending = target / f'.upgrade-recover-{part}'
            if pending.is_symlink():
                raise ValueError('回滚暂存路径不能是符号链接')
            if pending.exists():
                shutil.rmtree(pending)
            shutil.copytree(backup / part, pending)
            sync_tree(pending)
            sync_directory(target)
            existing = target / part
            if existing.is_symlink():
                raise ValueError('运行目录不能是符号链接')
            if existing.exists():
                shutil.rmtree(existing)
            os.replace(pending, existing)
            sync_directory(target)
        if inventory(target) != record['old_inventory']:
            raise ValueError('回滚后的运行文件校验失败')
        record['phase'] = 'rolled_back'
        write_json(journal, record)
        marker.unlink(missing_ok=True)
        sync_directory(target)

    if args.action == 'rollback':
        recover()
        report({'status': 'rolled_back', 'version': version(target)}, args.json)
        return
    if record and record['phase'] not in ('complete', 'rolled_back'):
        raise ValueError('存在未完成升级，请先运行 upgrade rollback')
    source = real_directory(args.source.absolute())
    if source.is_relative_to(workspace):
        raise ValueError('升级来源必须位于工作区外，避免执行 guest 可修改的模板')
    old, new = inventory(target), inventory(source)
    differences = sorted(k for k in old.keys() | new.keys() if old.get(k) != new.get(k))
    data = {'status': 'up_to_date' if not differences else 'update_available',
            'current_version': version(target), 'target_version': version(source),
            'changed_files': differences, 'backup_directory': str(backups)}
    if args.action == 'check' or not differences:
        report(data, args.json)
        return
    ident = uuid.uuid4().hex
    stage = target / ('.upgrade-stage-' + ident)
    backup = backups / ident
    try:
        copy_runtime(source, stage)
        smoke(stage, workspace)
        # Validate the new bundle before backing up or replacing any old file.
        copy_runtime(target, backup)
        record = {'id': ident, 'phase': 'prepared', 'old_inventory': old,
                  'new_inventory': new, 'old_version': version(target),
                  'new_version': version(source)}
        write_json(journal, record)
        begin_maintenance()
        try:
            record['phase'] = 'promoting'
            write_json(journal, record)
            for part in PARTS:
                # Both moves stay on the project's filesystem.
                displaced = stage / ('old-' + part)
                os.replace(target / part, displaced)
                os.replace(stage / part, target / part)
                sync_directory(stage)
                sync_directory(target)
            if inventory(target) != new:
                raise ValueError('升级后的文件校验失败')
            smoke(target, workspace)
            record['phase'] = 'complete'
            write_json(journal, record)
            marker.unlink(missing_ok=True)
            sync_directory(target)
        except BaseException:
            recover()
            raise
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    data['status'] = 'upgraded'
    report(data, args.json)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as exc:
        print(f'[capbox] 升级失败: {exc}', file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            print(exc.stderr[-2000:], file=sys.stderr)
        sys.exit(1)
