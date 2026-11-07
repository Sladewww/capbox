#!/usr/bin/env bash
# T38 — 环境清空：--clearenv 后宿主密钥不进入 guest（oneshot / profile / service / daemon）
# 回归 Issue #1 / SECURITY.md：bwrap 必须先 --clearenv 再白名单 --setenv。
set -u
CASE_TITLE="环境清空：clearenv 阻止宿主密钥进入 guest"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖 clearenv/bwrap 实路径"
  case_finish; exit 0
fi
require_rootfs || { case_finish; exit 0; }

SENTINEL_VAL='leak-me-t38'
AWS_VAL='AKIA_T38_PROBE'
GH_VAL='ghp_t38_probe'
SSH_VAL='/tmp/capbox-t38-ssh.sock'
GPG_VAL='/tmp/capbox-t38-gpg'
OPENAI_VAL='sk-t38-probe'

probe_cmd='printf "S=%s\nA=%s\nG=%s\nSSH=%s\nGPG=%s\nOAI=%s\nH=%s\nP=%s\nT=%s\n" \
  "${CAPBOX_TEST_SENTINEL:-clean}" \
  "${AWS_ACCESS_KEY_ID:-clean}" \
  "${GITHUB_TOKEN:-clean}" \
  "${SSH_AUTH_SOCK:-clean}" \
  "${GPG_AGENT_INFO:-clean}" \
  "${OPENAI_API_KEY:-clean}" \
  "${HOME:-}" \
  "${PATH:-}" \
  "${TERM:-}"'

assert_probe_clean() {
  local label="$1"
  assert_stdout_contains "S=clean" "$label：哨兵未泄漏"
  assert_stdout_contains "A=clean" "$label：AWS_ACCESS_KEY_ID 未泄漏"
  assert_stdout_contains "G=clean" "$label：GITHUB_TOKEN 未泄漏"
  assert_stdout_contains "SSH=clean" "$label：SSH_AUTH_SOCK 未泄漏"
  assert_stdout_contains "GPG=clean" "$label：GPG_AGENT_INFO 未泄漏"
  assert_stdout_contains "OAI=clean" "$label：OPENAI_API_KEY 未泄漏"
  assert_stdout_contains "H=/root" "$label：白名单 HOME=/root"
  assert_stdout_contains "P=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "$label：白名单 PATH"
}

run_leak_env() {
  env \
    CAPBOX_TEST_SENTINEL="$SENTINEL_VAL" \
    AWS_ACCESS_KEY_ID="$AWS_VAL" \
    GITHUB_TOKEN="$GH_VAL" \
    SSH_AUTH_SOCK="$SSH_VAL" \
    GPG_AGENT_INFO="$GPG_VAL" \
    OPENAI_API_KEY="$OPENAI_VAL" \
    "$@"
}

# ---- 1) oneshot：所有安全档 ----
for profile in compat untrusted strict; do
  run_cmd run_leak_env "$CAPBOX_BIN" exec --profile "$profile" -- sh -c "$probe_cmd"
  assert_rc 0 "exec --profile $profile 退出码"
  assert_probe_clean "oneshot/$profile"
done

# ---- 2) 白名单仍注入 CAPBOX_PROXY（不得因 clearenv 丢掉代理）----
proxy="http://127.0.0.1:1938"
run_cmd env -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
  CAPBOX_PROXY="$proxy" \
  CAPBOX_TEST_SENTINEL="$SENTINEL_VAL" \
  "$CAPBOX_BIN" exec -- sh -c 'printf "PX=%s\nS=%s\n" "${http_proxy:-}" "${CAPBOX_TEST_SENTINEL:-clean}"'
assert_rc 0 "代理白名单 exec 退出码"
assert_stdout_contains "PX=$proxy" "clearenv 后仍注入 CAPBOX_PROXY→http_proxy"
assert_stdout_contains "S=clean" "代理场景下哨兵仍不泄漏"

# ---- 3) service start 路径 ----
mkdir -p "$CAPBOX_DIR/services"
svc_name="t38env"
svc_file="$CAPBOX_DIR/services/${svc_name}.env"
cat >"$svc_file" <<'E'
CMD='sh -c "echo S=${CAPBOX_TEST_SENTINEL:-clean}; echo A=${AWS_ACCESS_KEY_ID:-clean}; echo G=${GITHUB_TOKEN:-clean}; echo SSH=${SSH_AUTH_SOCK:-clean}; echo H=${HOME:-}; sleep 3"'
CWD=/workspace
READY_TIMEOUT=5
RESTART=no
E

run_cmd run_leak_env "$CAPBOX_BIN" service start "$svc_name"
assert_rc 0 "service start t38env 退出码"
ok_log=0
logf="$CASE_OUT/service.log"
for _i in $(seq 1 50); do
  "$CAPBOX_BIN" service logs "$svc_name" -n 200 >"$logf" 2>/dev/null || true
  if [ -f "$logf" ] && grep -q 'S=clean' "$logf" 2>/dev/null; then
    ok_log=1
    break
  fi
  sleep 0.1
done
if [ "$ok_log" = 1 ]; then
  _ok "service 日志出现 S=clean"
  CASE_ASSERTS=$((CASE_ASSERTS + 1))
else
  _fail "service 日志未出现 S=clean（可能仍泄漏或未启动）" \
    "log: $(_short "$(cat "$logf" 2>/dev/null)")"
