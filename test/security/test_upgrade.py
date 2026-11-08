#!/usr/bin/env python3
"""Upgrade a real project copy, including refusal and recovery paths."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='capbox-upgrade-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.ws = self.base / 'workspace'
        self.ws.mkdir()
        self.runtime = self.base / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('CAPBOX_')}
        self.env['XDG_RUNTIME_DIR'] = str(self.runtime)
        self.env['XDG_STATE_HOME'] = str(self.base / 'state')
        self.cli('bootstrap', check=True)
        self.state = self.ws / '.capbox'
        self.cli('config', 'set', 'NET', 'none', check=True)
        self.config = (self.state / 'config.env').read_bytes()
        self.rootfs = self.state / 'os/alpine'
        self.rootfs.mkdir(parents=True)
        (self.rootfs / 'data').write_text('rootfs data')
        (self.ws / 'business-data').write_text('business data')
        version = self.state / 'lib/version.sh'
        version.write_text(version.read_text().replace('0.3.7', '0.3.5'))
        (self.state / 'lib/removed-in-upgrade.sh').write_text('# obsolete\n')

    def cli(self, *args, check=False):
        return subprocess.run([str(REPO / 'bin/capbox'), '--root', str(self.ws), *args],
                              env=self.env, capture_output=True, text=True,
                              timeout=40, check=check)

    def upgrade(self, action='apply', source=REPO):
        args = ['upgrade', action, '--json']
        if action != 'rollback':
            args += ['--from', str(source)]
        return self.cli(*args)

    def assert_data_preserved(self):
        self.assertEqual((self.rootfs / 'data').read_text(), 'rootfs data')
        self.assertEqual((self.ws / 'business-data').read_text(), 'business data')
        self.assertEqual((self.state / 'config.env').read_bytes(), self.config)

    def test_check_detects_content_and_obsolete_files(self):
        result = self.upgrade('check')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['status'], 'update_available')
        self.assertEqual(data['current_version'], '0.3.5')
        self.assertIn('lib/removed-in-upgrade.sh', data['changed_files'])
        self.assert_data_preserved()

    def test_apply_and_rollback_preserve_data_and_restore_whole_bundle(self):
        result = self.upgrade()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'], 'upgraded')
        self.assertFalse((self.state / 'lib/removed-in-upgrade.sh').exists())
        self.assertEqual(self.cli('version').stdout.strip(), 'CapBox 0.3.7')
        self.assert_data_preserved()
        result = self.upgrade('rollback')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.state / 'lib/removed-in-upgrade.sh').is_file())
        self.assertEqual(self.cli('version').stdout.strip(), 'CapBox 0.3.5')
        self.assert_data_preserved()

    def template(self):
        template = self.base / 'new template'
        template.mkdir()
        for part in ('bin', 'lib'):
            shutil.copytree(REPO / part, template / part,
                            ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        return template

    def test_incomplete_template_is_refused_before_replacement(self):
        template = self.template()
        (template / 'lib/config.sh').unlink()
        result = self.upgrade(source=template)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.cli('version').stdout.strip(), 'CapBox 0.3.5')
        self.assert_data_preserved()

    def test_failure_after_promotion_automatically_restores_old_runtime(self):
        template = self.template()
        cli = template / 'bin/capbox'
        text = cli.read_text()
        cli.write_text(text.replace('set -u',
            'set -u\n[[ "${BASH_SOURCE[0]}" == *".upgrade-stage-"* ]] || exit 77', 1))
        result = self.upgrade(source=template)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.cli('version').stdout.strip(), 'CapBox 0.3.5')
        self.assertFalse((self.state / '.upgrade-in-progress').exists())
        self.assert_data_preserved()

    def test_guest_visible_template_is_refused(self):
        result = self.upgrade(source=self.state)
        self.assertNotEqual(result.returncode, 0)
        self.assert_data_preserved()

    def test_legacy_service_records_require_old_cli_shutdown(self):
        legacy = self.state / 'run/services/legacy'
        legacy.mkdir(parents=True)
        (legacy / 'supervisor.pid').write_text('12345\n')
        result = self.upgrade()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('旧版运行记录', result.stderr)
        self.assert_data_preserved()

    def test_persistent_backup_survives_runtime_directory_removal(self):
        self.upgrade().check_returncode()
        shutil.rmtree(self.runtime)
        result = self.upgrade('rollback')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.cli('version').stdout.strip(), 'CapBox 0.3.5')
        self.assert_data_preserved()

    def test_corrupt_backup_is_refused_before_touching_installed_files(self):
        result = self.upgrade()
        result.check_returncode()
        backups = Path(json.loads(result.stdout)['backup_directory'])
        record = json.loads((backups / 'transaction.json').read_text())
        version = backups / record['id'] / 'lib/version.sh'
        version.write_text('corrupted backup')
        result = self.upgrade('rollback')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.cli('version').stdout.strip(), 'CapBox 0.3.7')
        self.assert_data_preserved()

    def test_corrupt_transaction_record_is_refused_without_traceback(self):
        result = self.upgrade()
        result.check_returncode()
        backups = Path(json.loads(result.stdout)['backup_directory'])
        (backups / 'transaction.json').write_text('{"id":"../outside"}')
        result = self.upgrade('rollback')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('事务记录格式无效', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertEqual(self.cli('version').stdout.strip(), 'CapBox 0.3.7')
        self.assert_data_preserved()

    def test_missing_backup_is_an_error(self):
        result = self.upgrade('rollback')
        self.assertNotEqual(result.returncode, 0)
        self.assert_data_preserved()

    def test_interruption_marker_blocks_normal_commands_but_not_recovery(self):
        self.upgrade().check_returncode()
        marker = self.state / '.upgrade-in-progress'
        marker.touch()
        result = self.cli('exec', '--', 'true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('升级未完成', result.stderr)
        result = self.upgrade('rollback')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assert_data_preserved()


if __name__ == '__main__':
    unittest.main(verbosity=2)
