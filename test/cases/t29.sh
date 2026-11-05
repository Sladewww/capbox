#!/usr/bin/env bash
# T29 — exec --user 解析 + pkg 帮助提及 audit
set -u
CASE_TITLE="exec --user / pkg audit 帮助"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖"
  case_finish; exit 0
fi

run_cmd "$CAPBOX_BIN" exec --help
assert_stdout_matches '--uid' "exec 帮助含 --uid"
assert_stdout_matches '--user' "exec 帮助含 --user"

run_cmd "$CAPBOX_BIN" pkg --help
assert_stdout_matches 'iU|audit|dpkg' "pkg 帮助提及 audit/iU"

run_cmd "$CAPBOX_BIN" service --help
assert_rc 0 "service 帮助"
assert_stdout_matches 'start' "service 帮助含 start"

# --user root 应可用
run_cmd "$CAPBOX_BIN" exec --user root -- id -u
assert_rc 0 "--user root"
assert_stdout_eq "0" "root uid 0"

case_finish
exit 0
