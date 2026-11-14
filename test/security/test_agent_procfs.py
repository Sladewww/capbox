#!/usr/bin/env python3
"""Exercise real bwrap proc mounts without opening sysctl files for writing."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

BWRAP = Path('/usr/bin/bwrap')
SYSCTL = Path('/proc/sys/user/max_user_namespaces')
GUARDED = ('/proc/sys', '/proc/sysrq-trigger', '/proc/irq', '/proc/bus')
BASE = (str(BWRAP), '--ro-bind', '/', '/', '--unshare-user', '--unshare-pid', '--proc', '/proc')
INSPECT = '''
import json, os
from pathlib import Path
paths = %r
with open('/proc/self/mountinfo') as stream:
    mounts = [line.split() for line in stream]
proc = next(m for m in reversed(mounts) if m[4] == '/proc')
print(json.dumps({
    'procfs': proc[proc.index('-') + 1],
    'pid': os.readlink('/proc/self/ns/pid'),
    'proc_read_only': bool(os.statvfs('/proc').f_flag & os.ST_RDONLY),
    'protected': {p: bool(os.statvfs(p).f_flag & os.ST_RDONLY) if Path(p).exists() else None for p in paths},
}))
''' % (GUARDED,)


def run(*argv):
    return subprocess.run(argv, capture_output=True, text=True, timeout=20)


class ProcfsTests(unittest.TestCase):
    def setUp(self):
        if os.getuid() == 0 or not BWRAP.is_file():
            self.skipTest('requires an unprivileged Linux user and /usr/bin/bwrap')
        before = SYSCTL.read_text()
        self.addCleanup(lambda: self.assertEqual(SYSCTL.read_text(), before))

    def check_sealed(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        child = json.loads(result.stdout)
        self.assertEqual(child['procfs'], 'proc')
        self.assertTrue(child['proc_read_only'])
        self.assertNotEqual(child['pid'], os.readlink('/proc/self/ns/pid'))
        self.assertNotIn(False, child['protected'].values())
        return child

    def test_builtin_and_sealed_fresh_procfs(self):
        native = run(*BASE, '--', sys.executable, '-c', INSPECT)
        self.assertEqual(native.returncode, 0, native.stderr)
        native_result = json.loads(native.stdout)
        print(f'{run(str(BWRAP), "--version").stdout.strip()} native: {native_result}', file=sys.stderr)
        sealed = run(*BASE, '--remount-ro', '/proc', '--', sys.executable, '-c', INSPECT)
        self.check_sealed(sealed)

    def test_outer_procfs_mask_stays_in_force_or_refuses_launch(self):
        # The outer sandbox masks its fresh proc tree with a private tmpfs.
        # Some kernels refuse the next proc mount under a restricted outer proc.
        outer = run(*BASE, '--tmpfs', '/proc/irq', '--remount-ro', '/proc/irq',
                    '--', sys.executable, '-c', '''
import os, subprocess, sys
assert os.statvfs('/proc/irq').f_flag & os.ST_RDONLY
inner = subprocess.run(sys.argv[1:], text=True, capture_output=True)
print(inner.stdout, end='')
print(inner.stderr, end='', file=sys.stderr)
sys.exit(inner.returncode)
''', *BASE, '--remount-ro', '/proc', '--', sys.executable, '-c', INSPECT)
        if outer.returncode:
            self.assertEqual(outer.stdout, '')
            self.assertIn("Can't mount proc on /proc", outer.stderr)
            print(f'nested procfs mount refused: {outer.stderr.strip()}', file=sys.stderr)
        else:
            self.check_sealed(outer)


if __name__ == '__main__':
    unittest.main()
