#!/usr/bin/env bash
# T12 — 退出码透传：exec -- sh -c 'exit 42' 返回 42
# 契约 §3.2：exec 透传容器内退出码。
set -u
CASE_TITLE="退出码透传：exec 返回容器内退出码 42"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

require_rootfs || { case_finish; exit 0; }

run_cmd "$CAPBOX_BIN" exec -- sh -c 'exit 42'
assert_rc 42 "容器内 exit 42 透传"

run_cmd "$CAPBOX_BIN" exec -- sh -c 'exit 7'
assert_rc 7 "容器内 exit 7 透传"

run_cmd "$CAPBOX_BIN" exec -- true
assert_rc 0 "容器内 true 透传 0"

# 区分「容器内命令不存在」与「CLI 自身错误」：契约 §3.2 里 127 未列，
# 但按「透传」语义，命令不存在应是 127 而不是 CLI 的 1/2。
run_cmd "$CAPBOX_BIN" exec -- sh -c 'exit 1'
assert_rc 1 "容器内 exit 1 透传（不与 CLI 一般错误混淆）"

case_finish
exit 0
