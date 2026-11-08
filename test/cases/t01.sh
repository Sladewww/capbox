#!/usr/bin/env bash
# T01 — capbox --help / version：退出 0，且含命令列表
set -u
CASE_TITLE="--help / version：退出 0 且含完整命令列表"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

run_cmd "$CAPBOX_BIN" --help
assert_rc 0 "--help 退出码"
assert_out_contains "capbox" "--help 提到 capbox"

# 契约 §3.1 命令表里的命令应全部出现在帮助里
for c in bootstrap init status exec shell cp pkg up down ls ps logs doctor distros config recipe clean; do
  assert_out_contains "$c" "--help 列出命令"
done

run_cmd "$CAPBOX_BIN" version
assert_rc 0 "version 退出码"
assert_out_contains "0.3.6" "version 输出当前 CLI 版本 0.3.6"

case_finish
exit 0
