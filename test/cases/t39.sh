#!/usr/bin/env bash
# T39 — 缺失配置路径预占：guest 不可创建 config.env / services/*.env（CVE-2026-25725 同类）
# 同时验证宿主侧 config set / service 工作流仍可用。
set -u
CASE_TITLE="缺失配置预占：guest 不可注入 config/services"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖 fsguard 缺失路径预占"
  case_finish; exit 0
fi
require_rootfs || { case_finish; exit 0; }

# 推导工作区（test/lib.sh 不导出 CAPBOX_WORKSPACE）
if [ -n "${CAPBOX_WORKSPACE:-}" ]; then
  _t39_ws="${CAPBOX_WORKSPACE%/}"
elif [ "$(basename -- "$CAPBOX_DIR")" = ".capbox" ]; then
  _t39_ws="$(cd -- "$(dirname -- "$CAPBOX_DIR")" && pwd)"
else
  _t39_ws="$(cd -- "$CAPBOX_DIR" && pwd)"
fi

# 宿主路径 → guest /workspace 视图（与 common.sh _guest_workspace_path 同构）
_guest_path_for_test() {
  local host="${1:-}" ws="${_t39_ws%/}"
  if [ "$host" = "$ws" ]; then
    printf '/workspace'
  elif [ "${host#"$ws"/}" != "$host" ]; then
    printf '/workspace/%s' "${host#"$ws"/}"
  else
    printf ''
  fi
}

cfg="$CAPBOX_DIR/config.env"
svc_dir="$CAPBOX_DIR/services"
log_host="$CAPBOX_DIR/logs/audit.jsonl"
log_guest="$(_guest_path_for_test "$log_host")"
marker="T39_AUDIT_TAMPER_$$"
host_probe="$CAPBOX_DIR/logs/.t39-host-write-$$"
cfg_guest="$(_guest_path_for_test "$cfg")"
svc_guest="$(_guest_path_for_test "$svc_dir")"
if [ -z "$cfg_guest" ] || [ -z "$svc_guest" ] || [ -z "$log_guest" ]; then
  skip_case "CAPBOX_DIR 不在工作区视图内，无法测 /workspace 预占"
  case_finish; exit 0
fi

mkdir -p "$QA_TMP"
cfg_bak=""
svc_bak=""
if [ -e "$cfg" ] || [ -L "$cfg" ]; then
  cfg_bak="$QA_TMP/t39-config.env.bak"
  rm -rf "$cfg_bak"
  mv -- "$cfg" "$cfg_bak"
fi
if [ -e "$svc_dir" ] || [ -L "$svc_dir" ]; then
  svc_bak="$QA_TMP/t39-services.bak"
  rm -rf "$svc_bak"
  mv -- "$svc_dir" "$svc_bak"
fi

restore_t39() {
  "$CAPBOX_BIN" service stop t39ok >/dev/null 2>&1 || true
  if [ -n "${cfg_bak:-}" ] && [ -e "$cfg_bak" ]; then
    rm -f -- "$cfg" 2>/dev/null || true
    mv -- "$cfg_bak" "$cfg"
  fi
  if [ -n "${svc_bak:-}" ] && [ -e "$svc_bak" ]; then
    rm -rf -- "$svc_dir" 2>/dev/null || true
    mv -- "$svc_bak" "$svc_dir"
  else
    rm -f -- "$CAPBOX_DIR/services/t39ok.env" "$CAPBOX_DIR/services/t39evil.env" 2>/dev/null || true
  fi
  rm -f -- "${host_probe:-}" 2>/dev/null || true
  # 只删探针标记行，不截断已有审计日志。
  if [ -n "${log_host:-}" ] && [ -f "$log_host" ] && [ ! -L "$log_host" ] && grep -q -F -- "$marker" "$log_host" 2>/dev/null; then
    _strip="$QA_TMP/t39-audit.strip"
    grep -v -F -- "$marker" "$log_host" >"$_strip" && cat "$_strip" >"$log_host"
    rm -f -- "$_strip"
  fi
}
trap restore_t39 EXIT

# ---- 1) 启动时缺失 config.env：guest 不得注入；宿主不得出现恶意内容 ----
rm -f -- "$cfg"
run_cmd "$CAPBOX_BIN" exec -- sh -c "echo CAPBOX_BWRAP=\\'/tmp/t39-evil\\' > \"$cfg_guest\"; echo WRITE_RC=\$?"
if [ -f "$cfg" ] && grep -q 't39-evil' "$cfg" 2>/dev/null; then
  _fail "缺失 config.env 仍被 guest 注入" "内容: $(head -c 200 "$cfg")"
else
  _ok "缺失 config.env 未被 guest 注入恶意内容"
fi
CASE_ASSERTS=$((CASE_ASSERTS + 1))

