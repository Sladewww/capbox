#!/usr/bin/env bash
# T17 — 代理注入：CAPBOX_PROXY=http://127.0.0.1:9999 capbox exec -- printenv http_proxy
# 契约 §3.4/§6：CAPBOX_PROXY 非空时一次性 exec 要 --setenv http_proxy/https_proxy/all_proxy/no_proxy。
set -u
CASE_TITLE="代理注入：CAPBOX_PROXY → 容器内 http_proxy"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

require_rootfs || { case_finish; exit 0; }

proxy="http://127.0.0.1:9999"

# 显式用 env 覆盖，避免宿主已有 http_proxy 干扰判据
run_cmd env -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
  CAPBOX_PROXY="$proxy" "$CAPBOX_BIN" exec -- printenv http_proxy
assert_rc 0 "带 CAPBOX_PROXY 的 exec 退出码"
assert_stdout_eq "$proxy" "容器内 http_proxy"

run_cmd env -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
  CAPBOX_PROXY="$proxy" "$CAPBOX_BIN" exec -- printenv https_proxy
assert_stdout_eq "$proxy" "容器内 https_proxy"

run_cmd env -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
  CAPBOX_PROXY="$proxy" "$CAPBOX_BIN" exec -- printenv all_proxy
assert_stdout_eq "$proxy" "容器内 all_proxy"

# 契约 §6：容器内还应写 /etc/profile.d/capbox-proxy.sh（可选，失败不致命）
run_cmd env -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
  CAPBOX_PROXY="$proxy" "$CAPBOX_BIN" exec -- sh -c 'test -f /etc/profile.d/capbox-proxy.sh && cat /etc/profile.d/capbox-proxy.sh || echo MISSING'
if printf '%s' "$RUN_STDOUT" | grep -qF "MISSING"; then
  mark_known_issue "契约 §6：容器内未生成 /etc/profile.d/capbox-proxy.sh（契约标注为可选，不判 FAIL）"
else
  _ok "容器内生成 /etc/profile.d/capbox-proxy.sh"
  assert_stdout_contains "$proxy" "profile.d 代理文件含代理值"
fi

# 对照：不设 CAPBOX_PROXY 时不应注入测试值
run_cmd env -u http_proxy -u https_proxy -u all_proxy -u no_proxy -u CAPBOX_PROXY \
  "$CAPBOX_BIN" exec -- sh -c 'printenv http_proxy || echo NO_PROXY_SET'
assert_rc 0 "无代理 exec 退出码"
assert_stdout_not_contains "$proxy" "不设 CAPBOX_PROXY 时不注入代理"

case_finish
exit 0
