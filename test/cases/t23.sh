#!/usr/bin/env bash
# T23 — 网络三档：none / open / restricted（allowlist 代理）
set -u
CASE_TITLE="网络三档：none / open / restricted"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖网络强制语义"
  case_finish
  exit 0
fi
require_rootfs

mkdir -p "$QA_TMP"
cfg_bak=""
if [ -f "$CAPBOX_DIR/config.env" ]; then
  cfg_bak="$QA_TMP/t23-config.bak"
  cp -a "$CAPBOX_DIR/config.env" "$cfg_bak" 2>/dev/null || cfg_bak=""
fi
restore_cfg() {
  if [ -n "${cfg_bak:-}" ] && [ -f "$cfg_bak" ]; then
    mv -f "$cfg_bak" "$CAPBOX_DIR/config.env"
  fi
  # 确保后续用例回到可联网默认
  "$CAPBOX_BIN" config set CAPBOX_NET open >/dev/null 2>&1 || true
  "$CAPBOX_BIN" config set CAPBOX_NET_ALLOW '' >/dev/null 2>&1 || true
}
trap restore_cfg EXIT

# ---- 非法 NET ----
run_cmd "$CAPBOX_BIN" config set CAPBOX_NET weird
assert_rc 2 "非法 CAPBOX_NET 被拒绝"

# ---- none：原始出站失败 ----
run_cmd "$CAPBOX_BIN" config set CAPBOX_NET none
assert_rc 0 "设置 NET=none"
run_cmd "$CAPBOX_BIN" exec --timeout 15 -- sh -c 'curl -fsS --max-time 3 https://example.com/ >/dev/null 2>&1; echo rc=$?'
assert_rc 0 "none 模式下外壳命令可执行"
if printf '%s' "$RUN_STDOUT" | grep -q 'rc=0'; then
  _fail "CAPBOX_NET=none 时仍能访问公网 HTTPS（应 --unshare-net）"
else
  _ok "none：公网 HTTPS 不可达"
fi

# ---- open（含 host 别名）----
run_cmd "$CAPBOX_BIN" config set CAPBOX_NET host
assert_rc 0 "设置 NET=host（open 别名）"
run_cmd "$CAPBOX_BIN" config get CAPBOX_NET
assert_rc 0 "读取 NET"
assert_out_matches 'open|host' "host/open 可读"

have_curl=0
run_cmd "$CAPBOX_BIN" exec --timeout 20 -- sh -c 'command -v curl >/dev/null'
if [ "${RUN_RC:-1}" -eq 0 ]; then
  have_curl=1
  _ok "guest 已有 curl"
else
  run_cmd "$CAPBOX_BIN" pkg install curl
  if [ "${RUN_RC:-1}" -eq 0 ]; then
    run_cmd "$CAPBOX_BIN" exec --timeout 20 -- sh -c 'command -v curl >/dev/null'
    if [ "${RUN_RC:-1}" -eq 0 ]; then
      have_curl=1
      _ok "open 下安装 curl 成功"
    fi
  fi
fi

if [ "$have_curl" = 1 ]; then
  run_cmd "$CAPBOX_BIN" exec --timeout 20 -- curl -fsS --max-time 10 -o /dev/null -w '%{http_code}' https://example.com/
  assert_rc 0 "open：HTTPS 可达"
  assert_stdout_contains "200" "open：example.com 返回 200"
else
  mark_known_issue "环境无法安装 curl，跳过 open/restricted 深测"
fi

# ---- restricted：缺 allowlist 应失败 ----
run_cmd "$CAPBOX_BIN" config set CAPBOX_NET_ALLOW ''
assert_rc 0 "清空 NET_ALLOW"
run_cmd "$CAPBOX_BIN" exec --net restricted --timeout 10 -- echo should-fail
assert_int_ge "${RUN_RC:-0}" 1 "restricted 无 allowlist 时 exec 失败"

if [ "$have_curl" = 1 ]; then
  run_cmd "$CAPBOX_BIN" config set CAPBOX_NET_ALLOW 'example.com'
  assert_rc 0 "设置 NET_ALLOW=example.com"
  run_cmd "$CAPBOX_BIN" config set CAPBOX_NET restricted
  assert_rc 0 "设置 NET=restricted"

  run_cmd "$CAPBOX_BIN" exec --timeout 25 -- curl -fsS --max-time 12 https://example.com/
  assert_rc 0 "restricted：allowlist 内 HTTPS 成功"
  assert_stdout_contains "html" "restricted：拿到 HTML"

  run_cmd "$CAPBOX_BIN" exec --timeout 25 -- curl -fsS --max-time 12 https://httpbin.org/get
  assert_int_ge "${RUN_RC:-0}" 1 "restricted：非 allowlist 域名被拒绝"

  run_cmd "$CAPBOX_BIN" exec --net none --timeout 10 -- curl -fsS --max-time 3 https://example.com/
  assert_int_ge "${RUN_RC:-0}" 1 "--net none 覆盖生效"
fi

case_finish
exit 0
