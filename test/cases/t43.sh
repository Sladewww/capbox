#!/usr/bin/env bash
# T43 — 审计 summary 记下脱敏完整参数；覆盖面与输出边界
set -u
CASE_TITLE="审计：summary 参数、脱敏与覆盖面"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

AUDIT_LIB="$(cd "$(dirname "$CAPBOX_BIN")/../lib" && pwd)/audit.sh"
assert_file_exists "$AUDIT_LIB" "CLI 库中有 audit.sh"

unit_dir="$QA_TMP/audit-unit"
rm -rf "$unit_dir"
mkdir -p "$unit_dir/logs"

# --- 1) summary 能看到脱敏后的完整参数；--password 被抹，-p 不被抹 ---
unit_script="$QA_TMP/audit-unit-run.sh"
cat >"$unit_script" <<'UNIT'
set -euo pipefail
log_err() { printf '%s\n' "$*" >&2; }
# shellcheck disable=SC1090
source "$1"
CAPBOX_DIR="$2"
CAPBOX_AUDIT=summary
unset CAPBOX_AUDIT_CMD
cmd=$(_audit_cmd_field "echo hello world --password s3cret -p 8080")
printf 'CMD=%s\n' "$cmd"
printf 'RED_LONG=%s\n' "$(_audit_redact 'run --password s3cret --token abc -p 8080')"
printf 'RED_EQ=%s\n' "$(_audit_redact 'run --password=s3cret -p 8080')"
printf 'RED_KV=%s\n' "$(_audit_redact 'curl password=s3cret')"
printf 'RED_FILE=%s\n' "$(_audit_redact 'run --password-file /tmp/x')"
join_sample="'echo' 'marker' '--password' 's3cret' '-p' '8080'"
printf 'RED_JOIN=%s\n' "$(_audit_redact "$join_sample")"
audit_event exec ok "cmd=echo hello world --password s3cret -p 8080" "exit=0" "ms=3" "output=STDOUT_SHOULD_STAY_OUT"
CAPBOX_AUDIT=full
audit_event exec ok "cmd=fullmode" "exit=0" "ms=1" "output=FULL_OUTPUT_OK"
UNIT
run_cmd bash "$unit_script" "$AUDIT_LIB" "$unit_dir"
assert_rc 0 "单元审计脚本退出码"
assert_stdout_matches 'CMD=echo hello world --password \*\*\*REDACTED\*\*\* -p 8080' "summary cmd 含完整参数且口令已脱敏"
assert_stdout_not_contains 's3cret' "summary/脱敏输出不含明文口令"
assert_stdout_matches 'RED_LONG=run --password \*\*\*REDACTED\*\*\* --token \*\*\*REDACTED\*\*\* -p 8080' "长选项空格形式脱敏，-p 保留"
assert_stdout_matches 'RED_EQ=run --password=\*\*\*REDACTED\*\*\* -p 8080' "长选项等号形式脱敏"
assert_stdout_matches 'RED_KV=curl password=\*\*\*REDACTED\*\*\*' "password= 赋值脱敏"
assert_stdout_matches 'RED_FILE=run --password-file /tmp/x' "--password-file 不被误伤"
assert_stdout_matches "RED_JOIN='echo' 'marker' '--password' \*\*\*REDACTED\*\*\* '-p' '8080'" "join_cmd_str 引号形式脱敏且保留 -p"

unit_log="$unit_dir/logs/audit.jsonl"
assert_file_exists "$unit_log" "单元测试写入了 audit.jsonl"
assert_file_contains "$unit_log" 'hello world' "summary 记录含完整参数"
assert_file_contains "$unit_log" '--password ***REDACTED***' "记录中 --password 已脱敏"
assert_file_contains "$unit_log" '-p 8080' "记录中 -p 8080 未被抹掉"
if grep -q 's3cret' "$unit_log"; then
  _fail "audit.jsonl 含明文口令 s3cret"
else
  _ok "audit.jsonl 不含明文口令"
fi
if grep -q 'STDOUT_SHOULD_STAY_OUT' "$unit_log"; then
  _fail "summary 模式下 output 不应写入 jsonl"
else
  _ok "summary 不写命令输出"
fi
assert_file_contains "$unit_log" 'FULL_OUTPUT_OK' "full 模式写入封顶后的 output"

# --- 2) help 与 audit 自身不记 ---
if is_fake_cli; then
  _ok "假 CLI 桩：跳过真实命令覆盖面"
  case_finish
  exit 0
fi

if ! rootfs_ready "$(config_distro)"; then
  _fail "前置条件未满足：rootfs 不存在，无法测 exec/shell 覆盖面"
  case_finish
  exit 1
fi

auditf="$CAPBOX_DIR/logs/audit.jsonl"
mkdir -p "$(dirname "$auditf")"
: >"$auditf"

run_cmd "$CAPBOX_BIN" audit --help
assert_rc 0 "audit --help 退出码"
run_cmd "$CAPBOX_BIN" exec --help
assert_rc 0 "exec --help 退出码"
if [[ -s "$auditf" ]]; then
  _fail "help 不应写入 audit.jsonl（实际: $(cat "$auditf"))"
