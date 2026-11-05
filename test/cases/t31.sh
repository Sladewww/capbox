#!/usr/bin/env bash
# T31 — 资源 require fail-closed + metrics 诚实 + CGROUP_ROOT 选择
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

# --- CAPBOX_CGROUP_ROOT：假目录（可 mkdir 但无控制器）不得视为成功 ---
fake_cg="$QA_TMP/fake-cgroup-root"
mkdir -p "$fake_cg"
run_cmd env \
  CAPBOX_CGROUP_ROOT="$fake_cg" \
  CAPBOX_MEMORY_MAX=32M \
  CAPBOX_RESOURCES_MODE=require \
  "$CAPBOX_BIN" exec --timeout 10 -- echo should-fail
assert_ne 0 "$RUN_RC" "假 CGROUP_ROOT + require 必须失败"
assert_out_matches 'CAPBOX_CGROUP_ROOT|控制器|memory.max|无法精确兑现|不可用|require' "假 CGROUP_ROOT 错误信息点名覆盖"

# warn 模式：显式 CGROUP_ROOT 失败时也不应悄悄 prlimit
run_cmd env \
  CAPBOX_CGROUP_ROOT="$fake_cg" \
  CAPBOX_MEMORY_MAX=32M \
  CAPBOX_RESOURCES_MODE=warn \
  "$CAPBOX_BIN" exec --timeout 10 -- echo warn-root-ok
assert_out_not_matches 'prlimit RLIMIT_AS|prlimit-as:' "CGROUP_ROOT 失败时不降级 prlimit"
assert_out_matches 'CAPBOX_CGROUP_ROOT|不可用|未应用|控制器' "warn 下仍明确报告 CGROUP_ROOT 失败"

run_cmd env CAPBOX_CGROUP_ROOT="$fake_cg" "$CAPBOX_BIN" metrics
assert_rc 0 "metrics with CGROUP_ROOT"
assert_out_matches 'cgroup_status=denied' "假 CGROUP_ROOT → denied"
assert_out_matches 'CAPBOX_CGROUP_ROOT' "metrics detail 提及覆盖"

# 单元：root 选择 / 控制器探测（不依赖宿主真实委派）
unit_out="$QA_TMP/resources-unit.out"
repo_lib="$(cd "$(dirname "$CAPBOX_BIN")/../lib" && pwd)"
if [[ ! -f "$repo_lib/resources.sh" ]]; then
  repo_lib="$CAPBOX_DIR/lib"
