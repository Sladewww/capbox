#!/usr/bin/env python3
"""Generate a seccomp BPF blob for CapBox untrusted/strict profiles.

Uses libseccomp via ctypes (no python3-seccomp package required).
Writes raw BPF to --out (or stdout as binary). Exit 0 on success.

Profiles:
  untrusted — deny mount/pivot/module/kexec/bpf/userfaultfd/open_by_handle_at/...
  strict    — untrusted + ptrace + perf_event_open + process_vm_{read,write}v
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import os
import sys

# x86_64 / aarch64 syscall numbers we care about. We resolve via libseccomp when possible.
_FALLBACK_NR = {
    "x86_64": {
        "mount": 165,
        "umount2": 166,
        "pivot_root": 155,
        "swapon": 167,
        "swapoff": 168,
        "reboot": 169,
        "init_module": 175,
        "delete_module": 176,
        "finit_module": 313,
        "kexec_load": 246,
        "kexec_file_load": 320,
        "bpf": 321,
        "userfaultfd": 323,
        "open_by_handle_at": 304,
        "name_to_handle_at": 303,
        "keyctl": 250,
        "add_key": 248,
        "request_key": 249,
        "ptrace": 101,
        "perf_event_open": 298,
        "process_vm_readv": 310,
        "process_vm_writev": 311,
        "fsopen": 430,
        "fsconfig": 431,
        "fsmount": 432,
        "move_mount": 433,
        "open_tree": 428,
        "fspick": 433,
        "mount_setattr": 442,
        "unshare": 272,
        "setns": 308,
        "clone3": 435,
    },
    "aarch64": {
        "mount": 40,
        "umount2": 39,
        "pivot_root": 41,
        "swapon": 224,
        "swapoff": 225,
        "reboot": 142,
        "init_module": 105,
        "delete_module": 106,
        "finit_module": 273,
        "kexec_load": 104,
        "kexec_file_load": 294,
        "bpf": 280,
        "userfaultfd": 282,
        "open_by_handle_at": 265,
        "name_to_handle_at": 264,
        "keyctl": 219,
        "add_key": 217,
        "request_key": 218,
        "ptrace": 117,
        "perf_event_open": 241,
        "process_vm_readv": 270,
        "process_vm_writev": 271,
        "fsopen": 430,
        "fsconfig": 431,
        "fsmount": 432,
        "move_mount": 433,
        "open_tree": 428,
        "fspick": 433,
        "mount_setattr": 442,
        "unshare": 97,
        "setns": 268,
        "clone3": 435,
    },
}

UNTRUSTED = [
    "mount", "umount2", "pivot_root", "swapon", "swapoff", "reboot",
    "init_module", "delete_module", "finit_module",
    "kexec_load", "kexec_file_load", "bpf", "userfaultfd",
    "open_by_handle_at", "name_to_handle_at",
    "keyctl", "add_key", "request_key",
    "fsopen", "fsconfig", "fsmount", "move_mount", "open_tree", "mount_setattr",
]

STRICT_EXTRA = [
    "ptrace", "perf_event_open", "process_vm_readv", "process_vm_writev",
]

# Action encodings from linux/seccomp.h / libseccomp
SCMP_ACT_ALLOW = 0x7FFF0000
SCMP_ACT_ERRNO = lambda errno: 0x00050000 | (errno & 0xFFFF)  # noqa: E731


def _arch() -> str:
    m = os.uname().machine
    if m in ("x86_64", "amd64"):
        return "x86_64"
    if m in ("aarch64", "arm64"):
        return "aarch64"
    return m


def _load_lib():
    path = ctypes.util.find_library("seccomp")
    if not path:
        raise SystemExit("libseccomp not found (install libseccomp)")
    return ctypes.CDLL(path)


def _resolve_nr(lib, name: str, arch: str) -> int | None:
    # seccomp_syscall_resolve_name
    if hasattr(lib, "seccomp_syscall_resolve_name"):
        lib.seccomp_syscall_resolve_name.argtypes = [ctypes.c_char_p]
        lib.seccomp_syscall_resolve_name.restype = ctypes.c_int
        nr = lib.seccomp_syscall_resolve_name(name.encode())
        if nr >= 0:
            return int(nr)
    return _FALLBACK_NR.get(arch, {}).get(name)


def generate(profile: str, out_path: str) -> int:
    arch = _arch()
    names = list(UNTRUSTED)
    if profile == "strict":
        names += STRICT_EXTRA
    elif profile != "untrusted":
        raise SystemExit(f"unknown profile for seccomp: {profile}")

    lib = _load_lib()
    lib.seccomp_init.restype = ctypes.c_void_p
    lib.seccomp_init.argtypes = [ctypes.c_uint32]
    lib.seccomp_rule_add.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint]
    lib.seccomp_export_bpf.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.seccomp_release.argtypes = [ctypes.c_void_p]

    ctx = lib.seccomp_init(SCMP_ACT_ALLOW)
    if not ctx:
        raise SystemExit("seccomp_init failed")

    added = 0
    missing = []
    for name in names:
        nr = _resolve_nr(lib, name, arch)
        if nr is None:
            missing.append(name)
            continue
        rc = lib.seccomp_rule_add(ctx, SCMP_ACT_ERRNO(1), int(nr), 0)
        if rc != 0:
            missing.append(f"{name}(add={rc})")
            continue
        added += 1

    fd = os.open(out_path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    try:
        rc = lib.seccomp_export_bpf(ctx, fd)
    finally:
        os.close(fd)
    lib.seccomp_release(ctx)
    if rc != 0:
        raise SystemExit(f"seccomp_export_bpf failed: {rc}")

    size = os.path.getsize(out_path)
    if size < 8:
        raise SystemExit(f"BPF too small ({size}); libseccomp export failed")
    sys.stderr.write(f"seccomp-gen profile={profile} arch={arch} rules={added} bytes={size}")
    if missing:
        sys.stderr.write(f" skipped={','.join(missing)}")
    sys.stderr.write("\n")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--profile", choices=("untrusted", "strict"), required=True)
    ap.add_argument("--out", required=True, help="BPF output path")
    args = ap.parse_args()
    return generate(args.profile, args.out)


if __name__ == "__main__":
    raise SystemExit(main())
