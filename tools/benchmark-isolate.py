#!/usr/bin/env python3
"""Measure CapBox Linux task startup with a disposable Alpine fixture."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import stat
import subprocess
import tempfile
from threading import Barrier
import time

REPO = Path(__file__).resolve().parents[1]
MIB = 1024**2


def command(*argv, env=None):
    return subprocess.run(argv, env=env, text=True, capture_output=True, timeout=180)


def checked(result):
    if result.returncode:
        raise RuntimeError(f"{result.args}: {result.returncode}\n{result.stdout}{result.stderr}")
    return result.stdout


def allocated_bytes(path):
    return int(checked(command("du", "-s", "-B1", path)).split()[0]) if path.exists() else 0


def tree(path):
    if not path.exists():
        return {"allocated_bytes": 0, "logical_bytes": 0, "files": 0, "symlinks": 0}
    allocated = allocated_bytes(path)
    stats = [p.lstat() for p in path.rglob("*") if not p.is_dir() or p.is_symlink()]
    return {"allocated_bytes": allocated, "logical_bytes": sum(s.st_size for s in stats),
            "files": sum(1 for s in stats if stat.S_ISREG(s.st_mode)),
            "symlinks": sum(1 for s in stats if stat.S_ISLNK(s.st_mode))}


def fill(path, mib, count, seed):
    if not count:
        return
    path.mkdir()
    size, remainder = divmod(mib * MIB, count)
    rng = random.Random(seed)
    for i in range(count):
        (path / f"{i:05d}").write_bytes(rng.randbytes(size + (i < remainder)))


def benchmark(workspace, runtime, args):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CAPBOX_", "_CAPBOX_"))}
    env.update(XDG_RUNTIME_DIR=str(runtime), CAPBOX_NET=args.net, CAPBOX_IDMAP="off",
               CAPBOX_SECURITY_PROFILE="untrusted", CAPBOX_OVERLAY="0", CAPBOX_AUDIT="off",
               CAPBOX_LANG="en")

    def cli(*argv):
        return command(REPO / "bin/capbox", "--root", workspace, *argv, env=env)

    checked(cli("bootstrap"))
    private = runtime / f"capbox-{os.getuid()}" / hashlib.sha256(
        os.fsencode(workspace / ".capbox")).hexdigest()[:32] / "tasks"
    rootfs = workspace / ".capbox/os/alpine"
    shutil.copytree(args.alpine_rootfs, rootfs, symlinks=True)
    checked(cli("exec", "--", "true"))
    print(json.dumps({"kind": "host", "repo": checked(command("git", "-C", REPO, "rev-parse", "HEAD")).strip(),
                      "kernel": platform.release(), "arch": platform.machine(),
                      "os": platform.freedesktop_os_release()["PRETTY_NAME"],
                      "cpu": next((line.split(":", 1)[1].strip() for line in
                                   Path("/proc/cpuinfo").read_text().splitlines()
                                   if line.startswith("model name")), None),
                      "available_cpus": len(os.sched_getaffinity(0)),
                      "memory": Path("/proc/meminfo").read_text().splitlines()[0],
                      "filesystem": checked(command("df", "-T", workspace, runtime)).splitlines(),
                      "bwrap": checked(command("bwrap", "--version")).strip(),
                      "python": platform.python_version(), "net": args.net,
                      "idmap": "off", "profile": "untrusted", "overlay": "0",
                      "cache": "warm; no cache drops", "repeats": args.repeats}), flush=True)

    def start(isolated, barrier, guest):
        barrier.wait()
        t0 = time.monotonic_ns()
        result = cli("task", "start", *(["--isolate"] if isolated else []), "--",
                     "sh", "-ec", guest)
        acknowledgement = time.monotonic_ns()
        state = json.loads(checked(result))
        job = private / state["task_id"]
        stdout = job / "stdout.log"
        deadline = time.monotonic() + 20
        while not stdout.exists() or "ready" not in stdout.read_text():
            if time.monotonic() >= deadline:
                stderr = cli("task", "logs", job.name, "--stream", "stderr")
                raise RuntimeError(f"guest readiness timed out: {stderr.stdout}{stderr.stderr}")
            time.sleep(0.005)
        return job, (acknowledgement - t0) / 1e6, (time.monotonic_ns() - t0) / 1e6

    for work_mib, work_count, rootfs_extra, rootfs_count in (
        (0, 0, 0, 0), (64, 1024, 0, 0), (0, 0, 256, 2048), (64, 1024, 256, 2048)
    ):
        work = workspace / "payload"
        root_payload = rootfs / "benchmark-payload"
        fill(work, work_mib, work_count, 100)
        fill(root_payload, rootfs_extra, rootfs_count, 101)
        label = f"work-{work_mib}MiB-rootfs-extra-{rootfs_extra}MiB"
        print(json.dumps({"kind": "fixture", "fixture": label, "workspace": tree(work),
                          "rootfs": tree(rootfs)}), flush=True)

        for concurrency in (1, args.parallel):
            for isolated in (False, True):
                for repeat in range(1, args.repeats + 1):
                    barrier = Barrier(concurrency)
                    with ThreadPoolExecutor(max_workers=concurrency) as pool:
                        pending = [pool.submit(start, isolated, barrier, "echo ready; sleep 120")
                                   for _ in range(concurrency)]
                        arrivals = [future.result() for future in pending]
                    try:
                        for job, ack_ms, ready_ms in sorted(arrivals, key=lambda item: item[2]):
                            view = job / "workspace"
                            job_bytes = allocated_bytes(job)
                            work_bytes = allocated_bytes(view / "payload")
                            rootfs_bytes = allocated_bytes(view / ".capbox/os/alpine")
                            review_bytes = allocated_bytes(job / "review.git")
                            print(json.dumps({"kind": "sample", "fixture": label, "repeat": repeat,
                                              "concurrency": concurrency, "isolated": isolated,
                                              "ack_ms": round(ack_ms, 2), "ready_ms": round(ready_ms, 2),
                                              "job_bytes": job_bytes, "work_bytes": work_bytes,
                                              "rootfs_bytes": rootfs_bytes, "review_bytes": review_bytes}),
                                  flush=True)
                    finally:
                        for job, _, _ in arrivals:
                            checked(cli("task", "cancel", job.name))
                        for job, _, _ in arrivals:
                            result = cli("task", "wait", job.name, "--timeout", "10")
                            if result.returncode != 143:
                                checked(result)
                                raise RuntimeError(f"expected cancellation: {result.stdout}")
                            checked(cli("task", "rm", job.name))
                            if job.exists():
                                raise RuntimeError("task rm left job files")
        for path in (work, root_payload):
            if path.exists():
                shutil.rmtree(path)

    with ThreadPoolExecutor(max_workers=2) as pool:
        barrier = Barrier(2)
        writer = pool.submit(start, True, barrier,
                             "echo private > /workspace/marker; echo private > /etc/marker; echo ready; sleep 120")
        peer = pool.submit(start, True, barrier,
                           "echo ready; sleep 3; test ! -e /workspace/marker && test ! -e /etc/marker")
        writer_job, _, _ = writer.result()
        peer_job, _, _ = peer.result()
    checked(cli("task", "wait", peer_job.name, "--timeout", "10"))
    checked(cli("task", "cancel", writer_job.name))
    if cli("task", "wait", writer_job.name, "--timeout", "10").returncode != 143:
        raise RuntimeError("writer did not reach cancelled")
    if (workspace / "marker").exists() or (rootfs / "etc/marker").exists():
        raise RuntimeError("writer changed the source")
    failed = json.loads(checked(cli("task", "start", "--isolate", "--", "sh", "-c", "exit 7")))["task_id"]
    result = cli("task", "wait", failed, "--timeout", "10")
    if result.returncode != 7 or json.loads(result.stdout)["status"] != "failed":
        raise RuntimeError("failure status did not retain its exit code")
    for task_id in (writer_job.name, peer_job.name, failed):
        checked(cli("task", "rm", task_id))
    if list(private.iterdir()):
        raise RuntimeError("job directory is not empty after removal")
    print(json.dumps({"kind": "isolation_and_cleanup", "result": "passed"}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("alpine_rootfs", type=lambda value: Path(value).resolve())
    parser.add_argument("--tmpdir", default="/tmp", type=lambda value: Path(value).resolve())
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--parallel", type=int, choices=range(2, 9), default=4)
    parser.add_argument("--net", choices=("none", "open"), default="none")
    args = parser.parse_args()
    if args.repeats < 1 or not os.path.lexists(args.alpine_rootfs / "bin/sh"):
        parser.error("supply a bootstrapped Alpine rootfs and a positive repeat count")
    with tempfile.TemporaryDirectory(prefix="", dir=args.tmpdir) as temporary:
        base = Path(temporary)
        workspace, runtime = base / "ws", base / "r"
        workspace.mkdir()
        runtime.mkdir(mode=0o700)
        if len(str(runtime / f"capbox-{os.getuid()}" / ("0" * 32))) > 60:
            parser.error("--tmpdir path is too long for CapBox's private runtime directory")
        benchmark(workspace, runtime, args)


if __name__ == "__main__":
    main()
