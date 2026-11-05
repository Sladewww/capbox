#!/usr/bin/env bash
# T30 — 安全档 untrusted：seccomp 拒 mount；compat 默认不削弱
set -u
CASE_TITLE="安全档 untrusted seccomp / compat 默认"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖"
  case_finish; exit 0
fi
require_rootfs

WS="${CAPBOX_TEST_WS:-$CAPBOX_DIR}"

run_cmd "$CAPBOX_BIN" exec --help
assert_rc 0 "exec 帮助"
assert_stdout_matches '--profile' "exec 帮助含 --profile"

run_cmd "$CAPBOX_BIN" exec --profile compat -- id -u
assert_rc 0 "compat id"
assert_stdout_eq "0" "compat uid 0"

run_cmd "$CAPBOX_BIN" exec --profile untrusted -- sh -c 'mkdir -p /mnt; mount -t tmpfs none /mnt 2>&1; echo RC=$?'
assert_rc 0 "untrusted 外壳可执行"
assert_stdout_matches 'RC=32|permission denied|Operation not permitted' "untrusted 拒绝 mount"

run_cmd "$CAPBOX_BIN" exec --profile untrusted -- echo ok-untrusted
assert_rc 0 "untrusted echo"
assert_stdout_contains "ok-untrusted" "untrusted 输出"

mkdir -p "$WS/.ssh"
echo secret-t30 >"$WS/.ssh/t30-key"
run_cmd "$CAPBOX_BIN" exec --profile untrusted -- cat /workspace/.ssh/t30-key
assert_ne 0 "$RUN_RC" "untrusted 下 .ssh 文件不可读"
run_cmd "$CAPBOX_BIN" exec --profile compat -- cat /workspace/.ssh/t30-key
assert_rc 0 "compat 下 .ssh 可读"
assert_stdout_contains "secret-t30" "compat 可见原文件"
rm -f "$WS/.ssh/t30-key"

case_finish
exit 0
