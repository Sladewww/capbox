#!/usr/bin/env bash
# T33 — 快照 / 镜像导出校验（不破坏现有 rootfs）
set -u
CASE_TITLE="snapshot / image export+verify"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖"
  case_finish; exit 0
fi
require_rootfs

name="t33-$$"
run_cmd "$CAPBOX_BIN" snapshot create "$name"
assert_rc 0 "snapshot create"
assert_out_matches 'snapshots/|sha256=' "快照路径/校验输出"

run_cmd "$CAPBOX_BIN" snapshot list
assert_rc 0 "snapshot list"
assert_out_matches "$name" "list 含快照名"

run_cmd "$CAPBOX_BIN" image export "$name"
assert_rc 0 "image export"
run_cmd "$CAPBOX_BIN" image verify "$name"
assert_rc 0 "image verify"
assert_stdout_matches '^OK ' "verify OK"

# import 默认旁路，不替换当前 rootfs
run_cmd "$CAPBOX_BIN" image import "$name"
assert_rc 0 "image import 旁路"
assert_out_matches '旁路|未替换' "默认不替换 rootfs"

# 确认当前 rootfs 仍可用
run_cmd "$CAPBOX_BIN" exec --timeout 15 -- id -u
assert_rc 0 "import 后 rootfs 仍可用"
assert_stdout_eq "0" "uid 仍为 0"

run_cmd "$CAPBOX_BIN" image lock save
assert_rc 0 "package lock save"
run_cmd "$CAPBOX_BIN" image lock show
assert_rc 0 "package lock show"

run_cmd "$CAPBOX_BIN" snapshot rm "$name"
assert_rc 0 "snapshot rm"

case_finish
exit 0
