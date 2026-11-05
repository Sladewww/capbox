#!/usr/bin/env bash
# T27 — 多 UID 映射：chown / setuid（或诚实 SKIP/FAIL）
set -u
CASE_TITLE="多 UID 映射：chown 到 33 且 --uid 降权（或明确阻塞）"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖 idmap"
  case_finish; exit 0
fi

# doctor 行
run_cmd "$CAPBOX_BIN" doctor
assert_rc 0 "doctor 退出码"
if printf '%s' "${RUN_STDOUT}${RUN_STDERR}" | grep -q 'UID 映射 multi'; then
  _ok "doctor 报告 multi"
elif printf '%s' "${RUN_STDOUT}${RUN_STDERR}" | grep -qE 'UID 映射 (single|不可用|被阻塞)'; then
  mark_known_issue "本环境无法多 UID 映射；后续断言改为验证单 UID 边界"
  run_cmd "$CAPBOX_BIN" exec -- sh -c 'touch /tmp/t27; chown 33:33 /tmp/t27 2>&1 || true'
  if printf '%s' "$RUN_STDOUT" | grep -qiE 'Invalid argument|Operation not permitted|chown:'; then
    _ok "单 UID 下 chown 33 失败（预期）"
  else
    # 某些系统 chown 可能静默成功到同一映射
    mark_known_issue "chown 33 未报错；请人工确认 uid_map"
  fi
  case_finish; exit 0
else
  _fail "doctor 未报告 UID 映射状态"
  case_finish; exit 0
fi

run_cmd "$CAPBOX_BIN" exec -- sh -c 'touch /tmp/t27; chown 33:33 /tmp/t27; ls -ln /tmp/t27'
assert_rc 0 "chown 33 退出码"
assert_stdout_matches '[[:space:]]33[[:space:]]+33[[:space:]]' "ls 显示属主 33:33"

run_cmd "$CAPBOX_BIN" exec --uid 33 --gid 33 -- id -u
assert_rc 0 "--uid 33 退出码"
assert_stdout_eq "33" "--uid 33 → id -u"

case_finish
exit 0
