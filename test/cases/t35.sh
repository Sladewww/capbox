#!/usr/bin/env bash
# T35 — doctor 报告新模块；配置白名单
set -u
CASE_TITLE="doctor 安全/cgroup 与新配置白名单"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖"
  case_finish; exit 0
fi

run_cmd "$CAPBOX_BIN" doctor
# doctor 可能因无关项 FAIL，但应提到安全档与 cgroup
assert_out_matches '安全档|SECURITY|seccomp|compat' "doctor 提及安全档"
assert_out_matches 'cgroup' "doctor 提及 cgroup"

run_cmd "$CAPBOX_BIN" config set CAPBOX_SECURITY_PROFILE weird
assert_rc 2 "非法 SECURITY_PROFILE 拒绝"

run_cmd "$CAPBOX_BIN" config set CAPBOX_SECURITY_PROFILE untrusted
assert_rc 0 "合法 untrusted"
run_cmd "$CAPBOX_BIN" config set CAPBOX_SECURITY_PROFILE compat
assert_rc 0 "恢复 compat"

run_cmd "$CAPBOX_BIN" config set CAPBOX_AUDIT full
assert_rc 0 "AUDIT=full"
run_cmd "$CAPBOX_BIN" config set CAPBOX_AUDIT summary
assert_rc 0 "恢复 AUDIT=summary"

run_cmd "$CAPBOX_BIN" help
assert_rc 0 "help"
assert_stdout_matches 'snapshot|image|audit|metrics' "help 含新命令"

case_finish
exit 0
