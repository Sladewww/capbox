#!/usr/bin/env python3
"""为已停止的项目暂存、校验并恢复 bin/lib，不触碰其数据。

事务记录与备份位于工作区外。每次 rename 都在同一文件系统上；
中断后可回退已完成步骤。现有进程必须先停止。
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

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
import i18n

if sys.version_info < (3, 10):
    print(i18n.t('upgrade.requires_python_3_10'), file=sys.stderr)
    sys.exit(5)


PARTS = ('bin', 'lib')


def real_directory(path: Path) -> Path:
    # 先拒绝链接（含父路径组件），再解析。
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError(i18n.t('upgrade.refuse_symlink_dir', path=part))
    if not path.is_dir():
        raise ValueError(i18n.t('upgrade.directory_does_not_exist', path=path))
    return path.resolve()


def inventory(root: Path) -> dict[str, str]:
    result = {}
    for part in PARTS:
        real_directory(root / part)
        for folder, dirs, files in os.walk(root / part):
            for name in dirs + files:
                path = Path(folder) / name
                if path.is_symlink():
                    raise ValueError(i18n.t('upgrade.runtime_file_must_not_be_symlink', path=path))
            for name in files:
                path = Path(folder) / name
                if not path.is_file():
                    raise ValueError(i18n.t('upgrade.runtime_dir_regular_files_only', path=path))
                # Python 字节码是本地缓存，不属于运行时包。
                if '__pycache__' in path.parts or path.suffix == '.pyc':
                    continue
                mode = stat.S_IMODE(path.stat().st_mode) & 0o111
                result[str(path.relative_to(root))] = (
                    hashlib.sha256(path.read_bytes()).hexdigest() + f':{mode:o}')
    if 'bin/capbox' not in result or 'lib/common.sh' not in result:
        raise ValueError(i18n.t('upgrade.template_missing_bin_or_lib'))
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
        raise ValueError(i18n.t('upgrade.copied_runtime_hash_mismatch'))
    sync_tree(dest)
    sync_directory(dest.parent)


def smoke(root: Path, workspace: Path) -> None:
    if not os.access(root / 'bin/capbox', os.X_OK):
        raise ValueError(i18n.t('upgrade.bin_capbox_not_executable'))
    for path in [root / 'bin/capbox', *sorted((root / 'lib').rglob('*.sh'))]:
        subprocess.run(['bash', '-n', str(path)], check=True, capture_output=True)
    # 从自身目录调用，避免其他项目的 lib 遮蔽暂存区。
    env = {k: v for k, v in os.environ.items() if not k.startswith('CAPBOX_')}
    for args in [('version',), ('--help',)]:
        result = subprocess.run([str(root / 'bin/capbox'), '--root', str(root), *args], cwd=root, env=env,
                                text=True, capture_output=True, timeout=30, check=True)
        if args == ('version',) and result.stdout.strip() != f'CapBox {version(root)}':
            raise ValueError(i18n.t('upgrade.runtime_version_metadata_mismatch'))


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
        raise ValueError(i18n.t('upgrade.backup_dir_must_not_be_in_workspace'))
    if private.stat().st_uid != os.getuid() or stat.S_IMODE(private.stat().st_mode) != 0o700:
        raise ValueError(i18n.t('upgrade.host_backup_owner_or_mode_unsafe'))
    data_root = args.data_root.absolute()
    if data_root.resolve().is_relative_to(workspace):
        raise ValueError(i18n.t('upgrade.persistent_backup_must_not_be_in_workspace'))
    for part in (data_root, *data_root.parents):
        if part.is_symlink():
            raise ValueError(i18n.t('upgrade.persistent_backup_path_must_not_contain_symlink'))
    data_root.mkdir(parents=True, mode=0o700, exist_ok=True)
    if data_root.stat().st_uid != os.getuid() or stat.S_IMODE(data_root.stat().st_mode) != 0o700:
        raise ValueError(i18n.t('upgrade.persistent_backup_owner_or_mode_unsafe'))
    project_data = data_root / hashlib.sha256(str(target).encode()).hexdigest()[:32]
    if project_data.is_symlink():
        raise ValueError(i18n.t('upgrade.project_backup_must_not_be_symlink'))
    project_data.mkdir(mode=0o700, exist_ok=True)
    if project_data.stat().st_uid != os.getuid() or stat.S_IMODE(project_data.stat().st_mode) != 0o700:
        raise ValueError(i18n.t('upgrade.project_backup_owner_or_mode_unsafe'))
    backups = project_data / 'upgrades'
    if backups.is_symlink():
        raise ValueError(i18n.t('upgrade.backup_dir_must_not_be_symlink'))
    backups.mkdir(mode=0o700, exist_ok=True)
    if backups.stat().st_uid != os.getuid() or stat.S_IMODE(backups.stat().st_mode) != 0o700:
        raise ValueError(i18n.t('upgrade.backup_dir_owner_or_mode_unsafe'))
    journal = backups / 'transaction.json'
    if journal.is_symlink():
        raise ValueError(i18n.t('upgrade.transaction_must_not_be_symlink'))
    record = json.loads(journal.read_text()) if journal.exists() else None
    if record is not None:
        fields = {'id', 'phase', 'old_inventory', 'new_inventory', 'old_version', 'new_version'}
        if (not isinstance(record, dict) or set(record) != fields
                or not re.fullmatch(r'[a-f0-9]{32}', str(record['id']))
                or record['phase'] not in ('prepared', 'promoting', 'complete', 'rolled_back')
                or not isinstance(record['old_inventory'], dict)
                or not isinstance(record['new_inventory'], dict)):
            raise ValueError(i18n.t('upgrade.transaction_format_invalid'))
    marker = target / '.upgrade-in-progress'

    def begin_maintenance():
        if marker.is_symlink() or (marker.exists() and not marker.is_file()):
            raise ValueError(i18n.t('upgrade.maintenance_marker_unsafe'))
        marker.touch(mode=0o600, exist_ok=True)
        with marker.open('rb') as f:
            os.fsync(f.fileno())
        sync_directory(target)


    def recover() -> None:
        nonlocal record
        if not record:
            raise ValueError(i18n.t('upgrade.no_rollback_record'))
        backup = backups / record['id']
        real_directory(backup)
        if inventory(backup) != record['old_inventory']:
            raise ValueError(i18n.t('upgrade.backup_integrity_failed'))
        begin_maintenance()
        # 恢复是幂等的，中断后可重复执行。
        for part in PARTS:
            pending = target / f'.upgrade-recover-{part}'
            if pending.is_symlink():
                raise ValueError(i18n.t('upgrade.rollback_staging_must_not_be_symlink'))
            if pending.exists():
                shutil.rmtree(pending)
            shutil.copytree(backup / part, pending)
            sync_tree(pending)
            sync_directory(target)
            existing = target / part
            if existing.is_symlink():
                raise ValueError(i18n.t('upgrade.runtime_dir_must_not_be_symlink'))
            if existing.exists():
                shutil.rmtree(existing)
            os.replace(pending, existing)
            sync_directory(target)
        if inventory(target) != record['old_inventory']:
            raise ValueError(i18n.t('upgrade.rollback_verification_failed'))
        record['phase'] = 'rolled_back'
        write_json(journal, record)
        marker.unlink(missing_ok=True)
        sync_directory(target)

    if args.action == 'rollback':
        recover()
        report({'status': 'rolled_back', 'version': version(target)}, args.json)
        return
    if record and record['phase'] not in ('complete', 'rolled_back'):
        raise ValueError(i18n.t('upgrade.post_upgrade_unfinished_rollback_first'))
    source = real_directory(args.source.absolute())
    if source.is_relative_to(workspace):
        raise ValueError(i18n.t('upgrade.source_must_be_outside_workspace'))
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
        # 先校验新包，再备份或替换任何旧文件。
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
                # 两次移动都留在项目所在文件系统上。
                displaced = stage / ('old-' + part)
                os.replace(target / part, displaced)
                os.replace(stage / part, target / part)
                sync_directory(stage)
                sync_directory(target)
            if inventory(target) != new:
                raise ValueError(i18n.t('upgrade.post_upgrade_verification_failed'))
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
        print(i18n.t('upgrade.failed', exc=exc), file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            print(exc.stderr[-2000:], file=sys.stderr)
        sys.exit(1)
