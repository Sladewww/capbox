#!/usr/bin/env bash
# T37 — CAPBOX_DISK_MAX 私有 loop 配额盘（无特权则 SKIP）
set -u
CASE_TITLE="DISK_MAX 私有 loop 配额与 ENOSPC"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖"
  case_finish; exit 0
fi
require_rootfs

# 探测：无 losetup/mkfs/特权则诚实 SKIP
if ! command -v losetup >/dev/null 2>&1 || ! command -v mkfs.ext4 >/dev/null 2>&1; then
  skip_case "缺少 losetup/mkfs.ext4"
  case_finish; exit 0
fi
if [[ ! -e /dev/loop-control ]]; then
  skip_case "无 /dev/loop-control"
  case_finish; exit 0
fi
can_priv=0
if [[ "$(id -u)" -eq 0 ]]; then
  can_priv=1
elif [[ -w /dev/loop-control ]] && command -v mount >/dev/null 2>&1; then
  can_priv=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  can_priv=1
fi
if [[ "$can_priv" -ne 1 ]]; then
  skip_case "无 disk/mount 特权且无 sudo -n（DISK_MAX 需宿主授权，非 rootless）"
  case_finish; exit 0
fi

mkdir -p "$QA_TMP"
cfg_bak=""
if [ -f "$CAPBOX_DIR/config.env" ]; then
  cfg_bak="$QA_TMP/t37-config.bak"
  cp -a "$CAPBOX_DIR/config.env" "$cfg_bak" || cfg_bak=""
fi
restore_cfg() {
  if [ -n "${cfg_bak:-}" ] && [ -f "$cfg_bak" ]; then
    mv -f "$cfg_bak" "$CAPBOX_DIR/config.env"
  fi
}
trap restore_cfg EXIT

# metrics 在配置 DISK_MAX 后应 capable（本环境有特权）
run_cmd env CAPBOX_DISK_MAX=64M CAPBOX_MEMORY_MAX= CAPBOX_CPU_MAX= CAPBOX_PIDS_MAX= \
  "$CAPBOX_BIN" metrics
assert_rc 0 "metrics with DISK_MAX"
assert_out_matches 'disk_status=capable' "有特权时 disk_status=capable"

# 32MiB 写入成功，超限 ENOSPC，退出非 0；不影响宿主其它路径
run_cmd env CAPBOX_DISK_MAX=64M CAPBOX_MEMORY_MAX= CAPBOX_CPU_MAX= CAPBOX_PIDS_MAX= \
  CAPBOX_RESOURCES_MODE=require \
  "$CAPBOX_BIN" exec --timeout 60 -- /bin/sh -c '
    set -e
    dd if=/dev/zero of=/var/lib/capbox-data/ok.bin bs=1M count=32 status=none
    echo write_32MiB=OK
    dd if=/dev/zero of=/var/lib/capbox-data/over.bin bs=1M count=64 conv=fsync
    echo SHOULD_NOT_REACH
  '
assert_ne 0 "$RUN_RC" "超限写入应失败（ENOSPC）"
assert_out_matches 'write_32MiB=OK' "限额内 32MiB 写入成功"
assert_out_matches 'No space left on device' "输出含 ENOSPC 证据"

# 宿主不应残留任何本次测试 loop 或 run/disk 挂载
loops_after=$(sudo -n losetup -a 2>/dev/null || losetup -a 2>/dev/null || true)
assert_out_not_matches 'SHOULD_NOT_REACH' "超限后停止后续命令"
if printf '%s' "$loops_after" | grep -q "$CAPBOX_DIR/run/disk"; then
  _fail "宿主仍残留测试 loop: $loops_after"
else
  _ok "宿主无残留测试 loop"
fi
if findmnt -rn -o TARGET | grep -q "^$CAPBOX_DIR/run/disk/"; then
  _fail "宿主仍挂着 $CAPBOX_DIR/run/disk 下的目录"
else
  _ok "宿主无残留 disk 挂载"
fi

# guest 看不到块设备，非 root 可写，异常退出也回收
run_cmd env CAPBOX_DISK_MAX=64M CAPBOX_MEMORY_MAX= CAPBOX_CPU_MAX= CAPBOX_PIDS_MAX= \
  CAPBOX_RESOURCES_MODE=require "$CAPBOX_BIN" exec --uid 33 --gid 33 --root -- \
  /bin/sh -c 'test ! -e /dev/loop0; touch /var/lib/capbox-data/nonroot; id; exit 42'
assert_eq 42 "$RUN_RC" "保留 guest 异常退出码"
assert_out_matches 'uid=33' "UID 33 在配额盘可写"
assert_out_not_matches 'Permission denied|cannot drop privileges' "降权及写入无权限错误"
loops_after=$(sudo -n losetup -a 2>/dev/null || losetup -a 2>/dev/null || true)
if printf '%s' "$loops_after" | grep -q "$CAPBOX_DIR/run/disk"; then
  _fail "异常退出后残留 loop: $loops_after"
else
  _ok "异常退出后无残留 loop"
fi

# require + 无特权路径：用假 priv 很难；至少确认未设置时 unset
run_cmd env CAPBOX_DISK_MAX= CAPBOX_MEMORY_MAX= "$CAPBOX_BIN" metrics
assert_out_matches 'disk_status=(unset|unavailable)' "清空后 disk 非 capable 冒充"

case_finish
exit 0