fi
set +e
(
  set -euo pipefail
  log_warn() { printf 'WARN %s\n' "$*" >&2; }
  log_err() { printf 'ERR %s\n' "$*" >&2; }
  log_debug() { :; }
  have_cmd() { command -v "$1" >/dev/null 2>&1; }
  # shellcheck source=/dev/null
  source "$repo_lib/resources.sh"

  base="$QA_TMP/unit-cg"
  rm -rf "$base"
  mkdir -p "$base/noctrl" "$base/withctrl"

  export CAPBOX_CGROUP_ROOT="$base/noctrl"
  if out="$(_resources_find_cgroup_root)"; then
    echo "FAIL: noctrl should not be selected: $out"
    exit 1
  else
    echo "OK noctrl rejected: $out"
  fi

  _resources_cgroup_try_enable() {
    local root="$1"
    local d
    # probe 目录以 . 开头，不能只用 "$root"/*
    while IFS= read -r -d "" d; do
      : >"$d/memory.max"
      : >"$d/cpu.max"
      : >"$d/pids.max"
      chmod u+w "$d/memory.max" "$d/cpu.max" "$d/pids.max" 2>/dev/null || true
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  }
  export CAPBOX_CGROUP_ROOT="$base/withctrl"
  if out="$(_resources_find_cgroup_root)"; then
    [[ "$out" == "$base/withctrl" ]] || { echo "FAIL: wrong root $out"; exit 1; }
    echo "OK withctrl selected: $out"
  else
    echo "FAIL: withctrl should be usable: $out"
    exit 1
  fi

  export CAPBOX_CGROUP_ROOT="$base/noctrl"
  # restore default try_enable for probe of noctrl (re-source would reset; call usable path via probe)
  # 重新 source 以恢复 try_enable，再验证 probe 不清空覆盖
  # shellcheck source=/dev/null
  source "$repo_lib/resources.sh"
  export CAPBOX_CGROUP_ROOT="$base/noctrl"
  _resources_probe_cgroup || true
  [[ "${CAPBOX_CGROUP_STATUS}" == "denied" ]] || { echo "FAIL: status=${CAPBOX_CGROUP_STATUS}"; exit 1; }
  [[ "${CAPBOX_CGROUP_ROOT}" == "$base/noctrl" ]] || { echo "FAIL: override cleared -> ${CAPBOX_CGROUP_ROOT}"; exit 1; }
  echo "OK override preserved and denied"

  # 回归：setup 必须在当前 shell 设置 APPLIED_*（禁止 $() 包一层）
  _resources_cgroup_try_enable() {
    local root="$1" d
    while IFS= read -r -d "" d; do
      : >"$d/memory.max"; : >"$d/cpu.max"; : >"$d/pids.max"
      chmod u+w "$d/memory.max" "$d/cpu.max" "$d/pids.max" 2>/dev/null || true
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  }
  export CAPBOX_CGROUP_ROOT="$base/withctrl"
  export CAPBOX_MEMORY_MAX=64M CAPBOX_CPU_MAX=50% CAPBOX_PIDS_MAX=64
  CAPBOX_RESOURCES_APPLIED_MEMORY=""
  CAPBOX_RESOURCES_APPLIED_CPU=""
  CAPBOX_RESOURCES_APPLIED_PIDS=""
  CAPBOX_RESOURCES_CGROUP_LEAF=""
  _resources_setup_cgroup || { echo "FAIL setup rc"; exit 1; }
  [[ "${CAPBOX_RESOURCES_APPLIED_MEMORY}" == cgroup:* ]] || { echo "FAIL mem=${CAPBOX_RESOURCES_APPLIED_MEMORY}"; exit 1; }
  [[ "${CAPBOX_RESOURCES_APPLIED_CPU}" == cgroup:* ]] || { echo "FAIL cpu=${CAPBOX_RESOURCES_APPLIED_CPU}"; exit 1; }
  [[ "${CAPBOX_RESOURCES_APPLIED_PIDS}" == cgroup:* ]] || { echo "FAIL pids=${CAPBOX_RESOURCES_APPLIED_PIDS}"; exit 1; }
  [[ -n "${CAPBOX_RESOURCES_CGROUP_LEAF}" ]] || { echo "FAIL empty leaf"; exit 1; }
  echo "OK applied state retained in parent shell mem=$CAPBOX_RESOURCES_APPLIED_MEMORY cpu=$CAPBOX_RESOURCES_APPLIED_CPU pids=$CAPBOX_RESOURCES_APPLIED_PIDS"

  # 反例：命令替换会丢掉 APPLIED_*（文档化回归）
  CAPBOX_RESOURCES_APPLIED_MEMORY=""
  CAPBOX_RESOURCES_APPLIED_CPU=""
  CAPBOX_RESOURCES_APPLIED_PIDS=""
  leaf_via_subshell="$(_resources_setup_cgroup)" || true
  if [[ -z "${CAPBOX_RESOURCES_APPLIED_MEMORY}" && -z "${CAPBOX_RESOURCES_APPLIED_CPU}" && -z "${CAPBOX_RESOURCES_APPLIED_PIDS}" ]]; then
    echo "OK subshell loses APPLIED (expected; wrap must not use \$())"
  else
    echo "NOTE subshell unexpectedly kept APPLIED (bash version?); wrap still uses direct call"
  fi
  # cleanup leaf dirs if any
  [[ -n "${CAPBOX_RESOURCES_CGROUP_LEAF:-}" && -d "${CAPBOX_RESOURCES_CGROUP_LEAF}" ]] && rmdir "${CAPBOX_RESOURCES_CGROUP_LEAF}" 2>/dev/null || true
  [[ -n "${leaf_via_subshell:-}" && -d "${leaf_via_subshell}" ]] && rmdir "${leaf_via_subshell}" 2>/dev/null || true
) >"$unit_out" 2>&1
unit_rc=$?
set -e
assert_eq 0 "$unit_rc" "resources unit 子壳退出码"
assert_file_contains "$unit_out" "OK noctrl rejected" "拒绝无控制器父目录"
assert_file_contains "$unit_out" "OK withctrl selected" "接受有控制器父目录"
assert_file_contains "$unit_out" "OK override preserved and denied" "probe 不覆盖 CAPBOX_CGROUP_ROOT"
assert_file_contains "$unit_out" "OK applied state retained in parent shell" "APPLIED_* 在父 shell 保留"

# DISK_MAX 配置合法；无特权时 unavailable，有 sudo/disk 时可为 capable
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
