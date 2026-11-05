#!/usr/bin/env python3
"""Host-side CapBox service supervisor: ready wait, health, restart backoff, stop timeout.

Launched by service.sh. Never reads secrets from env files beyond what's passed
as explicit CLI flags. Child is the already-constructed bwrap argv after `--`.
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
from typing import List, Optional


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


def wait_ready(args: argparse.Namespace, log: str, deadline: float) -> bool:
    if not (args.ready_cmd or args.ready_tcp or args.ready_http):
        return True
    while time.time() < deadline:
        ok = True
        if args.ready_tcp and not ready_tcp(args.ready_tcp):
            ok = False
        if ok and args.ready_http and not ready_http(args.ready_http):
            ok = False
        if ok and args.ready_cmd and not ready_cmd(args.ready_cmd):
            ok = False
        if ok:
            _log(log, "ready: ok")
            return True
        time.sleep(0.2)
    _log(log, "ready: timeout")
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
    _log(log, f"stop timeout {stop_timeout}s → SIGKILL")
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        proc.kill()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--pidfile", required=True)
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
    child: List[str] = list(args.child)
    if child and child[0] == "--":
        child = child[1:]
    if not child:
        _log(args.log, "supervisor: missing child argv")
        return 2

    stop = {"flag": False}

    def _on_term(signum, frame):  # noqa: ARG001
        stop["flag"] = True

    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)

    with open(args.pidfile, "w", encoding="utf-8") as f:
        f.write(str(os.getpid()))

    restarts = 0
    backoff = args.restart_backoff
    while not stop["flag"]:
        _log(args.log, f"supervisor: start {' '.join(child[:3])}...")
        proc = subprocess.Popen(
            child,
            start_new_session=True,
            stdout=open(args.log, "a"),
            stderr=subprocess.STDOUT,
        )
        child_pid_path = args.pidfile + ".child"
        with open(child_pid_path, "w", encoding="utf-8") as f:
            f.write(str(proc.pid))

        if not wait_ready(args, args.log, time.time() + args.ready_timeout):
            terminate_tree(proc, args.stop_timeout, args.log)
            proc.wait(timeout=args.stop_timeout + 2)
            if args.restart == "no":
                return 1
            restarts += 1
            if restarts > args.restart_max:
                _log(args.log, "restart max exceeded after ready failure")
                return 1
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)
            continue

        fails = 0
        while proc.poll() is None and not stop["flag"]:
            if args.health_interval > 0:
                time.sleep(args.health_interval)
                if not health_ok(args):
                    fails += 1
                    _log(args.log, f"health fail {fails}/{args.health_retries}")
                    if fails >= args.health_retries:
                        _log(args.log, "health: giving up → restart/stop")
                        terminate_tree(proc, args.stop_timeout, args.log)
                        break
                else:
                    fails = 0
            else:
                time.sleep(0.5)

        if stop["flag"]:
            terminate_tree(proc, args.stop_timeout, args.log)
            proc.wait(timeout=args.stop_timeout + 2)
            _log(args.log, "supervisor: stopped")
            return 0

        rc = proc.wait()
        _log(args.log, f"child exited rc={rc}")
        should = args.restart == "always" or (args.restart == "on-failure" and rc != 0)
        if not should:
            return rc
        restarts += 1
        if restarts > args.restart_max:
            _log(args.log, "restart max exceeded")
            return rc
        time.sleep(backoff)
        backoff = min(backoff * 2, 60)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
