#!/usr/bin/env bash
# T25 — 资源限额：校验 + 诚实的未应用告警 / 降级
set -u
CASE_TITLE="资源限额：校验与诚实告警"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖资源限额"
  case_finish
  exit 0
fi
require_rootfs

mkdir -p "$QA_TMP"
cfg_bak=""
if [ -f "$CAPBOX_DIR/config.env" ]; then
  cfg_bak="$QA_TMP/t25-config.bak"
  cp -a "$CAPBOX_DIR/config.env" "$cfg_bak" 2>/dev/null || cfg_bak=""
fi
restore_cfg() {
  if [ -n "${cfg_bak:-}" ] && [ -f "$cfg_bak" ]; then
    mv -f "$cfg_bak" "$CAPBOX_DIR/config.env"
  fi
}
trap restore_cfg EXIT

run_cmd "$CAPBOX_BIN" config set CAPBOX_MEMORY_MAX not-a-size
assert_rc 2 "非法 MEMORY_MAX 被拒绝"

run_cmd "$CAPBOX_BIN" config set CAPBOX_PIDS_MAX abc
assert_rc 2 "非法 PIDS_MAX 被拒绝"

run_cmd "$CAPBOX_BIN" config set CAPBOX_CPU_MAX 50%
assert_rc 0 "合法 CPU_MAX=50%"
run_cmd "$CAPBOX_BIN" config set CAPBOX_MEMORY_MAX 64M
assert_rc 0 "合法 MEMORY_MAX=64M"
run_cmd "$CAPBOX_BIN" config set CAPBOX_PIDS_MAX 64
assert_rc 0 "合法 PIDS_MAX=64"

# doctor 应提到资源限额（PASS 配置项或 WARN 无 cgroup）
run_cmd "$CAPBOX_BIN" doctor
assert_rc 0 "doctor 在资源限额配置下仍可通过（允许 WARN）"
assert_out_matches_i 'MEMORY_MAX|资源限额|cgroup|RLIMIT' "doctor 报告资源限额状态"

# exec 应成功；若无 cgroup，stderr 应出现诚实 WARN（不假装已应用 CPU/PIDS）
run_cmd "$CAPBOX_BIN" exec --timeout 15 -- sh -c 'echo resource-ok'
assert_rc 0 "配置限额后 exec 仍可用"
assert_stdout_contains "resource-ok" "exec 输出正常"
# 在本 CI/沙箱常见「无 cgroup 委派」：应看到 WARN；若有 cgroup 则可能无 WARN——两种都诚实
if printf '%s' "$RUN_STDERR$RUN_STDOUT" | grep -qiE '未应用|RLIMIT_AS|cgroup'; then
  _ok "资源限额路径发出了诚实状态信息"
else
  # 可能已通过 cgroup 静默应用；用 status/config 仍能读到值即可
  run_cmd "$CAPBOX_BIN" config get CAPBOX_MEMORY_MAX
  assert_stdout_eq "64M" "MEMORY_MAX 仍保留在配置中"
  _ok "未看到 WARN（可能 cgroup 已应用）；配置值保留"
fi

case_finish
exit 0
