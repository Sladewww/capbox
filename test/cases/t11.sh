#!/usr/bin/env bash
# T11 — 装包：capbox pkg install curl → exec -- curl --version 成功
# 契约 §3.1：pkg 按 distro 分派 apk/apt-get，透传退出码。
set -u
CASE_TITLE="装包：pkg install curl 后 exec curl --version 成功"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

require_rootfs || { case_finish; exit 0; }

# 幂等：已装过就不重复装（apk install 本身也幂等，但省时间）
run_cmd "$CAPBOX_BIN" exec -- sh -c 'command -v curl >/dev/null 2>&1 && echo present || echo absent'
already=$RUN_STDOUT

if [ "$already" = "present" ]; then
  _ok "curl 已在 rootfs 内（跳过重复安装，保证用例可重复运行）"
else
  run_cmd "$CAPBOX_BIN" pkg install curl
  assert_rc 0 "pkg install curl 退出码"
  # apk 的 chown 警告是正常现象（契约 §0 坑 2），但 ERROR 不行
  assert_stdout_not_contains "ERROR" "pkg install 无 ERROR 输出"
fi

run_cmd "$CAPBOX_BIN" exec -- curl --version
assert_rc 0 "exec curl --version 退出码"
assert_stdout_contains "curl" "curl --version 输出含 curl"
assert_stdout_matches '[0-9]+\.[0-9]+' "curl 版本号格式"

# pkg list 应能列出已装包（契约 §3.1）
run_cmd "$CAPBOX_BIN" pkg list
assert_rc 0 "pkg list 退出码"
assert_out_contains "curl" "pkg list 含 curl"

case_finish
exit 0
