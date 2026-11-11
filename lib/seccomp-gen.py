#!/usr/bin/env python3
"""为 CapBox untrusted/strict 配置生成 seccomp BPF。

通过 ctypes 使用 libseccomp（不依赖 python3-seccomp 包）。
将原始 BPF 写入 --out（或以二进制写到 stdout）。成功时退出码 0。

配置：
  untrusted — 拒绝 mount/pivot/module/kexec/bpf/userfaultfd/open_by_handle_at/
              unshare/setns/io_uring
  strict    — untrusted + ptrace + perf_event_open + process_vm_{read,write}v

有意不拒绝 clone3：glibc 用它创建线程。命名空间创建通过
unshare/setns 拦截（idmap 关闭时还有 bwrap --disable-userns）。
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import errno
import os
import sys
from pathlib import Path

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
import i18n

# 我们关心的 x86_64 / aarch64 系统调用号。尽量通过 libseccomp 解析。
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
        "move_mount": 429,
        "open_tree": 428,
        "fspick": 433,
        "mount_setattr": 442,
        "unshare": 272,
        "setns": 308,
        "clone3": 435,
        "io_uring_setup": 425,
        "io_uring_enter": 426,
        "io_uring_register": 427,
        "memfd_create": 319,
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
        "move_mount": 429,
        "open_tree": 428,
        "fspick": 433,
        "mount_setattr": 442,
        "unshare": 97,
        "setns": 268,
        "clone3": 435,
        "io_uring_setup": 425,
        "io_uring_enter": 426,
        "io_uring_register": 427,
        "memfd_create": 279,
    },
}

UNTRUSTED = [
    "mount", "umount2", "pivot_root", "swapon", "swapoff", "reboot",
    "init_module", "delete_module", "finit_module",
    "kexec_load", "kexec_file_load", "bpf", "userfaultfd",
    "open_by_handle_at", "name_to_handle_at",
    "keyctl", "add_key", "request_key",
    "fsopen", "fsconfig", "fsmount", "move_mount", "open_tree", "mount_setattr",
    "unshare", "setns",
    "io_uring_setup", "io_uring_enter", "io_uring_register",
]

STRICT_EXTRA = [
    "ptrace", "perf_event_open", "process_vm_readv", "process_vm_writev",
]

# 来自 linux/seccomp.h / libseccomp 的动作编码
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
        raise SystemExit(i18n.t("seccomp.lib_not_found"))
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


def generate(profile: str, out_path: str, deny_exec_memfd: bool = False) -> int:
    arch = _arch()
    names = [] if profile == "compat" else list(UNTRUSTED)
    if profile == "strict":
        names += STRICT_EXTRA
    elif profile not in ("untrusted", "compat"):
        raise SystemExit(i18n.t("seccomp.unknown_profile", profile=profile))
    if profile == "compat" and not deny_exec_memfd:
        raise SystemExit(i18n.t("seccomp.compat_needs_extra_restriction"))

    lib = _load_lib()
    lib.seccomp_init.restype = ctypes.c_void_p
    lib.seccomp_init.argtypes = [ctypes.c_uint32]
    lib.seccomp_rule_add.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint]
    lib.seccomp_export_bpf.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.seccomp_release.argtypes = [ctypes.c_void_p]

    ctx = lib.seccomp_init(SCMP_ACT_ALLOW)
    if not ctx:
        raise SystemExit(i18n.t("seccomp.init_failed"))

    added = 0
    missing = []
    if deny_exec_memfd:
        # APK 3 用可执行 memfd 跑脚本。即使创建成功，AppArmor 也可能拒绝 exec。
        # 返回 ENOSYS 可让 APK 走磁盘回退；这只追加一条限制，不改动各配置已有规则。
        class ArgCmp(ctypes.Structure):
            _fields_ = [("arg", ctypes.c_uint), ("op", ctypes.c_uint),
                        ("datum_a", ctypes.c_uint64), ("datum_b", ctypes.c_uint64)]

        nr = _resolve_nr(lib, "memfd_create", arch)
        rc = -1 if nr is None else lib.seccomp_rule_add(
            ctx, SCMP_ACT_ERRNO(errno.ENOSYS), nr, 1,
            ArgCmp(1, 7, 0x10, 0x10))  # SCMP_CMP_MASKED_EQ, MFD_EXEC
        if rc:
            missing.append(f"memfd_create(add={rc})")
        else:
            added += 1
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
        raise SystemExit(i18n.t("seccomp.export_failed", rc=rc))

    size = os.path.getsize(out_path)
    if size < 8:
        raise SystemExit(i18n.t("seccomp.bpf_too_small", size=size))
    if missing:
        try:
            os.remove(out_path)
        except OSError:
            pass
        raise SystemExit(
            i18n.t("seccomp.unresolved_syscalls", profile=profile, missing=",".join(missing))
        )
    sys.stderr.write(i18n.t("seccomp.generated", profile=profile, arch=arch, rules=added, bytes=size) + "\n")
    return 0


def main() -> int:
    ap = i18n.I18nArgumentParser(description=i18n.t("seccomp.tool_description"))
    ap.add_argument("--profile", choices=("compat", "untrusted", "strict"), required=True)
    ap.add_argument("--deny-exec-memfd", action="store_true")
    ap.add_argument("--out", required=True, help=i18n.t("seccomp.help_out"))
    args = ap.parse_args()
    return generate(args.profile, args.out, args.deny_exec_memfd)


if __name__ == "__main__":
    raise SystemExit(main())
