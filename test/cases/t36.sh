#!/usr/bin/env bash
# T36 — restricted 出站 allowlist 真实语义（代理过滤，非共享宿主假过滤）
set -u
CASE_TITLE="restricted 网络 allowlist 真实过滤"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖"
  case_finish; exit 0
fi
require_rootfs

mkdir -p "$QA_TMP"
cfg_bak=""
if [ -f "$CAPBOX_DIR/config.env" ]; then
  cfg_bak="$QA_TMP/t36-config.bak"
  cp -a "$CAPBOX_DIR/config.env" "$cfg_bak" || cfg_bak=""
fi
restore_cfg() {
  if [ -n "${cfg_bak:-}" ] && [ -f "$cfg_bak" ]; then
    mv -f "$cfg_bak" "$CAPBOX_DIR/config.env"
  fi
}
trap restore_cfg EXIT

# 确保 guest 有 curl
if ! "$CAPBOX_BIN" exec --timeout 20 -- sh -c 'command -v curl >/dev/null'; then
  run_cmd "$CAPBOX_BIN" pkg install curl
  if [ "${RUN_RC:-1}" != "0" ]; then
    skip_case "无法安装 curl，跳过 restricted 深测"
    case_finish; exit 0
  fi
fi

# 工作区绑定自检：不得把父目录 /workspace 当成项目工作区
run_cmd "$CAPBOX_BIN" status
assert_rc 0 "status"
assert_out_not_matches '工作区[[:space:]]*:[[:space:]]*/workspace$' "工作区不是裸 /workspace"
ws_line=$(printf '%s\n' "$RUN_STDOUT" | grep -E '工作区' | head -n1 || true)
_ok "status 工作区行: $ws_line"

# open 对照
run_cmd "$CAPBOX_BIN" config set CAPBOX_NET open
assert_rc 0 "NET=open"
run_cmd "$CAPBOX_BIN" exec --timeout 25 -- curl -fsS -o /dev/null -w '%{http_code}' --max-time 12 https://example.com/
assert_rc 0 "open: example.com"
assert_stdout_contains "200" "open 返回 200"

# restricted 无 allowlist 必须失败
run_cmd "$CAPBOX_BIN" config set CAPBOX_NET_ALLOW ''
assert_rc 0 "清空 allow"
run_cmd "$CAPBOX_BIN" exec --net restricted --timeout 10 -- echo no
assert_ne 0 "$RUN_RC" "restricted 无 allowlist 失败"

# allowlist 内
run_cmd "$CAPBOX_BIN" config set CAPBOX_NET_ALLOW 'example.com'
assert_rc 0 "ALLOW=example.com"
run_cmd "$CAPBOX_BIN" config set CAPBOX_NET restricted
assert_rc 0 "NET=restricted"

run_cmd "$CAPBOX_BIN" exec --timeout 30 -- curl -fsS -o /dev/null -w '%{http_code}' --max-time 15 https://example.com/
assert_rc 0 "restricted allow 内"
assert_stdout_contains "200" "allow 内 200"

# allowlist 外 — 必须非 0，且 stderr/stdout 体现 403/拒绝（代理语义）
run_cmd "$CAPBOX_BIN" exec --timeout 30 -- curl -fsS -o /dev/null -w '%{http_code}' --max-time 15 https://httpbin.org/get
assert_ne 0 "$RUN_RC" "restricted 拒绝非 allow 域名"
assert_out_matches '403|Forbidden|CONNECT tunnel failed|failed' "拒绝信息来自 allowlist 代理"

# 原始 TCP（不走代理）在 unshare-net 下应失败
run_cmd "$CAPBOX_BIN" exec --timeout 20 -- sh -c 'curl --noproxy "*" -fsS --max-time 5 -o /dev/null https://example.com/ 2>&1; echo RC=$?'
assert_stdout_matches 'RC=[1-9]|RC=[1-9][0-9]+' "noproxy 原始出站失败（证明不是共享宿主网络假过滤）"

# 裸 TLD allow 不得放行（安全加固）
run_cmd "$CAPBOX_BIN" config set CAPBOX_NET_ALLOW 'com'
assert_rc 0 "ALLOW=com（非法宽松后缀）"
run_cmd "$CAPBOX_BIN" exec --timeout 25 -- curl -fsS -o /dev/null -w '%{http_code}' --max-time 12 https://example.com/
assert_ne 0 "$RUN_RC" "裸 TLD allow 不放行 example.com"

# 恢复 open，避免污染后续用例
run_cmd "$CAPBOX_BIN" config set CAPBOX_NET open
run_cmd "$CAPBOX_BIN" config set CAPBOX_NET_ALLOW ''

case_finish
exit 0
