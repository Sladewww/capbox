#!/usr/bin/env python3
"""Host control files must remain outside the guest's writable filesystem."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class HostBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="capbox-boundary-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.workspace = self.base / "workspace"
        self.state = self.workspace / ".capbox"
        self.rootfs = self.state / "os/alpine"
        self.rootfs.mkdir(parents=True)
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith("CAPBOX_"):
                del self.env[key]
        self.env.update(CAPBOX_DIR=str(self.state),
                        CAPBOX_WORKSPACE=str(self.workspace),
                        XDG_RUNTIME_DIR=str(self.base), CAPBOX_IDMAP="off")

    def bash(self, code, *args):
        return subprocess.run(
            ["bash", "-c", 'source "$1/lib/common.sh"; '
             'source "$1/lib/idmap.sh"; source "$1/lib/service.sh"; '
             + code, "boundary-test", str(REPO), *map(str, args)],
            env=self.env, text=True, capture_output=True, timeout=30,
        )

    def test_service_control_directory_is_private(self):
        result = self.bash('rd="$(_service_run_dir demo)" || exit; '
                           'mkdir -p "$rd"; printf "%s" "$rd"')
        self.assertEqual(result.returncode, 0, result.stderr)
        control = Path(result.stdout).resolve()
        self.assertFalse(control.is_relative_to(self.workspace))
        self.assertEqual(control.parents[1].stat().st_mode & 0o777, 0o700)

    def test_helper_does_not_write_through_rootfs_links(self):
        target = self.base / "outside-rootfs.txt"
        target.write_text("unchanged\n")
        guest = self.rootfs / "usr/libexec/capbox-drop-priv"
        guest.parent.mkdir(parents=True)
        guest.symlink_to(target)
        result = self.bash(
            'CAPBOX_ROOTFS="$2"; bin="$(_idmap_drop_priv_host_bin)" || exit; '
            'mkdir -p "$(dirname "$bin")"; cp /bin/true "$bin"; '
            'touch -d "next hour" "$bin"; _idmap_ensure_drop_priv_helper',
            self.rootfs,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_bytes(), b"unchanged\n")
        self.assertTrue(guest.is_symlink())

    def test_helper_does_not_write_through_rootfs_ancestors(self):
        outside = self.base / "outside-directory"
        outside.mkdir()
        (self.rootfs / "usr").symlink_to(outside, target_is_directory=True)
        result = self.bash('CAPBOX_ROOTFS="$2"; _idmap_ensure_drop_priv_helper',
                           self.rootfs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(outside.iterdir()), [])

    def test_private_state_rejects_guest_visible_runtime_base(self):
        self.env["XDG_RUNTIME_DIR"] = str(self.workspace)
        result = self.bash('_capbox_host_state_dir')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(result.stdout).resolve().is_relative_to(self.workspace))

    def test_stale_service_pid_does_not_authorize_process_operations(self):
        result = self.bash('rd="$(_service_run_dir demo)" || exit; '
                           'mkdir -p "$rd"; echo $$ >"$rd/supervisor.pid"; '
                           '_service_is_running demo')
        self.assertNotEqual(result.returncode, 0)

    def test_private_parent_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="", dir="/tmp") as short:
            self.env["XDG_RUNTIME_DIR"] = short
            (Path(short) / f"capbox-{os.getuid()}").symlink_to(self.base)
            result = self.bash('_capbox_host_state_dir')
        self.assertNotEqual(result.returncode, 0)

    def test_blocked_uid_mapping_is_reported_without_traceback(self):
        tools = self.base / 'tools'
        tools.mkdir()
        for name in ('newuidmap', 'newgidmap'):
            command = tools / name
            command.write_text('#!/bin/sh\nexit 1\n')
            command.chmod(0o755)
        self.env['PATH'] = str(tools) + os.pathsep + self.env['PATH']
        result = self.bash('CAPBOX_IDMAP=on; rc=0; _idmap_probe || rc=$?; '
                           'printf "%s\\n" "$CAPBOX_IDMAP_DETAIL"; exit "$rc"')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn('Traceback', result.stdout + result.stderr)

    def test_supervisor_retains_filter_fd_across_restarts(self):
        data = self.base / "filter-fixture"
        data.write_bytes(b"filter sentinel")
        output = self.base / "children"
        child = [sys.executable, "-c",
                 "import os,sys,time; assert os.read(int(sys.argv[1]),15)==b'filter sentinel'; "
                 "open(sys.argv[2],'a').write('ok\\n'); time.sleep(0.35)"]
        with data.open("rb") as fd:
            proc = subprocess.run(
                [sys.executable, str(REPO / "lib/service-supervisor.py"),
                 "--name", "fd-test", "--log", str(self.base / "service.log"),
                 "--pidfile", str(self.base / "supervisor.pid"),
                 "--pass-fd", str(fd.fileno()), "--restart", "always",
                 "--restart-max", "1", "--restart-backoff", "0", "--",
                 *child, str(fd.fileno()), str(output)],
                pass_fds=(fd.fileno(),), capture_output=True, text=True, timeout=10,
                env=self.env,
            )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(output.read_text(), "ok\nok\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
