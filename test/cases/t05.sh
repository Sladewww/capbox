#!/usr/bin/env bash
# T05 — capbox doctor（有 rootfs）：全 PASS，退出 0
set -u
CASE_TITLE="doctor（有 rootfs）：全 PASS，退出 0"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

require_rootfs || { case_finish; exit 0; }

run_cmd "$CAPBOX_BIN" doctor
assert_rc 0 "doctor 退出码（有 rootfs 应全过）"

n_pass=$(cat "$RUN_STDOUT_FILE" "$RUN_STDERR_FILE" 2>/dev/null | grep -cE '(^|[[:space:]])PASS([[:space:]]|$)' || true)
n_fail=$(cat "$RUN_STDOUT_FILE" "$RUN_STDERR_FILE" 2>/dev/null | grep -cE '(^|[[:space:]])FAIL([[:space:]]|$)' || true)
n_warn=$(cat "$RUN_STDOUT_FILE" "$RUN_STDERR_FILE" 2>/dev/null | grep -cE '(^|[[:space:]])WARN([[:space:]]|$)' || true)

assert_int_ge "${n_pass:-0}" 3 "doctor 逐项 PASS 行数（契约 §3.3 要求逐项报告）"
assert_int_le "${n_fail:-0}" 0 "doctor 无 FAIL 行"
# 契约 §3.3 只要求逐项 PASS/FAIL；WARN 合法（§6 socks5 场景明确要求 WARN），仅提示
if [ "${n_warn:-0}" -gt 0 ]; then
  mark_known_issue "doctor 有 $n_warn 条 WARN（契约 §6 允许 socks5 场景 WARN；若是别的原因可关注）"
fi

# 契约 §3.1/§3.3 要求 doctor 覆盖这些自检维度
for k in bwrap rootfs; do
  assert_out_matches_i "$k" "doctor 覆盖自检项"
done

case_finish
exit 0
