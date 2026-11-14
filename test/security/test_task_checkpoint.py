#!/usr/bin/env python3
"""Cold checkpoint CLI acceptance with a bootstrapped Alpine rootfs."""
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import unittest


# Reuse the real-task fixture without inheriting its unrelated test methods.
from test_agent_workflows import Fixture, ROOTFS


@unittest.skipUnless(os.path.lexists(ROOTFS / 'bin/sh'), 'set CAPBOX_TEST_ROOTFS')
class CheckpointTests(Fixture):
    def setUp(self):
        super().setUp()
        self.env['CAPBOX_NET'] = os.getenv('CAPBOX_CHECKPOINT_TEST_NET', 'none')
        self.env['CAPBOX_OVERLAY'] = '0'
        self.env['CAPBOX_LANG'] = 'en'
        self.rootfs = self.ws / '.capbox/os/alpine'
        shutil.copytree(ROOTFS, self.rootfs, symlinks=True)
        self.archive = self.base / 'checkpoint'
        self.target = self.base / 'restored'

    def start(self, *args, workspace=None):
        cli = self.cli if workspace is None else [self.cli[0], '--root', str(workspace)]
        result = subprocess.run(cli + ['task', 'start', *args], env=self.env, text=True,
                                capture_output=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stderr)
        task = json.loads(result.stdout)['task_id']

        def remove_task():
            for command in (['cancel', task], ['wait', task, '--timeout', '5'], ['rm', task]):
                subprocess.run(cli + ['task', *command], env=self.env,
                               capture_output=True, timeout=15)

        self.addCleanup(remove_task)
        return task

    def test_restores_worktree_copy_up_whiteouts_and_config(self):
        (self.ws / 'progress').write_text('original')
        (self.ws / 'remove-this').write_text('original')
        (self.ws / '.env').write_text('excluded')
        self.run_cli('config', 'set', 'CAPBOX_HOSTNAME', 'checkpoint-host', check=True)
        (self.rootfs / 'etc/drop-from-lower').write_text('lower')
        (self.rootfs / 'etc/sub').mkdir()
        (self.rootfs / 'etc/sub/old').write_text('lower')
        upper = self.ws / '.capbox/run/overlay/active/upper'
        (upper / 'etc/sub').mkdir(parents=True)
        os.setxattr(upper / 'etc/sub', 'user.overlay.opaque', b'y')
        (upper / 'etc/.wh.drop-from-lower').touch()
        (upper / 'etc/sub/new').write_text('copied-up')
        task = self.start('--isolate', '--profile', 'strict', '--', 'sh', '-ec',
                          'test ! -e /etc/drop-from-lower && test ! -e /etc/sub/old; '
                          'echo updated > progress; rm remove-this; ! touch /etc/task-only')
        self.run_cli('task', 'wait', task, '--timeout', '15', check=True)
        result = self.run_cli('task', 'checkpoint', task, str(self.archive))
        self.assertEqual(result.returncode, 0, result.stderr)
        pin = json.loads(result.stdout)['manifest_sha256']
        self.run_cli('task', 'rm', task, check=True)
        result = self.run_cli('task', 'restore', str(self.archive), str(self.target),
                              '--manifest-sha256', pin)
        self.assertEqual(result.returncode, 0, result.stderr)
        resumed = self.start('--isolate', '--', 'sh', '-ec',
                             'test "$(hostname)" = checkpoint-host; '
                             'test "$(cat progress)" = updated; test ! -e remove-this; '
                             'test ! -e .env; test ! -e /etc/drop-from-lower; '
                             'test ! -e /etc/sub/old; test "$(cat /etc/sub/new)" = copied-up; '
                             'test ! -e /etc/task-only; echo continued > continued',
                             workspace=self.target)
        result = subprocess.run([self.cli[0], '--root', str(self.target), 'task', 'wait',
                                 resumed, '--timeout', '15'], env=self.env, capture_output=True,
                                timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.ws / 'progress').read_text(), 'original')
        self.assertTrue((self.ws / 'remove-this').is_file())
        self.assertTrue((self.rootfs / 'etc/drop-from-lower').is_file())
        self.assertFalse((self.rootfs / 'etc/task-only').exists())
        self.assertEqual((upper / 'etc/sub/new').read_text(), 'copied-up')

    def test_failed_restore_and_corruption_do_not_publish_target(self):
        task = self.start('--isolate', '--', 'true')
        self.run_cli('task', 'wait', task, '--timeout', '15', check=True)
        self.run_cli('task', 'checkpoint', task, str(self.archive), check=True)
        archive = self.archive / 'rootfs.tar.gz'
        expected_bytes = archive.read_bytes()
        archive.write_bytes(expected_bytes + b'corrupt')
        result = self.run_cli('task', 'restore', str(self.archive), str(self.target))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SHA256', result.stderr)
        self.assertFalse(self.target.exists())

        # An internally consistent archive can still be unusable at restore time.
        with tarfile.open(archive, 'w:gz') as outgoing:
            entry = tarfile.TarInfo('alpine')
            entry.type = tarfile.DIRTYPE
            outgoing.addfile(entry)
        manifest = self.archive / 'manifest.json'
        payload = json.loads(manifest.read_text())
        payload['files'][archive.name] = hashlib.sha256(archive.read_bytes()).hexdigest()
        manifest.write_text(json.dumps(payload))
        result = self.run_cli('task', 'restore', str(self.archive), str(self.target))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing its shell', result.stderr)
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.base.glob('.capbox-restore-*')), [])
        self.target.mkdir()
        sentinel = self.target / 'sentinel'
        sentinel.write_text('keep')
        result = self.run_cli('task', 'restore', str(self.archive), str(self.target))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), 'keep')

    def test_running_and_shared_tasks_cannot_be_checkpointed(self):
        shared = self.start('--', 'true')
        self.run_cli('task', 'wait', shared, '--timeout', '15', check=True)
        running = self.start('--isolate', '--', 'sleep', '30')
        for task in (shared, running):
            result = self.run_cli('task', 'checkpoint', task, str(self.archive))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('finished isolated task', result.stderr)
            self.assertFalse(self.archive.exists())


if __name__ == '__main__':
    unittest.main()
