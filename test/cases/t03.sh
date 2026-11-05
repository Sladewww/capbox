#!/usr/bin/env bash
# T03 — capbox init --distro alpine：退出 0，os/alpine/bin/sh 存在
set -u
CASE_TITLE="init --distro alpine：退出 0，os/alpine/bin/sh 存在"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

rf="$CAPBOX_DIR/os/alpine"

if [ "${CAPBOX_TEST_SKIP_INIT:-0}" = "1" ]; then
  skip_case "CAPBOX_TEST_SKIP_INIT=1：跳过 init（假定 rootfs 已就绪）"
  assert_rootfs_has "/bin/sh" "rootfs /bin/sh"
  case_finish
  exit 0
fi

run_cmd "$CAPBOX_BIN" init --distro alpine
assert_rc 0 "init --distro alpine 退出码"

assert_rootfs_has "/bin/sh" "rootfs 存在 /bin/sh"
assert_file_exists "$rf/etc/apk/repositories" "alpine 镜像源文件已写入"

# init 后 config 应记录 distro（契约 §2）
if [ -f "$CAPBOX_DIR/config.env" ]; then
  _ok "config.env 已生成"
  assert_file_contains "$CAPBOX_DIR/config.env" "CAPBOX_DISTRO" "config 含 CAPBOX_DISTRO"
  assert_eq "alpine" "$(config_distro)" "init 后当前 distro"
else
  _fail "init 后未生成 config.env（契约 §2：init 写 config）"
fi

case_finish
exit 0