fi
if [ -f "$logf" ]; then
  if grep -qE "leak-me-t38|AKIA_T38_PROBE|ghp_t38_probe|/tmp/capbox-t38-ssh" "$logf" 2>/dev/null; then
    _fail "service 日志含宿主哨兵/密钥" "log: $(_short "$(cat "$logf")")"
  else
    _ok "service 日志不含宿主哨兵/密钥"
    CASE_ASSERTS=$((CASE_ASSERTS + 1))
  fi
fi
run_cmd "$CAPBOX_BIN" service stop "$svc_name" || true
rm -f "$svc_file"

# ---- 4) 源码契约：两条 bwrap 构造路径都必须 --clearenv ----
for base in common.sh daemon.sh; do
  f="$CAPBOX_DIR/lib/$base"
  if [ ! -f "$f" ]; then
    f="$(cd "$(dirname "$CAPBOX_BIN")/.." && pwd)/lib/$base"
  fi
  if grep -q -- '--clearenv' "$f" 2>/dev/null; then
    _ok "$base 含 --clearenv"
    CASE_ASSERTS=$((CASE_ASSERTS + 1))
  else
    _fail "$base 缺少 --clearenv" "path=$f"
  fi
done

# 运行时参数序：clearenv 必须早于首个 setenv
struct_out="$CASE_OUT/bwrap-args.txt"
struct_err="$CASE_OUT/bwrap-args.err"
lib_root="$CAPBOX_DIR/lib"
if [ ! -f "$lib_root/common.sh" ]; then
  lib_root="$(cd "$(dirname "$CAPBOX_BIN")/.." && pwd)/lib"
fi
(
  set -euo pipefail
  export CAPBOX_DIR CAPBOX_WORKSPACE CAPBOX_ROOTFS CAPBOX_BWRAP
  # shellcheck disable=SC1090
  source "$lib_root/common.sh"
  [ -f "$lib_root/net.sh" ] && source "$lib_root/net.sh"
  [ -f "$lib_root/security.sh" ] && source "$lib_root/security.sh"
  [ -f "$lib_root/fsguard.sh" ] && source "$lib_root/fsguard.sh"
  [ -f "$lib_root/resources.sh" ] && source "$lib_root/resources.sh"
  [ -f "$lib_root/idmap.sh" ] && source "$lib_root/idmap.sh"
  if declare -F load_config >/dev/null 2>&1; then
    load_config >/dev/null 2>&1 || true
  fi
  if declare -F _capbox_derive_paths >/dev/null 2>&1; then
    _capbox_derive_paths >/dev/null 2>&1 || true
  fi
  mapfile -t a < <(build_bwrap_args oneshot /workspace)
  printf '%s\n' "${a[@]}"
) >"$struct_out" 2>"$struct_err" || true

if grep -qx -- '--clearenv' "$struct_out" 2>/dev/null; then
  _ok "build_bwrap_args oneshot 运行时含 --clearenv"
  CASE_ASSERTS=$((CASE_ASSERTS + 1))
  clr_line=$(grep -n -- '--clearenv' "$struct_out" | head -n1 | cut -d: -f1)
  set_line=$(grep -n -- '--setenv' "$struct_out" | head -n1 | cut -d: -f1)
  if [ -n "${clr_line:-}" ] && [ -n "${set_line:-}" ] && [ "$clr_line" -lt "$set_line" ]; then
    _ok "oneshot：--clearenv 位于首个 --setenv 之前（$clr_line < $set_line）"
    CASE_ASSERTS=$((CASE_ASSERTS + 1))
  else
    _fail "oneshot：--clearenv 未位于首个 --setenv 之前" "clear=$clr_line set=$set_line"
  fi
else
  _fail "build_bwrap_args oneshot 运行时缺少 --clearenv" \
    "err: $(_short "$(cat "$struct_err" 2>/dev/null)")" \
    "out: $(_short "$(head -n 30 "$struct_out" 2>/dev/null)")"
fi

# ---- 5) daemon（可选；不调用 require_daemon，以免整案被标 SKIP）----
if [ "${CAPBOX_TEST_DAEMON:-0}" = "1" ] && daemon_is_up; then
  run_cmd run_leak_env "$CAPBOX_BIN" exec --daemon -- sh -c "$probe_cmd"
  assert_rc 0 "exec --daemon 退出码"
  assert_probe_clean "daemon/exec"
  run_cmd "$CAPBOX_BIN" exec --daemon -- sh -c 'printf "D=%s\nV=%s\n" "${CAPBOX_DAEMON_DIR:-}" "${CAPBOX_VERSION:-}"'
  assert_rc 0 "daemon 白名单变量可读"
  if printf '%s' "$RUN_STDOUT" | grep -q '^D=/'; then
    _ok "CAPBOX_DAEMON_DIR 已注入"
    CASE_ASSERTS=$((CASE_ASSERTS + 1))
  else
    _fail "CAPBOX_DAEMON_DIR 未注入" "out=$RUN_STDOUT"
  fi
  if printf '%s' "$RUN_STDOUT" | grep -q '^V='; then
    _ok "CAPBOX_VERSION 已注入"
    CASE_ASSERTS=$((CASE_ASSERTS + 1))
  else
    _fail "CAPBOX_VERSION 未注入" "out=$RUN_STDOUT"
  fi
else
  _ok "daemon 实路径本跑跳过（导出 CAPBOX_TEST_DAEMON=1 并先 capbox up 可启用）"
  CASE_ASSERTS=$((CASE_ASSERTS + 1))
fi

case_finish
exit 0
