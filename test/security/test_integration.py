#!/usr/bin/env python3
"""Real bubblewrap regressions, using an isolated copy of the installed rootfs."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[2]
ROOTFS = Path(os.environ.get("CAPBOX_TEST_ROOTFS", REPO / "os/alpine"))


@unittest.skipUnless((ROOTFS / "bin/sh").exists() or (ROOTFS / "bin/sh").is_symlink(),
                     "set CAPBOX_TEST_ROOTFS to an Alpine rootfs")
class SandboxIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="capbox-security-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.workspace = self.base / "workspace"
        self.runtime = self.base / "runtime"
        self.workspace.mkdir()
        self.runtime.mkdir(mode=0o700)
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith("CAPBOX_"):
                del self.env[key]
        self.env.update(XDG_RUNTIME_DIR=str(self.runtime), CAPBOX_IDMAP="off",
                        CAPBOX_SECURITY_PROFILE="untrusted", CAPBOX_NET="none",
                        CAPBOX_OVERLAY="off")
        self.cli = [str(REPO / "bin/capbox"), "--root", str(self.workspace)]
        self.run_cli("bootstrap", check=True)
        self.state = self.workspace / ".capbox"
        shutil.copytree(ROOTFS, self.state / "os/alpine", symlinks=True)
        for directory in ("run", "workspace", "proc", "dev", "sys", "tmp", "mnt"):
            (self.state / "os/alpine" / directory).mkdir(exist_ok=True)
        # init's first writable bootstrap normally creates this bind mountpoint.
        (self.state / "os/alpine/etc/resolv.conf").touch(exist_ok=True)

    def run_cli(self, *args, check=False):
        return subprocess.run(self.cli + list(args), env=self.env, capture_output=True,
                              text=True, timeout=45, check=check)

    def service(self, name, content):
        (self.state / "services" / (name + ".env")).write_text(content)
        self.addCleanup(self.run_cli, "service", "stop", name)

    def test_guest_cannot_access_host_control_files(self):
        self.service("boundary", "CMD=sleep 60\n")
        result = self.run_cli("service", "start", "boundary")
        self.assertEqual(result.returncode, 0, result.stderr)
        host_env = dict(self.env, CAPBOX_DIR=str(self.state),
                        CAPBOX_WORKSPACE=str(self.workspace))
        control = subprocess.check_output(
            ["bash", "-c", 'source "$1/lib/common.sh"; source "$1/lib/service.sh"; '
             '_service_run_dir boundary', "test", str(REPO)], env=host_env, text=True)
        self.assertFalse(Path(control).is_relative_to(self.workspace))
        self.assertTrue((Path(control) / "run-child.sh").is_file())
        result = self.run_cli("exec", "--", "sh", "-c",
                              'test ! -e "$1/run-child.sh" && '
                              'test ! -e /workspace/.capbox/run/services/boundary/run-child.sh '
                              '&& echo protected', "test", control)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "protected")

    def test_seccomp_service_survives_restart(self):
        self.service("restart", "CMD=sh -c 'echo RUN; sleep 1'\n"
                     "RESTART=always\nRESTART_MAX=10\nRESTART_BACKOFF=0\n")
        result = self.run_cli("service", "start", "restart")
        self.assertEqual(result.returncode, 0, result.stderr)
        time.sleep(1.6)
        logs = self.run_cli("service", "logs", "restart", "-n", "100")
        self.assertGreaterEqual(logs.stdout.splitlines().count("RUN"), 2, logs.stdout)
        self.assertNotIn("Bad file descriptor", logs.stdout)
        self.assertNotIn("reported EINVAL", logs.stdout)
        status = self.run_cli("service", "status", "restart")
        self.assertIn("state=running", status.stdout)

    def test_failed_service_start_returns_failure(self):
        self.service("failure", "CMD=/nonexistent-capbox-service\n")
        result = self.run_cli("service", "start", "failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("已启动", result.stderr)

    def test_published_port_reaches_the_sandbox_network(self):
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            host_port = reserve.getsockname()[1]
        self.service("publish", "CMD=sh -c 'while true; do nc -l -p 18080 -e /bin/cat; done'\n"
                     f"PUBLISH={host_port}:18080\n")
        result = self.run_cli("service", "start", "publish")
        self.assertEqual(result.returncode, 0, result.stderr)
        with socket.create_connection(("127.0.0.1", host_port), timeout=5) as client:
            client.sendall(b"defensive-test\n")
            self.assertEqual(client.recv(64), b"defensive-test\n")

    def test_package_scripts_use_disk_fallback_without_losing_profile_rules(self):
        probe = self.base / "script-probe"
        subprocess.run(["gcc", "-static", "-O2",
                        str(REPO / "test/security/probe_script_exec.c"),
                        "-o", str(probe)], check=True, capture_output=True, timeout=30)
        for profile in ("compat", "untrusted"):
            env = dict(self.env, CAPBOX_DIR=str(self.state),
                       CAPBOX_WORKSPACE=str(self.workspace),
                       CAPBOX_SECURITY_PROFILE=profile,
                       CAPBOX_BWRAP_EXTRA=f"--ro-bind {probe} /run/script-probe")
            result = subprocess.run(
                ["bash", "-c", 'for module in common rootfs sandbox net resources idmap '
                 'security fsguard landlock; do source "$1/lib/$module.sh"; done; '
                 '_pkg_run_guest install "/run/script-probe; '
                 'if mount -t tmpfs none /mnt >/dev/null 2>&1; then echo MOUNT_ALLOWED; '
                 'else echo MOUNT_DENIED; fi" 20', "test", str(REPO)],
                env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("memfd_create: Function not implemented", result.stdout)
            self.assertIn("disk-script rc=0", result.stdout)
            if profile == "untrusted":
                self.assertIn("MOUNT_DENIED", result.stdout)

    def test_none_uses_a_separate_network_namespace_and_clears_env(self):
        self.env["CAPBOX_SECURITY_TEST_SENTINEL"] = "host-only"
        result = self.run_cli("exec", "--", "sh", "-c",
                              'test -z "${CAPBOX_SECURITY_TEST_SENTINEL+x}" && '
                              'readlink /proc/self/ns/net')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(result.stdout.strip(), os.readlink("/proc/self/ns/net"))

    def test_strict_exec(self):
        result = self.run_cli("exec", "--profile", "strict", "--", "true")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_restricted_bridge_starts_without_exposing_host_control(self):
        self.env["CAPBOX_NET_ALLOW"] = "example.com"
        result = self.run_cli("exec", "--net", "restricted", "--", "sh", "-c",
                              'test -n "$https_proxy" && '
                              'test -d /run/capbox-net && '
                              'test ! -e /run/capbox-net/oneshot-proxy.pid')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_daemon_exec_and_shutdown(self):
        proc = subprocess.Popen(self.cli + ["up"], env=self.env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                status = self.run_cli("status", "--json")
                if '"running":true' in status.stdout.replace(" ", ""):
                    break
                if proc.poll() is not None:
                    self.fail("daemon exited during startup")
                time.sleep(0.1)
            else:
                self.fail("daemon did not become ready")
            result = self.run_cli("exec", "--daemon", "--", "id", "-u")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "0")
            result = self.run_cli("down")
            self.assertEqual(result.returncode, 0, result.stderr)
            proc.wait(timeout=15)
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=15)


if __name__ == "__main__":
    unittest.main(verbosity=2)
