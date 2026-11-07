#!/usr/bin/env python3
"""Strict package locks reject ambiguous or incompatible environments."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).resolve().parents[2] / 'lib/package-lock.py'


class PackageLockTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='capbox-lock-')
        self.addCleanup(self.tmp.cleanup)
        self.lock = Path(self.tmp.name) / 'package.lock'

    def run_tool(self, action, text='', distro='alpine', architecture='x86_64'):
        return subprocess.run([sys.executable, str(TOOL), action, '--distro', distro,
                               '--architecture', architecture, str(self.lock)],
                              input=text, text=True, capture_output=True, timeout=10)

    def save(self, inventory='busybox-1.37.0-r30\nca-certificates-bundle-20260601-r0\n'):
        result = self.run_tool('save', inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.lock.write_text(result.stdout)
        return json.loads(result.stdout)

    def test_alpine_lock_replays_exact_versions_and_verifies(self):
        obj = self.save()
        self.assertEqual(obj['packages']['ca-certificates-bundle'], '20260601-r0')
        result = self.run_tool('arguments')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('busybox=1.37.0-r30\0', result.stdout)
        result = self.run_tool('verify', 'ca-certificates-bundle-20260601-r0\nbusybox-1.37.0-r30\n')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_dpkg_epoch_and_architecture_qualifier_are_preserved(self):
        result = self.run_tool('save', 'ii \tlibc6:amd64\t2:2.39-0ubuntu1\nrc \told\t1.0\n',
                               distro='ubuntu')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['packages'],
                         {'libc6:amd64': '2:2.39-0ubuntu1'})

    def test_missing_extra_or_changed_packages_fail_verification(self):
        self.save()
        for inventory in ['busybox-1.37.0-r30\n',
                          'busybox-1.37.0-r31\nca-certificates-bundle-20260601-r0\n',
                          'busybox-1.37.0-r30\nca-certificates-bundle-20260601-r0\nextra-1.0-r0\n']:
            with self.subTest(inventory=inventory):
                self.assertEqual(self.run_tool('verify', inventory).returncode, 2)

    def test_wrong_distro_or_architecture_fails_before_arguments(self):
        self.save()
        self.assertEqual(self.run_tool('arguments', distro='ubuntu').returncode, 2)
        self.assertEqual(self.run_tool('arguments', architecture='aarch64').returncode, 2)

    def test_empty_or_unconfigured_inventory_cannot_be_saved(self):
        self.assertEqual(self.run_tool('save', '').returncode, 2)
        result = self.run_tool('save', 'iU \tbroken\t1.0\n', distro='ubuntu')
        self.assertEqual(result.returncode, 2)

    def test_untrusted_package_arguments_and_duplicate_keys_are_rejected(self):
        obj = self.save()
        for packages in [{'busybox': '1.0;touch /tmp/x'}, {'../local.apk': '1.0-r0'},
                         {'busybox': '--option'}, {'-option': '1.0-r0'}]:
            with self.subTest(packages=packages):
                obj['packages'] = packages
                self.lock.write_text(json.dumps(obj))
                self.assertEqual(self.run_tool('arguments').returncode, 2)
        self.lock.write_text('{"schema":1,"schema":1,"distro":"alpine",'
                             '"architecture":"x86_64","packages":{"busybox":"1.0-r0"}}')
        self.assertEqual(self.run_tool('validate').returncode, 2)

    def test_legacy_inventory_has_an_explicit_migration_error(self):
        self.lock.write_text('# CapBox package.lock\nbusybox-1.0-r0\n')
        result = self.run_tool('validate')
        self.assertEqual(result.returncode, 2)
        self.assertIn('重新 image lock save', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
