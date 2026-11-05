#!/usr/bin/env bash
# T32 — FS_HIDE / FS_BINDS 校验（拒绝工作区外 bind）
set -u
CASE_TITLE="文件系统 hide/bind 校验"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖"
  case_finish; exit 0
fi
require_rootfs

WS="${CAPBOX_TEST_WS:-$CAPBOX_DIR}"

mkdir -p "$QA_TMP"
cfg_bak=""
if [ -f "$CAPBOX_DIR/config.env" ]; then
  cfg_bak="$QA_TMP/t32-config.bak"
  cp -a "$CAPBOX_DIR/config.env" "$cfg_bak" || cfg_bak=""
fi
restore_cfg() {
  if [ -n "${cfg_bak:-}" ] && [ -f "$cfg_bak" ]; then
    mv -f "$cfg_bak" "$CAPBOX_DIR/config.env"
  fi
}
trap restore_cfg EXIT

mkdir -p "$WS/t32-secret"
echo hidden-data >"$WS/t32-secret/x"

run_cmd "$CAPBOX_BIN" config set CAPBOX_FS_HIDE t32-secret
assert_rc 0 "设置 FS_HIDE"
run_cmd "$CAPBOX_BIN" exec --timeout 15 -- cat /workspace/t32-secret/x
assert_ne 0 "$RUN_RC" "hide 后文件不可读"

run_cmd "$CAPBOX_BIN" config set CAPBOX_FS_HIDE ''
assert_rc 0 "清空 FS_HIDE"
run_cmd "$CAPBOX_BIN" exec --timeout 15 -- cat /workspace/t32-secret/x
assert_rc 0 "取消 hide 后可读"
assert_stdout_contains "hidden-data" "内容恢复可见"

run_cmd "$CAPBOX_BIN" config set CAPBOX_FS_BINDS '/etc/passwd:/mnt/passwd:ro'
assert_rc 0 "config set 粗接受（细校验在 exec）"
run_cmd "$CAPBOX_BIN" exec --timeout 15 -- echo should-fail
assert_ne 0 "$RUN_RC" "工作区外 bind 被拒绝"
assert_out_matches '拒绝工作区外|FS_BINDS|无法构造 bwrap' "越界 bind 错误信息"

run_cmd "$CAPBOX_BIN" config set CAPBOX_FS_BINDS ''
assert_rc 0 "清空 FS_BINDS"

case_finish
exit 0
