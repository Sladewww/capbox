#!/usr/bin/env bash
# T02 — capbox doctor（无 rootfs）：退出 1，有 FAIL 行且措辞清晰
# 用一个隔离骨架复刻 .capbox 的脚本（不含 os/<distro>/）来制造「无 rootfs」场景，
# 这样不会破坏真实工作区，也可以随时重跑。
set -u
CASE_TITLE="doctor（无 rootfs）：退出 1，有 FAIL 行且措辞清晰"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

if [ ! -x "$CAPBOX_BIN" ]; then
  skip_case "CLI 尚不存在（$CAPBOX_BIN），无法验证无 rootfs 分支"
  case_finish
  exit 0
fi

sbx=$(make_sandbox_skeleton T02)
assert_file_absent "$sbx/.capbox/os/alpine/bin/sh" "骨架中确实没有 rootfs（避免误判）"

# 显式清掉可能影响判定的环境变量，确保 CLI 以骨架为根
RUN_CWD="$sbx" run_cmd env -u CAPBOX_ROOT -u CAPBOX_DISTRO "$sbx/.capbox/bin/capbox" doctor

assert_rc 1 "无 rootfs 时 doctor 退出码"
n_fail=$(cat "$RUN_STDOUT_FILE" "$RUN_STDERR_FILE" 2>/dev/null | grep -cE '(^|[[:space:]])FAIL([[:space:]]|$)' || true)
if [ "${n_fail:-0}" -ge 1 ]; then
  _ok "输出含 FAIL 行（$n_fail 行）"
else
  _fail "输出不含 FAIL 行" "stdout: $(_short "$RUN_STDOUT")" "stderr: $(_short "$RUN_STDERR")"
fi
assert_out_matches_i 'rootfs|根文件系统|init|未初始化' "FAIL 行措辞指向 rootfs 缺失"

n_pass=$(cat "$RUN_STDOUT_FILE" "$RUN_STDERR_FILE" 2>/dev/null | grep -cE '(^|[[:space:]])PASS([[:space:]]|$)' || true)
assert_int_ge "${n_pass:-0}" 1 "其余自检项仍有 PASS 行（doctor 应逐项报告，而非整体报错）"

case_finish
exit 0
