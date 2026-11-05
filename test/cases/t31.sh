#!/usr/bin/env bash
# T31 — 资源 require fail-closed + metrics 诚实
set -u
CASE_TITLE="资源 require 与 metrics 诚实语义"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖"
  case_finish; exit 0
fi
require_rootfs

run_cmd "$CAPBOX_BIN" metrics
assert_rc 0 "metrics"
assert_stdout_matches 'cgroup_status=' "metrics 含 cgroup_status"

run_cmd "$CAPBOX_BIN" metrics --json
assert_rc 0 "metrics json"
assert_stdout_matches '"cgroup_status"' "json 含 cgroup_status"

run_cmd "$CAPBOX_BIN" metrics
cgroup_line="$RUN_STDOUT"
if printf '%s' "$cgroup_line" | grep -q 'cgroup_status=ready'; then
  _ok "宿主有 cgroup 委派；跳过 require 负向（改为验证配置键）"
  run_cmd "$CAPBOX_BIN" config set CAPBOX_RESOURCES_MODE require
  assert_rc 0 "可设置 RESOURCES_MODE=require"
  run_cmd "$CAPBOX_BIN" config set CAPBOX_RESOURCES_MODE warn
else
  run_cmd env CAPBOX_MEMORY_MAX=32M CAPBOX_RESOURCES_MODE=require "$CAPBOX_BIN" exec --timeout 10 -- echo no
  assert_ne 0 "$RUN_RC" "require 在无 cgroup 时失败"
  assert_out_matches 'require|memory.max|拒绝 prlimit|无法精确兑现' "require 错误信息诚实"
fi

# DISK_MAX 配置合法，metrics 应诚实说 unavailable（本环境无 loop 权限）
run_cmd "$CAPBOX_BIN" config set CAPBOX_DISK_MAX 1G
assert_rc 0 "DISK_MAX 可配置"
run_cmd env CAPBOX_DISK_MAX=1G "$CAPBOX_BIN" metrics
assert_out_matches 'disk_status=(unavailable|capable|unset)' "disk 状态存在"
if printf '%s' "$RUN_STDOUT$RUN_STDERR" | grep -q 'disk_status=capable'; then
  _ok "loop 可用（capable）"
else
  assert_out_matches 'disk_status=unavailable|无写权限|loop-control' "无 loop 权限时诚实 unavailable"
fi
run_cmd "$CAPBOX_BIN" config set CAPBOX_DISK_MAX ''
assert_rc 0 "清空 DISK_MAX"

case_finish
exit 0
