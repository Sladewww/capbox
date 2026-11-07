#!/usr/bin/env bash
# T10 — 镜像源：/etc/apk/repositories 含 cn 镜像；apk update 成功
# 契约 §6：alpine 写 <MIRROR_ALPINE>/v3.24/main 与 community。
set -u
CASE_TITLE="镜像源：repositories 含 cn 镜像且 apk update 成功"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

require_rootfs || { case_finish; exit 0; }

if ! require_alpine; then case_finish; exit 0; fi

run_cmd "$CAPBOX_BIN" exec -- cat /etc/apk/repositories
assert_rc 0 "读取 /etc/apk/repositories 退出码"
# 默认 cn 镜像可能是 aliyun / tuna / 其它国内源
if printf '%s' "$RUN_STDOUT" | grep -qiE 'aliyun|tuna|ustc|huaweicloud|tsinghua|mirror'; then
  _ok "repositories 含已知 cn/镜像主机"
else
  _fail "repositories 未包含预期镜像主机" "实际: $(_short "$RUN_STDOUT")"
fi
assert_stdout_contains "v3.24/main" "repositories 含 v3.24/main"
assert_stdout_contains "v3.24/community" "repositories 含 v3.24/community"

run_cmd "$CAPBOX_BIN" exec -- apk update
assert_rc 0 "apk update 退出码"
assert_stdout_not_contains "ERROR" "apk update 无 ERROR 输出"

case_finish
exit 0