else
  _ok "help 与 audit 自身不写审计"
fi

# --- 3) exec：参数可见、口令脱敏、-p 保留、stdout 不进 jsonl ---
run_cmd "$CAPBOX_BIN" exec -- sh -c 'echo STDOUT_T43_$((1+2+3+4)); echo hello world --password s3cret -p 8080 >/dev/null; exit 0'
assert_rc 0 "exec 退出码"
assert_stdout_contains 'STDOUT_T43_10' "exec 的 stdout 可见"

exec_lines=$(grep -c '"kind":"exec"' "$auditf" || true)
assert_int_ge "$exec_lines" 1 "exec 至少一条审计"
if grep '"kind":"exec"' "$auditf" | grep -q 's3cret'; then
  _fail "exec 审计含明文口令"
else
  _ok "exec 审计不含明文口令"
fi
if grep '"kind":"exec"' "$auditf" | grep -q 'STDOUT_T43_10'; then
  _fail "命令 stdout 不应进入 audit.jsonl"
else
  _ok "命令输出不进 jsonl"
fi
# The guest command string in this exec does not itself include --password;
# exercise redaction via a command line that does:
: >"$auditf"
run_cmd "$CAPBOX_BIN" exec -- echo marker --password s3cret -p 8080
assert_rc 0 "exec echo 退出码"
assert_file_contains "$auditf" '"kind":"exec"' "echo exec 有审计"
assert_file_contains "$auditf" '***REDACTED***' "exec cmd 脱敏口令"
if grep -q -- "-p 8080" "$auditf" || grep -q -- "'-p' '8080'" "$auditf"; then
  _ok "exec cmd 保留 -p 8080"
else
  _fail "exec cmd 未保留 -p 8080"
  echo "      实际内容: $(tr '\n' ' ' < "$auditf")"
fi
assert_file_contains "$auditf" '--password' "exec cmd 仍含 --password 参数名"
assert_file_contains "$auditf" '"exit":0' "exec 记录退出码"
if grep -q 's3cret' "$auditf"; then
  _fail "echo exec 审计含明文口令"
else
  _ok "echo exec 审计不含明文口令"
fi

# --- 4) shell 只有一条启动记录，不含会话内命令 ---
: >"$auditf"
shell_script="$QA_TMP/t43-shell.sh"
printf 'echo SHELL_LINE_ONE\necho SHELL_LINE_TWO\nexit 0\n' >|"$shell_script"
run_cmd bash -c "$(printf '%q' "$CAPBOX_BIN") shell < $(printf '%q' "$shell_script")"
assert_rc 0 "shell 退出码"
shell_lines=$(grep -c '"kind":"shell"' "$auditf" || true)
assert_eq 1 "$shell_lines" "shell 只有一条启动记录"
if grep -q 'SHELL_LINE_ONE\|SHELL_LINE_TWO' "$auditf"; then
  _fail "shell 审计不应包含会话内命令"
else
  _ok "shell 审计不记会话内每一行"
fi
assert_file_contains "$auditf" '"kind":"shell"' "有 shell 记录"
assert_file_contains "$auditf" '"exit":' "shell 记录含退出码"

# --- 5) pkg / doctor / init（幂等）各一条 ---
: >"$auditf"
run_cmd "$CAPBOX_BIN" pkg list
assert_file_contains "$auditf" '"kind":"pkg"' "pkg 有审计"
assert_file_contains "$auditf" '"exit":' "pkg 记录含退出码"

: >"$auditf"
run_cmd "$CAPBOX_BIN" doctor || true
assert_file_contains "$auditf" '"kind":"doctor"' "doctor 有审计"
assert_file_contains "$auditf" '"exit":' "doctor 记录含退出码"

: >"$auditf"
run_cmd "$CAPBOX_BIN" init
assert_rc 0 "幂等 init 退出码"
assert_file_contains "$auditf" '"kind":"init"' "init 有审计"
assert_file_contains "$auditf" '"exit":0' "init 记录退出码"

# --- 6) 走常驻容器的 exec：有 daemon 才测，否则跳过该段 ---
if [ "${CAPBOX_TEST_DAEMON:-0}" = "1" ] && daemon_is_up; then
  : >"$auditf"
  run_cmd "$CAPBOX_BIN" exec --daemon -- echo DAEMON_EXEC_T43
  assert_rc 0 "daemon exec 退出码"
  if grep '"kind":"exec"' "$auditf" | grep -q 'DAEMON_EXEC_T43'; then
    _ok "daemon exec 有审计记录"
  else
    _fail "daemon exec 结束后应写入 exec 审计（实际: $(cat "$auditf"))"
  fi
  assert_file_contains "$auditf" '"exit":' "daemon exec 记录含退出码"
else
  _ok "未设置 CAPBOX_TEST_DAEMON=1 或守护容器未运行，跳过 daemon exec 审计"
fi

case_finish
exit 0
