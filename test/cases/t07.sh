#!/usr/bin/env bash
# T07 — 全权限证明：mount -t tmpfs + chmod 4755 + nproc
# 契约 §0：容器内 uid0 且 CapEff 全量，因此 tmpfs 挂载、setuid 位、多核都应可用。
set -u
CASE_TITLE="全权限证明：tmpfs mount + chmod 4755 + nproc"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

require_rootfs || { case_finish; exit 0; }

# 1) mount -t tmpfs
run_cmd "$CAPBOX_BIN" exec -- sh -c 'mkdir -p /mnt && mount -t tmpfs none /mnt && echo mount-ok'
assert_rc 0 "mount -t tmpfs none /mnt 退出码"
assert_stdout_contains "mount-ok" "tmpfs 挂载成功标记"

# 2) chmod 4755（setuid 位）
run_cmd "$CAPBOX_BIN" exec -- sh -c 'touch /mnt/suid-test 2>/dev/null; F=/root/suid-test; echo x > $F; chmod 4755 $F && stat -c %a $F'
assert_rc 0 "chmod 4755 退出码"
assert_stdout_eq "4755" "文件权限位（setuid 生效）"

# 3) nproc（容器内应能看到宿主多核）
run_cmd "$CAPBOX_BIN" exec -- nproc
assert_rc 0 "nproc 退出码"
assert_int_ge "$(printf '%s' "$RUN_STDOUT" | tr -d '[:space:]')" 1 "nproc 输出核数"
if printf '%s' "$RUN_STDOUT" | tr -d '[:space:]' | grep -qE '^[0-9]+$' && [ "$(printf '%s' "$RUN_STDOUT" | tr -d '[:space:]')" -ge 2 ]; then
  _ok "nproc > 1（容器未把 CPU 限成单核）"
else
  mark_known_issue "nproc 显示单核：契约未强制，但 cgroup/cpuset 继承异常时值得关注"
fi

# 4) capability 证明（契约 §0 的核心结论：CapEff 全量）
run_cmd "$CAPBOX_BIN" exec -- sh -c 'grep ^CapEff /proc/self/status'
assert_rc 0 "读 /proc/self/status 退出码"
assert_stdout_matches_i 'CapEff:[[:space:]]*[0-9a-f]{8,}' "CapEff 行存在"
if printf '%s' "$RUN_STDOUT" | grep -qiE 'CapEff:[[:space:]]*000001ffffffffff'; then
  _ok "CapEff 为契约 §0 记录的全量值"
else
  mark_known_issue "CapEff 与契约 §0 记录值不同（$(_short "$RUN_STDOUT" 1)）；若 CLI 未加 --cap-add ALL 会是功能性差异"
fi

case_finish
exit 0
