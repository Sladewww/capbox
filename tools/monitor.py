#!/usr/bin/env python3
"""Serve a local, read-only dashboard for one CapBox workspace."""

import argparse
from contextlib import contextmanager
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import threading
import time

HERE = Path(__file__).resolve().parent
AUDIT_KEYS = ("ts", "kind", "event", "status", "exit", "ms")
TASK_KEYS = ("task_id", "status", "created_at", "started_at", "finished_at", "exit_code")
AUDIT_BYTES = 128 * 1024
CGROUP_ROOT = Path("/sys/fs/cgroup")
SERVICE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@+-]*")


def fields(record, keys):
    return {key: record[key] for key in keys
            if key in record and isinstance(record[key], (str, int, float, bool, type(None)))
            and (not isinstance(record[key], float) or math.isfinite(record[key]))}


class AuditTail:
    def __init__(self, state):
        self.state = state
        self.identity = None
        self.offset = 0
        self.events = deque(maxlen=100)

    def open_log(self):
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        state_fd = os.open(self.state, directory_flags)
        try:
            log_fd = os.open("logs", directory_flags, dir_fd=state_fd)
            try:
                return os.open("audit.jsonl", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                               dir_fd=log_fd)
            finally:
                os.close(log_fd)
        finally:
            os.close(state_fd)

    def read(self):
        try:
            fd = self.open_log()
        except FileNotFoundError:
            self.identity = None
            self.events.clear()
            return []

        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("Audit input is not a regular file")
            identity = (info.st_dev, info.st_ino)
            if identity != self.identity or info.st_size < self.offset:
                self.identity = identity
                self.offset = 0
                self.events.clear()
            start = max(self.offset, info.st_size - AUDIT_BYTES)
            stream.seek(start)
            if start != self.offset:
                stream.readline(AUDIT_BYTES)
            data = stream.read(max(0, info.st_size - stream.tell()))
            lines = data.split(b"\n")
            self.offset = stream.tell() - len(lines.pop())
            for line in lines:
                try:
                    record = json.loads(line, parse_constant=lambda value: None)
                    if isinstance(record, dict):
                        self.events.append(fields(record, AUDIT_KEYS))
                except (ValueError, RecursionError):
                    continue
        return list(reversed(self.events))


class CgroupUsage:
    def __init__(self, path):
        self.path = path
        self.previous = None

    def read(self):
        if self.path is None:
            return None
        with cgroup_directory(self.path) as directory:
            info = os.fstat(directory)
            cpu = dict(line.split() for line in self.counter(directory, "cpu.stat").splitlines())
            memory = int(self.counter(directory, "memory.current"))
            pids = int(self.counter(directory, "pids.current"))
        identity = (info.st_dev, info.st_ino)
        sample = (identity, time.monotonic(), int(cpu["usage_usec"]))
        prior, self.previous = self.previous, sample
        percent = None
        if prior and prior[0] == identity and sample[2] >= prior[2]:
            percent = round((sample[2] - prior[2]) / ((sample[1] - prior[1]) * 10000), 1)
        return {"cpu_percent": percent, "memory_bytes": memory, "pids": pids}

    @staticmethod
    def counter(directory, name):
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        with os.fdopen(fd, encoding="ascii") as stream:
            return stream.read()