run_cmd "$CAPBOX_BIN" exec -- sh -c "echo MALICIOUS > \"$cfg_guest\""
assert_ne 0 "$RUN_RC" "写入预占 config.env 应非零退出"

# ---- 2) 嵌套父路径：services/ 整树缺失时不可创建 *.env ----
rm -rf -- "$svc_dir"
run_cmd "$CAPBOX_BIN" exec -- sh -c "mkdir -p \"$svc_guest\" && echo CMD=\\'touch /tmp/pwned\\' > \"$svc_guest/t39evil.env\"; echo WRITE_RC=\$?"
if [ -f "$svc_dir/t39evil.env" ]; then
  _fail "缺失 services/ 时 guest 仍创建了 t39evil.env" "内容: $(cat "$svc_dir/t39evil.env" 2>/dev/null)"
else
  _ok "缺失 services/ 时 guest 无法创建服务定义"
fi
CASE_ASSERTS=$((CASE_ASSERTS + 1))

run_cmd "$CAPBOX_BIN" exec -- sh -c "echo CMD=true > \"$svc_guest/t39evil.env\""
assert_ne 0 "$RUN_RC" "写入 services/*.env 应非零退出"

# ---- 3) 宿主合法工作流：config set 仍可写 config.env ----
run_cmd "$CAPBOX_BIN" config set CAPBOX_HOSTNAME t39-host
assert_rc 0 "宿主 config set 退出码"
assert_file_contains "$cfg" "t39-host" "宿主 config set 写入 hostname"

run_cmd "$CAPBOX_BIN" exec -- sh -c "echo HACKED >> \"$cfg_guest\""
assert_ne 0 "$RUN_RC" "已存在 config.env 对 guest 仍只读"
if grep -q HACKED "$cfg" 2>/dev/null; then
  _fail "guest 篡改了已存在的 config.env"
else
  _ok "已存在 config.env 未被 guest 篡改"
fi
CASE_ASSERTS=$((CASE_ASSERTS + 1))

# ---- 4) 宿主合法 service 定义 + start 仍可用 ----
mkdir -p "$svc_dir"
cat >"$svc_dir/t39ok.env" <<'E'
CMD='sh -c "echo T39_SVC_OK; sleep 2"'
CWD=/workspace
READY_TIMEOUT=5
RESTART=no
E
run_cmd "$CAPBOX_BIN" service start t39ok
assert_rc 0 "宿主 service start 退出码"
ok_log=0
logf="$CAPBOX_DIR/run/services/t39ok/service.log"
for _i in $(seq 1 50); do
  if [ -f "$logf" ] && grep -q 'T39_SVC_OK' "$logf" 2>/dev/null; then
    ok_log=1
    break
  fi
  sleep 0.1
done
if [ "$ok_log" = 1 ]; then
  _ok "合法 service 日志出现 T39_SVC_OK"
else
  _fail "合法 service 未跑起来或日志无 T39_SVC_OK" "log=$(tail -c 400 "$logf" 2>/dev/null)"
fi
CASE_ASSERTS=$((CASE_ASSERTS + 1))
run_cmd "$CAPBOX_BIN" service stop t39ok
assert_rc 0 "service stop 退出码"

# ---- 5) 已有 services 目录时仍不可新增恶意 env ----
run_cmd "$CAPBOX_BIN" exec -- sh -c "echo CMD=true > \"$svc_guest/t39evil.env\""
assert_ne 0 "$RUN_RC" "已有 services/ 时 guest 仍不可创建 *.env"
if [ -f "$svc_dir/t39evil.env" ]; then
  _fail "guest 在已有 services/ 下创建了 t39evil.env"
else
  _ok "已有 services/ 下 guest 无法新建 *.env"
fi
CASE_ASSERTS=$((CASE_ASSERTS + 1))

# ---- 6) logs/audit.jsonl 对 guest 只读；宿主仍可写 logs/ ----
mkdir -p "$CAPBOX_DIR/logs"
run_cmd "$CAPBOX_BIN" exec -- sh -c "echo $marker >> \"$log_guest\""
assert_ne 0 "$RUN_RC" "guest 追加 audit.jsonl 应非零退出"
if [ -f "$log_host" ] && grep -q -F -- "$marker" "$log_host" 2>/dev/null; then
  _fail "guest 写入了 logs/audit.jsonl"
else
  _ok "guest 未能写入 logs/audit.jsonl"
fi
CASE_ASSERTS=$((CASE_ASSERTS + 1))
if printf 'host\n' >"$host_probe" 2>/dev/null; then
  _ok "宿主仍可在 logs/ 下创建文件"
  rm -f -- "$host_probe"
else
  _fail "宿主无法在 logs/ 下创建文件"
fi
CASE_ASSERTS=$((CASE_ASSERTS + 1))

case_finish
