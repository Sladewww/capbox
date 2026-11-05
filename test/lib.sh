#!/usr/bin/env bash
# =============================================================================
# .capbox/test/lib.sh — CapBox 验收测试框架（断言库 + 用例生命周期）
# -----------------------------------------------------------------------------
# 由 run.sh source。设计原则：
#   1) 断言只记录失败，绝不 exit，因此单个断言失败不影响同用例的后续断言。
#   2) 每条断言都打印「期望 vs 实际」，run_cmd 还会打印实际执行的命令与输出，
#      失败时能直接定位。
#   3) 每个用例在独立子 shell 中执行（run.sh 负责），一个 FAIL 不阻断其余用例。
#   4) 临时文件全部落在 .capbox/test/tmp/qa/ 下，由 run.sh 每次启动清理。
#   5) 契约 §7 的断言是硬断言，不允许为了变绿放宽；对契约本身存在歧义的点，
#      用 mark_known_issue 显式打印，仍会出现在汇总里。
# =============================================================================

# 防重复 source
if [ -n "${CAPBOX_TEST_LIB_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
CAPBOX_TEST_LIB_LOADED=1

# ---------------------------------------------------------------------------
# 路径解析（全部由本文件位置推导，因此可以整体拷到沙箱工作区里自测）
# ---------------------------------------------------------------------------
CAPBOX_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 本套件位于 <capbox dir>/test/，上一级就是 CapBox 根。不假设它叫 .capbox ——
# 仓库可能以任意目录名存在（甚至直接放在工作区根做开发）。
# 仓库布局兼容：
#   A) 测试在 .capbox/test/ → CAPBOX_DIR=.capbox，工作区=其父目录
#   B) 测试在 repo/test/ 且存在 repo/.capbox → CAPBOX_DIR=repo/.capbox，工作区=repo
#   C) 旧式「仓库即状态」→ CAPBOX_DIR=repo
_capbox_test_repo="$(cd "$CAPBOX_TEST_DIR/.." && pwd)"
if [ "$(basename "$CAPBOX_TEST_DIR")" = "test" ] && [ "$(basename "$_capbox_test_repo")" = ".capbox" ]; then
  CAPBOX_DIR="$_capbox_test_repo"
  CAPBOX_TEST_WS="$(dirname "$CAPBOX_DIR")"
elif [ -d "$_capbox_test_repo/.capbox/lib" ] || [ -e "$_capbox_test_repo/.capbox/bin/capbox" ]; then
  CAPBOX_DIR="$_capbox_test_repo/.capbox"
  CAPBOX_TEST_WS="$_capbox_test_repo"
else
  CAPBOX_DIR="$_capbox_test_repo"
  CAPBOX_TEST_WS="$(dirname "$CAPBOX_DIR")"
fi
# 优先用仓库根/模板上的 bin（开发树）；否则用状态树内 bin
if [ -z "${CAPBOX_TEST_BIN:-}" ]; then
  if [ -x "$_capbox_test_repo/bin/capbox" ]; then
    CAPBOX_BIN="$_capbox_test_repo/bin/capbox"
  elif [ -x "$CAPBOX_DIR/bin/capbox" ]; then
    CAPBOX_BIN="$CAPBOX_DIR/bin/capbox"
  else
    CAPBOX_BIN="$CAPBOX_DIR/bin/capbox"
  fi
else
  CAPBOX_BIN="$CAPBOX_TEST_BIN"
fi
unset _capbox_test_repo
CAPBOX_TEST_TMP="${CAPBOX_TEST_TMP:-$CAPBOX_TEST_DIR/tmp}" # 临时根
# 本框架独占的临时区。
# ⚠ 必须带运行实例 ID 后缀：run.sh 启动时会 rm -rf 整个 qa/，如果两个人（或两个 DSH 会话）
# 同时跑测试，后来者会把先跑者的 case 输出目录删掉，导致「cat: 没有那个文件或目录」
# 这种假失败（自测时踩过）。带 ID 后并发跑互不干扰。
CAPBOX_TEST_RUN_ID="${CAPBOX_TEST_RUN_ID:-$$}"
QA_TMP="$CAPBOX_TEST_TMP/qa-$CAPBOX_TEST_RUN_ID"

# 输出长度上限（行），超出截断并提示完整文件位置
CAPBOX_TEST_MAX_OUTPUT_LINES="${CAPBOX_TEST_MAX_OUTPUT_LINES:-25}"

# ---------------------------------------------------------------------------
# 颜色（非 tty 或 NO_COLOR 时自动关闭）
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_DIM=$'\033[2m'
else
  C_RST=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''
fi

# ---------------------------------------------------------------------------
# 被测 CLI 调用必须穿越 fuzz 环境（如 CAPBOX_PROXY）时用 capbox_raw
# ---------------------------------------------------------------------------
capbox() { "$CAPBOX_BIN" "$@"; }

# 自测假 CLI 桩（含 FAKE_DEFECTS）无法覆盖真 CLI 的安全/脚手架语义
is_fake_cli() {
  [ -n "${CAPBOX_TEST_FAKE_CLI:-}" ] && return 0
  [ -f "$CAPBOX_BIN" ] && grep -q 'FAKE_DEFECTS' "$CAPBOX_BIN" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 用例生命周期
# ---------------------------------------------------------------------------
case_begin() {
  CASE_ID="$1"
  CASE_NAME="$2"
  CASE_OUT="$3"
  CASE_ASSERTS=0
  CASE_FAILS=0
  CASE_SKIP_REASON=""
  RUN_SEQ=0
  RUN_CWD=""
  RUN_RC=0
  RUN_STDOUT=""
  RUN_STDERR=""
  RUN_ELAPSED_MS=0
  mkdir -p "$CASE_OUT"
  : >"$CASE_OUT/failures.txt"
  : >"$CASE_OUT/known-issues.txt"
}

case_finish() {
  local status
  if [ "$CASE_FAILS" -gt 0 ]; then
    status=FAIL
  elif [ -n "$CASE_SKIP_REASON" ]; then
    status=SKIP
  else
    status=PASS
  fi
  local reason
  reason="$(printf '%s' "${CASE_SKIP_REASON:-}" | tr '\n' ' ' | tr -s ' ')"
  printf '%s\n' "$status $CASE_ASSERTS $CASE_FAILS $reason" >"$QA_TMP/status/$CASE_ID"
  if [ -s "$CASE_OUT/known-issues.txt" ]; then
    sed "s/^/KNOWN-ISSUE [$CASE_ID] /" "$CASE_OUT/known-issues.txt" >>"$QA_TMP/known-issues.txt"
  fi
  printf '  %s→ 断言 %s 条，失败 %s 条%s\n' "$C_DIM" "$CASE_ASSERTS" "$CASE_FAILS" "$C_RST"
}

# 跳过当前用例（打印原因）。多次调用以第一次为准。
skip_case() {
  [ -n "$CASE_SKIP_REASON" ] || CASE_SKIP_REASON="$*"
  printf '  %s⊘ SKIP%s %s\n' "$C_YELLOW" "$C_RST" "$*"
}

# 显式记录契约符合性差异（打印 + 汇总里单列），但**不算通过**：
# 如果该点同时是硬断言失败，断言仍然计 FAIL。
mark_known_issue() {
  printf '  %s⚠ KNOWN-ISSUE%s %s\n' "$C_YELLOW" "$C_RST" "$*"
  printf -- '- %s\n' "$*" >>"$CASE_OUT/known-issues.txt"
}

# ---------------------------------------------------------------------------
# 命令执行器：打印命令 → 执行 → 打印 stdout/stderr/rc，永不中断
#   可选：调用前设置 RUN_CWD=DIR，则在该目录下执行
# ---------------------------------------------------------------------------
_quote_cmd() {
  local out="" a
  for a in "$@"; do
    out+="$(printf '%q' "$a") "
  done
  printf '%s' "${out% }"
}

_print_output_block() {
  local label="$1" file="$2"
  if [ ! -s "$file" ]; then
    printf '    %s: %s(空)%s\n' "$label" "$C_DIM" "$C_RST"
    return 0
  fi
  local total max
  total=$(wc -l <"$file")
  max="$CAPBOX_TEST_MAX_OUTPUT_LINES"
  printf '    %s:\n' "$label"
  head -n "$max" "$file" | sed 's/^/      /'
  if [ "$total" -gt "$max" ]; then
    printf '      %s...（已截断：共 %s 行，完整输出见 %s）%s\n' \
      "$C_DIM" "$total" "$file" "$C_RST"
  fi
}

run_cmd() {
  RUN_SEQ=$((RUN_SEQ + 1))
  # 防御：如果临时目录被外部删掉（例如另一个 run.sh 实例误清），重建它而不是报错
  [ -d "$CASE_OUT" ] || mkdir -p "$CASE_OUT" 2>/dev/null
  local out="$CASE_OUT/cmd-$RUN_SEQ.out" err="$CASE_OUT/cmd-$RUN_SEQ.err"
  local pretty
  pretty=$(_quote_cmd "$@")
  RUN_STDOUT_FILE="$out"; RUN_STDERR_FILE="$err"
  printf '  %s$%s %s\n' "$C_DIM" "$C_RST" "$pretty"
  [ -n "${RUN_CWD:-}" ] && printf '    %s(cwd: %s)%s\n' "$C_DIM" "$RUN_CWD" "$C_RST"
  local start end
  RUN_LAST_PRETTY="$pretty"
  start=$(date +%s%N)
  if [ -n "${RUN_CWD:-}" ]; then
    ( cd "$RUN_CWD" && "$@" ) >"$out" 2>"$err"
  else
    "$@" >"$out" 2>"$err"
  fi
  RUN_RC=$?
  end=$(date +%s%N)
  RUN_ELAPSED_MS=$(( (end - start) / 1000000 ))
  RUN_STDOUT=$(_cat_file "$out")
  RUN_STDERR=$(_cat_file "$err")
  _print_output_block stdout "$out"
  _print_output_block stderr "$err"
  printf '  %s→ rc=%s（%sms）%s\n' "$C_DIM" "$RUN_RC" "$RUN_ELAPSED_MS" "$C_RST"
  return 0
}

# ---------------------------------------------------------------------------
# 断言原语
# ---------------------------------------------------------------------------
_ok() {
  CASE_ASSERTS=$((CASE_ASSERTS + 1))
  printf '  %s✓%s %s\n' "$C_GREEN" "$C_RST" "$1"
}

_fail() {
  CASE_ASSERTS=$((CASE_ASSERTS + 1))
  CASE_FAILS=$((CASE_FAILS + 1))
  local msg="$1"; shift
  printf '  %s✗ FAIL%s %s\n' "$C_RED" "$C_RST" "$msg"
  local line
  for line in "$@"; do
    printf '      %s\n' "$line"
  done
  printf -- '- %s\n' "$msg" >>"$CASE_OUT/failures.txt"
}

# 把多行文本压成一行摘要，避免刷屏
_short() {
  printf '%s' "$1" | head -n "${2:-3}" | tr '\n' '|' | cut -c1-400
}

assert_rc() {
  local want="$1" label="${2:-退出码}"
  if [ "${RUN_RC:-}" = "$want" ]; then
    _ok "$label = $want"
  else
    _fail "$label 期望 $want，实际 ${RUN_RC:-<未执行>}" \
      "命令: $(_short "$(_last_cmd)")" \
      "完整输出: $RUN_STDOUT_FILE / $RUN_STDERR_FILE"
  fi
}

_last_cmd() { printf '%s' "${RUN_LAST_PRETTY:-}"; }

# 记录命令文本（供失败摘要使用）
_track_cmd() { RUN_LAST_PRETTY="$*"; }

assert_eq() { # 期望 实际 [标签]
  local want="$1" got="$2" label="${3:-值}"
  if [ "$want" = "$got" ]; then
    _ok "$label = $want"
  else
    _fail "$label 期望 '$want'，实际 '$got'"
  fi
}

assert_ne() {
  local bad="$1" got="$2" label="${3:-值}"
  if [ "$got" != "$bad" ]; then
    _ok "$label != '$bad'"
  else
    _fail "$label 不应等于 '$bad'"
  fi
}

assert_stdout_eq() {
  local want="$1" label="${2:-stdout}"
  if [ "${RUN_STDOUT:-}" = "$want" ]; then
    _ok "$label == '$want'"
  else
    _fail "$label 期望 '$want'，实际 '$(_short "${RUN_STDOUT:-}")'" \
      "完整 stdout: $(_short "$(_cat_file "$RUN_STDOUT_FILE")" 5)"
  fi
}

assert_stdout_contains() {
  local needle="$1" label="${2:-stdout 包含}"
  if printf '%s' "${RUN_STDOUT:-}" | grep -qF -- "$needle"; then
    _ok "$label '$needle'"
  else
    _fail "$label '$needle'：未找到" \
      "实际 stdout: $(_short "${RUN_STDOUT:-}")"
  fi
}

assert_stdout_matches() {
  local re="$1" label="${2:-stdout 匹配}"
  if printf '%s' "${RUN_STDOUT:-}" | grep -qE -- "$re"; then
    _ok "$label /$re/"
  else
    _fail "$label /$re/：未匹配" \
      "实际 stdout: $(_short "${RUN_STDOUT:-}")"
  fi
}

assert_stdout_not_contains() {
  local needle="$1" label="${2:-stdout 不含}"
  if printf '%s' "${RUN_STDOUT:-}" | grep -qF -- "$needle"; then
    _fail "$label '$needle'：却出现了" "实际 stdout: $(_short "${RUN_STDOUT:-}")"
  else
    _ok "$label '$needle'"
  fi
}

# stdout + stderr 联合断言
assert_out_contains() {
  local needle="$1" label="${2:-输出包含}"
  if printf '%s\n%s' "${RUN_STDOUT:-}" "${RUN_STDERR:-}" | grep -qF -- "$needle"; then
    _ok "$label '$needle'"
  else
    _fail "$label '$needle'：未找到" \
      "stdout: $(_short "${RUN_STDOUT:-}")" \
      "stderr: $(_short "${RUN_STDERR:-}")"
  fi
}

assert_out_matches() {
  local re="$1" label="${2:-输出匹配}"
  if printf '%s\n%s' "${RUN_STDOUT:-}" "${RUN_STDERR:-}" | grep -qE -- "$re"; then
    _ok "$label /$re/"
  else
    _fail "$label /$re/：未匹配" \
      "stdout: $(_short "${RUN_STDOUT:-}")" \
      "stderr: $(_short "${RUN_STDERR:-}")"
  fi
}

assert_out_not_matches() {
  local re="$1" label="${2:-输出不匹配}"
  if printf '%s\n%s' "${RUN_STDOUT:-}" "${RUN_STDERR:-}" | grep -qE -- "$re"; then
    _fail "$label /$re/：却匹配了" "实际输出: $(_short "${RUN_STDOUT:-}${RUN_STDERR:-}")"
  else
    _ok "$label 不含 /$re/"
  fi
}

# 忽略大小写版本（doctor 等输出大小写风格由实现决定）
assert_out_matches_i() {
  local re="$1" label="${2:-输出匹配}"
  if printf '%s\n%s' "${RUN_STDOUT:-}" "${RUN_STDERR:-}" | grep -qiE -- "$re"; then
    _ok "$label /$re/i"
  else
    _fail "$label /$re/i：未匹配" \
      "stdout: $(_short "${RUN_STDOUT:-}")" \
      "stderr: $(_short "${RUN_STDERR:-}")"
  fi
}

assert_stdout_matches_i() {
  local re="$1" label="${2:-stdout 匹配}"
  if printf '%s' "${RUN_STDOUT:-}" | grep -qiE -- "$re"; then
    _ok "$label /$re/i"
  else
    _fail "$label /$re/i：未匹配" "实际 stdout: $(_short "${RUN_STDOUT:-}")"
  fi
}

# 统计最近一次命令输出（stdout+stderr）里匹配某正则的行数
count_out() {
  local re="$1"
  cat "${RUN_STDOUT_FILE:-/dev/null}" "${RUN_STDERR_FILE:-/dev/null}" 2>/dev/null \
    | grep -cE -- "$re" 2>/dev/null || true
}

_cat_file() { [ -f "$1" ] && cat "$1" || printf ''; }

# 打印一条即将执行的命令（用于手工编排的并行/多步场景）
announce() { printf '  %s$%s %s\n' "$C_DIM" "$C_RST" "$*"; }

# 读取配置值：环境变量 > config.env > 默认值（不 source 配置文件，避免污染测试进程）
config_value() { # KEY [DEFAULT]
  local key="$1" def="${2:-}" v
  v=$(printf '%s' "${!key:-}")
  if [ -n "$v" ]; then
    printf '%s' "$v"
    return 0
  fi
  local f="$CAPBOX_DIR/config.env"
  if [ -f "$f" ]; then
    v=$(sed -n "s/^[[:space:]]*$key=//p" "$f" | tail -n 1)
    v=$(printf '%s' "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
  fi
  printf '%s' "${v:-$def}"
}

assert_file_exists() {
  local f="$1" label="${2:-文件存在}"
  if [ -e "$f" ]; then
    _ok "$label: $f"
  else
    _fail "$label 期望存在：$f（不存在）"
  fi
}

assert_file_absent() {
  local f="$1" label="${2:-文件不存在}"
  if [ -e "$f" ]; then
    _fail "$label 期望不存在：$f（却存在）"
  else
    _ok "$label: $f"
  fi
}

assert_file_contains() {
  local f="$1" needle="$2" label="${3:-文件内容包含}"
  if [ ! -e "$f" ]; then
    _fail "$label '$needle'：文件不存在 $f"
    return 0
  fi
  if grep -qF -- "$needle" "$f" 2>/dev/null; then
    _ok "$label '$needle'（$f）"
  else
    _fail "$label '$needle'：未找到（$f）" "实际内容: $(_short "$(cat "$f" 2>/dev/null)")"
  fi
}

assert_int_gt() {
  local n="$1" bound="$2" label="${3:-数值}"
  if printf '%s' "$n" | grep -qE '^-?[0-9]+$' && [ "$n" -gt "$bound" ]; then
    _ok "$label = $n (> $bound)"
  else
    _fail "$label 期望 > $bound，实际 '$n'"
  fi
}

assert_int_le() {
  local n="$1" bound="$2" label="${3:-数值}"
  if printf '%s' "$n" | grep -qE '^-?[0-9]+$' && [ "$n" -le "$bound" ]; then
    _ok "$label = $n (<= $bound)"
  else
    _fail "$label 期望 <= $bound，实际 '$n'"
  fi
}

assert_int_ge() {
  local n="$1" bound="$2" label="${3:-数值}"
  if printf '%s' "$n" | grep -qE '^-?[0-9]+$' && [ "$n" -ge "$bound" ]; then
    _ok "$label = $n (>= $bound)"
  else
    _fail "$label 期望 >= $bound，实际 '$n'"
  fi
}

# ---------------------------------------------------------------------------
# JSON 断言（用 python3 严格解析，不依赖 jq）
# ---------------------------------------------------------------------------
# json_get FILE KEYPATH → 成功打印值，失败返回非 0：
#   2 = 不是合法 JSON，3 = 键路径不存在
json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    raw = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace').strip()
    d = json.loads(raw)
except Exception:
    sys.exit(2)
cur = d
for k in sys.argv[2].split('.'):
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        sys.exit(3)
if isinstance(cur, bool):
    print('true' if cur else 'false')
elif cur is None:
    print('null')
elif isinstance(cur, (int, float)):
    print(cur)
else:
    print(cur)
PY
}

assert_json_valid() {
  local label="${1:-status --json 合法}"
  local tmp="$CASE_OUT/json-probe.json"
  printf '%s' "${RUN_STDOUT:-}" >"$tmp"
  local rc=0
  json_get "$tmp" "__no_such_key__" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = "3" ] || [ "$rc" = "0" ]; then
    _ok "$label（JSON 可解析）"
  else
    _fail "$label：不是合法 JSON（python 解析失败）" \
      "实际 stdout: $(_short "${RUN_STDOUT:-}" 5)"
  fi
}

assert_json_key() {
  local path="$1" label="${2:-JSON 字段}"
  local tmp="$CASE_OUT/json-probe.json"
  printf '%s' "${RUN_STDOUT:-}" >"$tmp"
  local val rc=0
  val=$(json_get "$tmp" "$path" 2>/dev/null) || rc=$?
  if [ "$rc" = "0" ]; then
    _ok "$label '$path' 存在（= $val）"
  elif [ "$rc" = "2" ]; then
    _fail "$label '$path'：stdout 不是合法 JSON" "实际 stdout: $(_short "${RUN_STDOUT:-}" 5)"
  else
    _fail "$label '$path'：字段缺失" "实际 stdout: $(_short "${RUN_STDOUT:-}" 5)"
  fi
}

assert_json_value() {
  local path="$1" want="$2" label="${3:-JSON 值}"
  local tmp="$CASE_OUT/json-probe.json"
  printf '%s' "${RUN_STDOUT:-}" >"$tmp"
  local val rc=0
  val=$(json_get "$tmp" "$path" 2>/dev/null) || rc=$?
  if [ "$rc" = "0" ] && [ "$val" = "$want" ]; then
    _ok "$label '$path' = $want"
  else
    _fail "$label '$path' 期望 '$want'，实际 '$val'（rc=$rc）" \
      "实际 stdout: $(_short "${RUN_STDOUT:-}" 5)"
  fi
}

assert_json_int() {
  local path="$1" label="${2:-JSON 整数}"
  local tmp="$CASE_OUT/json-probe.json"
  printf '%s' "${RUN_STDOUT:-}" >"$tmp"
  local val rc=0
  val=$(json_get "$tmp" "$path" 2>/dev/null) || rc=$?
  if [ "$rc" = "0" ] && printf '%s' "$val" | grep -qE '^[0-9]+$'; then
    _ok "$label '$path' = $val（整数）"
  else
    _fail "$label '$path' 期望整数，实际 '$val'" "实际 stdout: $(_short "${RUN_STDOUT:-}" 5)"
  fi
}

# 单行 JSON：stdout 去尾空行后只能有 1 行，且能被解析
assert_single_line_json() {
  local label="${1:-单行 JSON}"
  local lines
  lines=$(printf '%s' "${RUN_STDOUT:-}" | wc -l)
  if [ "$lines" -le 0 ]; then
    _ok "$label（1 行）"
  else
    _fail "$label 期望单行，实际 $((lines + 1)) 行" \
      "实际 stdout: $(_short "${RUN_STDOUT:-}" 3)"
  fi
}

# ---------------------------------------------------------------------------
# 环境探测辅助（不重复探测系统事实，只读 CLI 自己产出的状态）
# ---------------------------------------------------------------------------
# 当前配置的发行版：优先环境变量，其次 config.env，最后默认 alpine
config_distro() {
  local f="$CAPBOX_DIR/config.env" d="${CAPBOX_DISTRO:-}"
  if [ -n "$d" ]; then
    printf '%s' "$d"
    return 0
  fi
  if [ -f "$f" ]; then
    d=$(sed -n 's/^[[:space:]]*CAPBOX_DISTRO=//p' "$f" | tail -n 1)
    d=$(printf '%s' "$d" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
  fi
  printf '%s' "${d:-alpine}"
}

rootfs_dir_for() { printf '%s/os/%s' "$CAPBOX_DIR" "$1"; }

# rootfs 内是否「有」某路径。
# ⚠ 关键陷阱：alpine 的 /bin/sh 是绝对符号链接 → /bin/busybox。
# 宿主上 `test -e os/alpine/bin/sh` 会跟随这个绝对链接到**宿主**的 /bin/busybox
# （通常不存在）而误报「不存在」；但它在容器内是完全有效的。
# 因此这里对绝对符号链接按 rootfs 根重新解析，而不是相信宿主的 test -e。
rootfs_path_exists() { # ROOTFS_PATH  （如 $CAPBOX_DIR/os/alpine/bin/sh）
  local full="$1"
  [ -e "$full" ] && return 0
  [ -L "$full" ] || return 1
  local tgt cur i=0
  tgt=$(readlink "$full") || return 1
  case "$tgt" in
    /*) cur="$2$tgt" ;;
    *) cur="$(dirname "$full")/$tgt" ;;
  esac
  while [ -L "$cur" ] && [ "$i" -lt 8 ]; do
    tgt=$(readlink "$cur") || return 1
    case "$tgt" in
      /*) cur="$2$tgt" ;;
      *) cur="$(dirname "$cur")/$tgt" ;;
    esac
    i=$((i + 1))
  done
  [ -e "$cur" ]
}

# 便捷版：rootfs_has <distro> <容器内绝对路径>
rootfs_has() { # DISTRO /bin/sh
  local d="$1" p="${2#/}"
  local rf
  rf=$(rootfs_dir_for "$d")
  rootfs_path_exists "$rf/$p" "$rf"
}

rootfs_ready() { # [distro]
  local d="${1:-$(config_distro)}"
  rootfs_has "$d" /bin/sh
}

# 断言 rootfs 内存在某路径（正确处理绝对符号链接，见 rootfs_path_exists）
# 用法：assert_rootfs_has [/容器内路径] [标签]   或   assert_rootfs_has DISTRO /路径 [标签]
assert_rootfs_has() {
  local d p label
  case "${1:-}" in
    alpine | ubuntu) d="$1"; p="$2"; label="${3:-rootfs 内存在}" ;;
    *) d=$(config_distro); p="$1"; label="${2:-rootfs 内存在}" ;;
  esac
  local rf full
  rf=$(rootfs_dir_for "$d")
  full="$rf/${p#/}"
  if rootfs_has "$d" "$p"; then
    _ok "$label: $d:$p"
  else
    local hint=""
    [ -L "$full" ] && hint="（是符号链接 → $(readlink "$full")，目标在 rootfs 内也不存在）"
    _fail "$label 期望存在：$d:$p（实际绝对路径 $full 不存在）$hint"
  fi
}

# 在隔离骨架中复刻 .capbox（只有脚本，没有 os/rootfs），用于验证「无 rootfs」分支
# 用法：sbx=$(make_sandbox_skeleton T02)  然后 RUN_CWD=$sbx 执行 $sbx/.capbox/bin/capbox
make_sandbox_skeleton() {
  local name="$1"
  local base="$QA_TMP/sandbox/$name"
  local sbx="$base/ws"
  rm -rf "$base"
  mkdir -p "$sbx/.capbox/bin" "$sbx/.capbox/lib" "$sbx/.capbox/os" \
    "$sbx/.capbox/cache" "$sbx/.capbox/run" "$sbx/.capbox/logs" "$sbx/.capbox/state"
  if [ -d "$CAPBOX_DIR/bin" ]; then
    cp -a "$CAPBOX_DIR/bin/." "$sbx/.capbox/bin/" 2>/dev/null
  fi
  if [ -d "$CAPBOX_DIR/lib" ]; then
    cp -a "$CAPBOX_DIR/lib/." "$sbx/.capbox/lib/" 2>/dev/null
  fi
  if [ -f "$CAPBOX_DIR/config.env" ]; then
    cp -a "$CAPBOX_DIR/config.env" "$sbx/.capbox/config.env" 2>/dev/null
  fi
  printf '%s' "$sbx"
}

# ---------------------------------------------------------------------------
# daemon 相关（契约 §5）
# ---------------------------------------------------------------------------
daemon_json_file() { printf '%s/run/daemon/daemon.json' "$CAPBOX_DIR"; }

# daemon 是否真的在跑：优先问 CLI（status --json），失败再退回 daemon.json + kill -0
daemon_is_up() {
  local tmpf="$QA_TMP/.daemon-probe.json"
  mkdir -p "$QA_TMP"
  if "$CAPBOX_BIN" status --json >"$tmpf" 2>/dev/null; then
    case "$(json_get "$tmpf" daemon.running 2>/dev/null)" in
      true | 1) return 0 ;;
      *) return 1 ;;
    esac
  fi
  local f pid
  f=$(daemon_json_file)
  [ -f "$f" ] || return 1
  pid=$(json_get "$f" pid 2>/dev/null) || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

print_manual_daemon_instructions() {
  cat <<'EOF'
      ┌─ daemon 用例需要手动准备（DSH 的 bash 工具会 die-with-parent 杀掉后台进程，
      │  测试脚本自己起不了 daemon）：
      │
      │   1) 在 DSH 里用 run_in_background 运行：
      │        .capbox/bin/capbox up
      │   2) 等它启动完成后，设置环境变量重跑：
      │        CAPBOX_TEST_DAEMON=1 .capbox/test/run.sh T16 T15
      │      （顺序建议 T16 在前：T15 末尾会执行 capbox down 停掉 daemon）
      │   3) 跑完后停掉后台 job 即可。
      └─
EOF
}

# 返回 0 表示可以执行 daemon 用例；否则已 skip_case 并返回 1
require_daemon() {
  if [ "${CAPBOX_TEST_DAEMON:-0}" != "1" ]; then
    skip_case "daemon 用例默认跳过（未设置 CAPBOX_TEST_DAEMON=1）"
    print_manual_daemon_instructions
    return 1
  fi
  if ! daemon_is_up; then
    skip_case "已设置 CAPBOX_TEST_DAEMON=1，但检测不到运行中的 daemon（status --json / daemon.json 均未显示 running）"
    print_manual_daemon_instructions
    return 1
  fi
  return 0
}

# 前置条件：rootfs 已 init（否则用例无法有意义地执行）
require_rootfs() {
  local d
  d=$(config_distro)
  if rootfs_ready "$d"; then
    return 0
  fi
  _fail "前置条件未满足：rootfs 不存在（$(rootfs_dir_for "$d")/bin/sh），请先跑 T03 / capbox init --distro $d"
  return 1
}

# 需要 alpine 的用例（apk 相关）在 ubuntu 配置下无意义
require_alpine() {
  local d
  d=$(config_distro)
  if [ "$d" = "alpine" ]; then
    return 0
  fi
  skip_case "当前 distro=$d（非 alpine），apk 相关断言不适用"
  return 1
}
