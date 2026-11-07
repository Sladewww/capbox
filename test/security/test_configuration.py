#!/usr/bin/env python3
"""Exercise configuration commits through the real CLI, without guest/rootfs access."""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='capbox-config-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.ws = self.base / 'workspace'
        self.ws.mkdir()
        runtime = self.base / 'runtime'
        runtime.mkdir(mode=0o700)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('CAPBOX_')}
        self.env['XDG_RUNTIME_DIR'] = str(runtime)
        self.cli('bootstrap', check=True)
        self.config = self.ws / '.capbox/config.env'
        self.cli('config', 'set', 'NET', 'open', check=True)

    def cli(self, *args, check=False):
        return subprocess.run([str(REPO / 'bin/capbox'), '--root', str(self.ws), *args],
                              env=self.env, capture_output=True, text=True, timeout=20,
                              check=check)

    def recipe(self, text, *options):
        path = self.ws / 'capbox.recipe'
        path.write_text(text)
        return self.cli('recipe', 'apply', *options, str(path))

    def test_invalid_later_value_keeps_entire_file_unchanged(self):
        before = self.config.read_bytes()
        inode = self.config.stat().st_ino
        result = self.recipe('NET=none\nMEMORY_MAX=invalid\nINIT=0\n')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(self.config.stat().st_ino, inode)

    def test_typo_fails_without_configuration_changes(self):
        before = self.config.read_bytes()
        result = self.recipe('NETT=none\nINIT=0\n')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.config.read_bytes(), before)

    def test_shell_text_fails_without_running_it(self):
        sentinel = self.ws / 'executed'
        result = self.recipe(f'NET=none\n$(touch {sentinel})\nINIT=0\n')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertEqual(self.cli('config', 'get', 'NET').stdout.strip(), 'open')

    def test_duplicate_normalized_key_fails(self):
        result = self.recipe('NET=none\nCAPBOX_NET=open\nINIT=0\n')
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_invalid_init_fails_before_any_write(self):
        before = self.config.read_bytes()
        result = self.recipe('NET=none\nINIT=typo\n')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.config.read_bytes(), before)

    def test_successful_batch_keeps_bind_inode(self):
        inode = self.config.stat().st_ino
        result = self.recipe('NET=none\nMEMORY_MAX=128M\nINIT=0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.stat().st_ino, inode)
        self.assertEqual(self.cli('config', 'get', 'NET').stdout.strip(), 'none')
        self.assertEqual(self.cli('config', 'get', 'MEMORY_MAX').stdout.strip(), '128M')

    def test_unrelated_updates_preserve_implicit_strict_rootfs_default(self):
        self.assertNotIn('CAPBOX_ROOTFS_RO=', self.config.read_text())
        self.cli('config', 'set', 'MEMORY_MAX', '128M', check=True)
        self.assertNotIn('CAPBOX_ROOTFS_RO=', self.config.read_text())
        self.cli('config', 'set', 'ROOTFS_RO', '0', check=True)
        self.assertIn("CAPBOX_ROOTFS_RO='0'", self.config.read_text())

    def test_check_does_not_write(self):
        before = self.config.read_bytes()
        path = self.ws / 'valid.recipe'
        path.write_text('NET=none\nINIT=0\n')
        result = self.cli('recipe', 'check', str(path))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_bytes(), before)

    def test_parallel_updates_preserve_both_keys(self):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            jobs = [pool.submit(self.cli, 'config', 'set', key, value)
                    for key, value in [('NET', 'none'), ('MEMORY_MAX', '256M')]]
            for job in jobs:
                result = job.result()
                self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.cli('config', 'get', 'NET').stdout.strip(), 'none')
        self.assertEqual(self.cli('config', 'get', 'MEMORY_MAX').stdout.strip(), '256M')

    def test_incompatible_package_lock_fails_before_configuration_commit(self):
        import json
        lock = self.ws / 'wrong.lock'
        lock.write_text(json.dumps({'schema': 1, 'distro': 'ubuntu',
            'architecture': os.uname().machine, 'packages': {'busybox': '1.0-r0'}}))
        before = self.config.read_bytes()
        result = self.recipe('NET=none\nINIT=0\n', '--locked', str(lock))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.config.read_bytes(), before)

    def test_package_lock_must_satisfy_recipe_packages_before_commit(self):
        import json
        lock = self.ws / 'missing.lock'
        lock.write_text(json.dumps({'schema': 1, 'distro': 'alpine',
            'architecture': os.uname().machine, 'packages': {'busybox': '1.0-r0'}}))
        before = self.config.read_bytes()
        result = self.recipe('NET=none\nPACKAGES=curl\nINIT=0\n', '--locked', str(lock))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('不能满足配方', result.stderr)
        self.assertEqual(self.config.read_bytes(), before)

    def test_conflicting_presets_fail_before_initialization(self):
        before = self.config.read_bytes()
        result = self.cli('init', '--agent', '--trusted')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.config.read_bytes(), before)

    def test_reader_waits_for_complete_inode_preserving_commit(self):
        import time
        environment = dict(self.env, CAPBOX_DIR=str(self.ws / '.capbox'),
                           CAPBOX_WORKSPACE=str(self.ws))
        private = subprocess.check_output(['bash', '-c',
            'source "$1/lib/common.sh"; _capbox_host_state_dir',
            'read-lock-test', str(REPO)], env=environment, text=True).strip()
        marker = self.base / 'writer-ready'
        writer_code = ("import fcntl,pathlib,sys,time; "
            "lock=open(sys.argv[1],'w'); fcntl.flock(lock,fcntl.LOCK_EX); "
            "config=open(sys.argv[2],'w'); pathlib.Path(sys.argv[3]).touch(); "
            "time.sleep(0.8); config.write(\"CAPBOX_NET='none'\\n\"); config.close()")
        writer = subprocess.Popen(['python3', '-c', writer_code,
            str(Path(private) / 'config.lock'), str(self.config), str(marker)])
        try:
            deadline = time.monotonic() + 5
            while not marker.exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            result = self.cli('config', 'get', 'NET')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), 'none')
            writer.wait(timeout=5)
        finally:
            if writer.poll() is None:
                writer.terminate()
                writer.wait(timeout=5)

    def test_config_symlink_is_refused(self):
        victim = self.base / 'outside'
        victim.write_text('unchanged')
        self.config.unlink()
        self.config.symlink_to(victim)
        result = self.cli('config', 'set', 'NET', 'none')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(victim.read_text(), 'unchanged')


if __name__ == '__main__':
    unittest.main(verbosity=2)
