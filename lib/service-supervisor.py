#!/usr/bin/env python3
"""宿主侧 CapBox 服务监督器：就绪等待、健康检查、重启退避、停止超时。

由 service.sh 启动。除显式 CLI 标志外，不从环境文件读取密钥。
子进程是 `--` 之后已构造好的 bwrap argv。
"""
from __future__ import annotations

import argparse
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import List, Optional

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
import i18n


def _log(path: str, msg: str) -> None:
    line = f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] {msg}\n"
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(line)
    except OSError:
        pass
    sys.stderr.write(line)


def ready_tcp(addr: str, timeout: float = 1.0) -> bool:
    host, _, port_s = addr.rpartition(":")
    if not host:
        host = "127.0.0.1"
    try:
        port = int(port_s)
    except ValueError:
        return False
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def ready_http(url: str, timeout: float = 2.0) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return 200 <= int(getattr(r, "status", 200)) < 500
    except (urllib.error.URLError, TimeoutError, ValueError, OSError):
        return False


def ready_cmd(cmd: str, cwd: Optional[str] = None) -> bool:
    try:
        r = subprocess.run(["/bin/sh", "-c", cmd], cwd=cwd, timeout=30)
        return r.returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


def wait_ready(args: argparse.Namespace, log: str, deadline: float,
               proc: subprocess.Popen) -> bool:
    if not (args.ready_cmd or args.ready_tcp or args.ready_http):
        # 先让 setup/exec 错误到达监督器，再报告成功。
        time.sleep(0.25)
        return proc.poll() is None
    while time.time() < deadline:
        if proc.poll() is not None:
            return False
        ok = True
        if args.ready_tcp and not ready_tcp(args.ready_tcp):
            ok = False
        if ok and args.ready_http and not ready_http(args.ready_http):
            ok = False
        if ok and args.ready_cmd and not ready_cmd(args.ready_cmd):
            ok = False
        if ok:
            _log(log, i18n.t("supervisor.ready"))
            return True
        time.sleep(0.2)
    _log(log, i18n.t("supervisor.ready_timeout"))
    return False


def health_ok(args: argparse.Namespace) -> bool:
    if args.health_cmd:
        return ready_cmd(args.health_cmd)
    if args.ready_tcp:
        return ready_tcp(args.ready_tcp)
    if args.ready_http:
        return ready_http(args.ready_http)
    return True


def terminate_tree(proc: subprocess.Popen, stop_timeout: float, log: str) -> None:
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        proc.terminate()
    deadline = time.time() + stop_timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.1)
    _log(log, i18n.t("supervisor.stop_timeout_sigkill", seconds=stop_timeout))
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        proc.kill()


def main() -> int:
    ap = i18n.I18nArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--pidfile", required=True)
    ap.add_argument("--pass-fd", type=int, action="append", default=[])
    ap.add_argument("--status-file")
    ap.add_argument("--ready-cmd")
    ap.add_argument("--ready-tcp")
    ap.add_argument("--ready-http")
    ap.add_argument("--ready-timeout", type=float, default=30.0)
    ap.add_argument("--health-cmd")
    ap.add_argument("--health-interval", type=float, default=0.0)
    ap.add_argument("--health-retries", type=int, default=3)
    ap.add_argument("--restart", choices=("no", "on-failure", "always"), default="no")
    ap.add_argument("--restart-max", type=int, default=3)
    ap.add_argument("--restart-backoff", type=float, default=1.0)
    ap.add_argument("--stop-timeout", type=float, default=10.0)
    ap.add_argument("child", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    def status(value: str) -> None:
        if args.status_file:
            tmp = args.status_file + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(value + "\n")
            os.replace(tmp, args.status_file)

    status("starting")
    for fd in args.pass_fd:
        if fd < 3:
            ap.error(i18n.t("supervisor.pass_fd_must_be_gt_stderr"))
        os.fstat(fd)  # 报告监督器运行前先失败关闭。
    child: List[str] = list(args.child)
    if child and child[0] == "--":
        child = child[1:]
    if not child:
        _log(args.log, i18n.t("supervisor.missing_child_argv"))
        return 2

    stop = {"flag": False}

    def _on_term(signum, frame):  # noqa: ARG001
        stop["flag"] = True

    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)

    with open(args.pidfile, "w", encoding="utf-8") as f:
        f.write(str(os.getpid()))
    with open("/proc/self/stat", encoding="utf-8") as f:
        start_time = f.read().rpartition(") ")[2].split()[19]
    with open(args.pidfile + ".identity", "w", encoding="utf-8") as f:
        f.write(os.readlink("/proc/self/ns/pid") + " " + start_time)

    restarts = 0
    backoff = args.restart_backoff
    while not stop["flag"]:
        _log(args.log, i18n.t("supervisor.starting", cmd=" ".join(child[:3])))
        # bwrap 会消费 BPF 字节。继承的打开文件偏移与监督器共享，
        # 因此每次重启都必须从过滤器开头重新读取。
        for fd in args.pass_fd:
            os.lseek(fd, 0, os.SEEK_SET)
        proc = subprocess.Popen(
            child,
            pass_fds=tuple(args.pass_fd),
            start_new_session=True,
            stdout=open(args.log, "a"),
            stderr=subprocess.STDOUT,
        )
        child_pid_path = args.pidfile + ".child"
        with open(child_pid_path, "w", encoding="utf-8") as f:
            f.write(str(proc.pid))

        if not wait_ready(args, args.log, time.time() + args.ready_timeout, proc):
            status("failed")
            terminate_tree(proc, args.stop_timeout, args.log)
            proc.wait(timeout=args.stop_timeout + 2)
            if args.restart == "no":
                return 1
            restarts += 1
            if restarts > args.restart_max:
                _log(args.log, i18n.t("supervisor.ready_failed_max_restarts"))
                return 1
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)
            continue

        status("ready")
        fails = 0
        while proc.poll() is None and not stop["flag"]:
            if args.health_interval > 0:
                time.sleep(args.health_interval)
                if not health_ok(args):
                    fails += 1
                    _log(args.log, i18n.t("supervisor.health_failed", fails=fails, retries=args.health_retries))
                    if fails >= args.health_retries:
                        _log(args.log, i18n.t("supervisor.health_give_up"))
                        terminate_tree(proc, args.stop_timeout, args.log)
                        break
                else:
                    fails = 0
            else:
                time.sleep(0.5)

        if stop["flag"]:
            status("stopped")
            terminate_tree(proc, args.stop_timeout, args.log)
            proc.wait(timeout=args.stop_timeout + 2)
            _log(args.log, i18n.t("supervisor.stopped"))
            return 0

        rc = proc.wait()
        status("stopped")
        _log(args.log, i18n.t("supervisor.child_exited", rc=rc))
        should = args.restart == "always" or (args.restart == "on-failure" and rc != 0)
        if not should:
            return rc
        restarts += 1
        if restarts > args.restart_max:
            _log(args.log, i18n.t("supervisor.max_restarts"))
            return rc
        time.sleep(backoff)
        backoff = min(backoff * 2, 60)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
