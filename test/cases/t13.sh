#!/usr/bin/env bash
# T13 — 超时：exec --timeout 2 -- sleep 10 返回 124
# 契约 §3.2：124 = 容器内命令超时。断言不仅看码，也看「确实在约 2s 后返回」，
# 否则 CLI 直接返回 124 但实际卡满 10s 也能骗过测试。
set -u
CASE_TITLE="超时：exec --timeout 2 返回 124 且约 2s 返回"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

require_rootfs || { case_finish; exit 0; }

run_cmd "$CAPBOX_BIN" exec --timeout 2 -- sleep 10
assert_rc 124 "超时退出码"
# 期望 ~2000ms；给足余量（含容器启动开销），但必须远小于 10s
assert_int_le "$RUN_ELAPSED_MS" 9000 "耗时（应显著小于 sleep 10s）"
assert_int_ge "$RUN_ELAPSED_MS" 1000 "耗时（至少接近 timeout 2s，未提前误判）"

# 对照：timeout 内的命令应正常返回 0
run_cmd "$CAPBOX_BIN" exec --timeout 30 -- sh -c 'echo fast-ok'
assert_rc 0 "timeout 内快速命令退出码"
assert_stdout_eq "fast-ok" "快速命令输出"

# 契约 §3.2：超时不应污染 stdout（stdout 只含容器内输出）
assert_stdout_not_contains "timeout" "超时后 stdout 不含 CLI 自身提示"

case_finish
exit 0