@contextmanager
def cgroup_directory(path):
    fd = os.open(path, os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        yield fd
    finally:
        os.close(fd)


class Monitor:
    def __init__(self, workspace, cli, cgroup):
        self.workspace = workspace
        self.cli = cli
        self.audit = AuditTail(workspace / ".capbox")
        self.usage = CgroupUsage(cgroup)
        self.condition = threading.Condition()
        self.snapshot = {}
        self.payload = "{}"
        self.revision = 0
        self.stop = threading.Event()

    def command(self, *args, env=None):
        result = subprocess.run([str(self.cli), "--root", str(self.workspace), *args],
                                cwd=self.workspace, env=env, capture_output=True, timeout=3, check=True)
        return json.loads(result.stdout)

    def overview(self):
        status = self.command("status", "--json")
        return dict(fields(status, ("distro", "rootfs_bytes", "net", "version")),
                    daemon=fields(status["daemon"], ("running", "uptime")))

    def resources(self):
        return fields(self.command("metrics", "--json"),
                      ("cgroup_status", "disk_status", "mode",
                       "memory_max", "cpu_max", "pids_max"))

    def tasks(self):
        # The CLI normally audits task listings. The monitor polls this read repeatedly.
        tasks = self.command("task", "list", "--json",
                             env=dict(os.environ, CAPBOX_AUDIT="off"))["tasks"]
        tasks.sort(key=lambda task: task.get("created_at", 0), reverse=True)
        return [fields(task, TASK_KEYS) for task in tasks[:100]]

    def services(self):
        directory = self.workspace / ".capbox" / "services"
        try:
            entries = sorted(directory.iterdir())
        except FileNotFoundError:
            return []
        return [self.service(path.stem) for path in entries
                if path.suffix == ".env" and SERVICE_NAME.fullmatch(path.stem) and path.is_file()]

    def service(self, name):
        try:
            result = self.command("service", "status", name, "--json")
            if result.get("state") in ("running", "stopped"):
                return {"name": name, "state": result["state"]}
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        return {"name": name, "state": "unavailable"}

    def collect(self, name, reader):
        try:
            data = reader()
            record = {"data": data, "sampled_at": time.time(), "error": False}
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            record = None
        with self.condition:
            if record is None:
                prior = self.snapshot.get(name, {"data": None, "sampled_at": None})
                record = dict(prior, error=True)
            self.snapshot[name] = record
            self.payload = json.dumps(self.snapshot, allow_nan=False)
            self.revision += 1
            self.condition.notify_all()

    def collect_periodically(self, interval, readers):
        while not self.stop.is_set():
            started = time.monotonic()
            for name, reader in readers:
                self.collect(name, reader)
            self.stop.wait(max(0, interval - (time.monotonic() - started)))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        self.request.settimeout(10)
        super().setup()

    def do_GET(self):
        if self.headers.get("Host") != f"127.0.0.1:{self.server.server_port}":
            return self.send_error(403)
        if self.path == "/events":
            return self.events()
        asset = {"/": ("monitor.html", "text/html"), "/monitor.js": ("monitor.js", "text/javascript")}
        if self.path not in asset:
            return self.send_error(404)
        name, content_type = asset[self.path]
        body = (HERE / name).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; "
                         "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(body)

    def events(self):
        monitor = self.server.monitor
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        seen = -1
        try:
            while not monitor.stop.is_set():
                with monitor.condition:
                    monitor.condition.wait_for(
                        lambda: monitor.revision != seen or monitor.stop.is_set(), timeout=10)
                    if monitor.revision != seen:
                        seen = monitor.revision
                        message = f"data: {monitor.payload}\n\n"
                    else:
                        message = ": heartbeat\n\n"
                self.wfile.write(message.encode("utf-8"))
                self.wfile.flush()
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="Initialized CapBox workspace")
    parser.add_argument("--port", type=int, default=8765, help="Loopback HTTP port")
    parser.add_argument("--cgroup", type=Path, help="Optional dedicated CapBox cgroup v2 directory")
    args = parser.parse_args()
    workspace = args.root.resolve()
    if workspace in (Path("/"), Path.home().resolve()):
        parser.error("--root must be a project workspace")
    cli = workspace / ".capbox" / "bin" / "capbox"
    if not cli.is_file():
        parser.error("--root must contain .capbox/bin/capbox; run capbox bootstrap first")
    cgroup = args.cgroup.resolve() if args.cgroup else None
    if cgroup is not None and CGROUP_ROOT not in cgroup.parents:
        parser.error("--cgroup must be a dedicated directory under /sys/fs/cgroup")
    monitor = Monitor(workspace, cli, cgroup)
    with ThreadingHTTPServer(("127.0.0.1", args.port), Handler) as server:
        server.monitor = monitor
        schedules = [
            (1, (("audit", monitor.audit.read), ("usage", monitor.usage.read))),
            (2, (("tasks", monitor.tasks), ("services", monitor.services))),
            (15, (("overview", monitor.overview), ("resources", monitor.resources))),
        ]
        threads = [threading.Thread(target=monitor.collect_periodically, args=schedule, daemon=True)
                   for schedule in schedules]
        for thread in threads:
            thread.start()
        print(f"CapBox monitor: http://127.0.0.1:{server.server_port}/", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            monitor.stop.set()
            with monitor.condition:
                monitor.condition.notify_all()


if __name__ == "__main__":
    main()
