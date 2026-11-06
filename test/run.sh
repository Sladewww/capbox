#!/usr/bin/env bash
# =============================================================================
# .capbox/test/run.sh — CapBox 验收测试主入口（契约 §7，T01–T40）
# -----------------------------------------------------------------------------
# 用法：
#   .capbox/test/run.sh                 # 跑全部 T01–T40
#   .capbox/test/run.sh --list          # 只列出用例
#   .capbox/test/run.sh T05 T06         # 只跑指定用例（大小写均可）
#   .capbox/test/run.sh --list -v       # 带说明的清单
#
# 环境变量：
#   CAPBOX_TEST_DAEMON=1   允许执行 T15/T16（需先在 DSH 后台 job 里 `capbox up`）
#   CAPBOX_TEST_SLOW=1     允许执行 T19（ubuntu，慢，下载 30MB）
#   真实服务慢测见 test/slow/run-slow.sh（默认不进 CI）
#   CAPBOX_TEST_BIN=PATH   指定被测 CLI（默认为 <ws>/.capbox/bin/capbox；自测时指向桩）
#   CAPBOX_TEST_KEEP_TMP=1 保留 tmp/qa 便于排查
#   CAPBOX_TEST_TIMEOUT=N  单个用例超时秒数（默认 1800）
#
# 退出码：0=无 FAIL；1=有 FAIL（SKIP 不计失败）；2=用法错误
# =============================================================================
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 运行实例 ID：用例是独立子进程，必须共享同一个临时区，
# 所以在这里定好并 export，子进程 source lib.sh 时会继承（见 lib.sh 中 QA_TMP 注释）。
export CAPBOX_TEST_RUN_ID="$$"

# shellcheck source=/dev/null
. "$TEST_DIR/lib.sh"

CASE_DIR="$TEST_DIR/cases"
QS="$QA_TMP/status"
ALL_CASE_FILES=()

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# 收集用例
# ---------------------------------------------------------------------------
collect_cases() {
  local f
  ALL_CASE_FILES=()
  for f in "$CASE_DIR"/t*.sh; do
    [ -f "$f" ] || continue
    ALL_CASE_FILES+=("$f")
  done
}

case_id_of() { # file → T01
  local b
  b="$(basename "$1" .sh)"
  printf '%s' "$b" | tr '[:lower:]' '[:upper:]'
}

case_title_of() { # file → 标题（静态读取，不执行用例）
  local t
  t=$(sed -n 's/^CASE_TITLE=//p' "$1" | head -n 1)
  t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"
  printf '%s' "$t"
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
MODE=run
SELECTED=()
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --list) MODE=list ;;
    --run) MODE=run ;;
    -v | --verbose) VERBOSE=1 ;;
    -h | --help) usage; exit 0 ;;
    -*)
      printf '未知选项：%s\n\n' "$arg" >&2
      usage >&2
      exit 2
      ;;
    *) SELECTED+=("$arg"); MODE=run ;;
  esac
done

collect_cases

if [ "$MODE" = list ]; then
  printf 'CapBox 验收测试用例（契约 §7）\n\n'
  for f in "${ALL_CASE_FILES[@]}"; do
    printf '  %-5s %s\n' "$(case_id_of "$f")" "$(case_title_of "$f")"
  done
  printf '\n共 %s 个用例。默认全跑；可 run.sh T05 T06 选择性执行。\n' "${#ALL_CASE_FILES[@]}"
  printf '需要 daemon 的 T15/T16 默认 SKIP（设 CAPBOX_TEST_DAEMON=1 且 daemon 在跑才执行）；\n'
  printf 'T19（ubuntu）默认 SKIP（设 CAPBOX_TEST_SLOW=1 才执行）。\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# 选择要跑的用例
# ---------------------------------------------------------------------------
RUN_FILES=()
if [ "${#SELECTED[@]}" -eq 0 ]; then
  # 执行顺序微调：T15 末尾会 `capbox down` 停掉 daemon，若按数字序先跑 T15，
  # 后面的 T16（并发）就没 daemon 可测了。因此把 T15 放到最后。
  last=()
  for f in "${ALL_CASE_FILES[@]}"; do
    if [ "$(case_id_of "$f")" = "T15" ]; then
      last=("$f")
    else
      RUN_FILES+=("$f")
    fi
  done
  RUN_FILES+=("${last[@]}")
else
  for want in "${SELECTED[@]}"; do
    w_up=$(printf '%s' "$want" | tr '[:lower:]' '[:upper:]')
    found=""
    for f in "${ALL_CASE_FILES[@]}"; do
      if [ "$(case_id_of "$f")" = "$w_up" ]; then
        found="$f"; break
      fi
    done
    if [ -z "$found" ]; then
      printf '没有这个用例：%s（用 --list 查看）\n' "$want" >&2
      exit 2
    fi
    RUN_FILES+=("$found")
  done
fi

# ---------------------------------------------------------------------------
# 清理临时区（幂等：每次开始都重建）
# ---------------------------------------------------------------------------
if [ "${CAPBOX_TEST_KEEP_TMP:-0}" != "1" ]; then
  rm -rf "$QA_TMP"
  # 清理其它实例遗留的临时区（超过 1 小时的），避免 tmp/ 无限增长；
  # 不用 `rm -rf qa-*` 是因为可能正有另一个会话在跑。
  find "$CAPBOX_TEST_TMP" -maxdepth 1 -type d -name 'qa-*' -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true
  rm -rf "$CAPBOX_TEST_TMP/sandbox"
fi
mkdir -p "$QS" "$QA_TMP"
: >"$QA_TMP/known-issues.txt"

# ---------------------------------------------------------------------------
# 环境横幅
# ---------------------------------------------------------------------------
printf '%s\n' "==============================================================================="
printf 'CapBox 验收测试  |  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '工作区   : %s\n' "$CAPBOX_TEST_WS"
printf '被测 CLI : %s\n' "$CAPBOX_BIN"
printf '用例数   : %s' "${#RUN_FILES[@]}"
if [ ! -x "$CAPBOX_BIN" ]; then
  printf '  (警告：CLI 不存在或不可执行，绝大多数用例会 FAIL)'
fi
printf '\n'
printf '开关     : DAEMON=%s  SLOW=%s  TIMEOUT=%ss\n' \
  "${CAPBOX_TEST_DAEMON:-0}" "${CAPBOX_TEST_SLOW:-0}" "${CAPBOX_TEST_TIMEOUT:-1800}"
[ -n "${CAPBOX_PROXY:-}" ] && printf '注意     : CAPBOX_PROXY 已设置，T17 会临时覆盖测试值\n'
printf '%s\n' "==============================================================================="

# ---------------------------------------------------------------------------
# 逐个执行（每个用例一个独立 bash 进程，互不影响）
# ---------------------------------------------------------------------------
CASE_TIMEOUT="${CAPBOX_TEST_TIMEOUT:-1800}"
INDEX=0
for f in "${RUN_FILES[@]}"; do
  INDEX=$((INDEX + 1))
  cid="$(case_id_of "$f")"
  title="$(case_title_of "$f")"
  out="$QA_TMP/cases/$cid"
  rm -rf "$out"
  mkdir -p "$out"
  printf '\n\033[1;34m[%s/%s] %s  %s\033[0m\n' "$INDEX" "${#RUN_FILES[@]}" "$cid" "$title"
  start=$(date +%s)
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 10 "$CASE_TIMEOUT" bash "$f" "$cid" "$out" 2>&1 | tee "$out/console.log"
    rc=${PIPESTATUS[0]}
  else
    bash "$f" "$cid" "$out" 2>&1 | tee "$out/console.log"
    rc=${PIPESTATUS[0]}
  fi
  elapsed=$(( $(date +%s) - start ))

  if [ ! -f "$QS/$cid" ]; then
    # 用例没有正常收尾（被 kill / 崩溃 / 超时）——按 FAIL 记，不中断整体
    printf '  \033[1;31m✗ FAIL\033[0m 用例异常终止（rc=%s，耗时 %ss）\n' "$rc" "$elapsed"
    [ "$rc" = "124" ] && printf '      %s原因：超过单用例超时 %ss（可调 CAPBOX_TEST_TIMEOUT）%s\n' "$C_DIM" "$CASE_TIMEOUT" "$C_RST"
    printf 'FAIL 0 1 用例异常终止 rc=%s\n' "$rc" >"$QS/$cid"
    tail -n 15 "$out/console.log" 2>/dev/null | sed 's/^/      /'
  fi
done

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
pass=0; fail=0; skip=0
fail_ids=(); skip_ids=(); pass_ids=()
for f in "${RUN_FILES[@]}"; do
  cid="$(case_id_of "$f")"
  line=""
  [ -f "$QS/$cid" ] && line="$(cat "$QS/$cid")"
  st=$(printf '%s' "$line" | awk '{print $1}')
  reason=${line#* * * }
  case "$st" in
    PASS) pass=$((pass + 1)); pass_ids+=("$cid") ;;
    SKIP) skip=$((skip + 1)); skip_ids+=("$cid|$reason") ;;
    *)    fail=$((fail + 1)); fail_ids+=("$cid") ;;
  esac
done

printf '\n%s\n' "==============================================================================="
printf '汇总：\033[1;32mPASS %s\033[0m / \033[1;31mFAIL %s\033[0m / \033[1;33mSKIP %s\033[0m   （共 %s）\n' \
  "$pass" "$fail" "$skip" "${#RUN_FILES[@]}"
printf '%s\n' "==============================================================================="

if [ "$pass" -gt 0 ]; then
  printf 'PASS : %s\n' "${pass_ids[*]}"
fi

if [ "$fail" -gt 0 ]; then
  printf '\n\033[1;31mFAIL 明细：\033[0m\n'
  for entry in "${fail_ids[@]}"; do
    printf '  %s\n' "$entry"
    if [ -f "$QA_TMP/cases/$entry/failures.txt" ]; then
      head -n 8 "$QA_TMP/cases/$entry/failures.txt" | sed 's/^/      - /'
      n=$(wc -l <"$QA_TMP/cases/$entry/failures.txt")
      [ "$n" -gt 8 ] && printf '      - ...（共 %s 条失败，见 %s）\n' "$n" "$QA_TMP/cases/$entry/failures.txt"
    fi
  done
fi

if [ "$skip" -gt 0 ]; then
  printf '\n\033[1;33mSKIP 明细：\033[0m\n'
  for entry in "${skip_ids[@]}"; do
    printf '  %-4s %s\n' "${entry%%|*}" "${entry#*|}"
  done
  printf '  提示：daemon → CAPBOX_TEST_DAEMON=1（先在后台 job 起 capbox up）；ubuntu → CAPBOX_TEST_SLOW=1\n'
fi

if [ -s "$QA_TMP/known-issues.txt" ]; then
  printf '\n\033[1;33m契约符合性差异清单（KNOWN-ISSUE）：\033[0m\n'
  sed 's/^/  /' "$QA_TMP/known-issues.txt"
fi

printf '\n日志目录：%s\n' "$QA_TMP/cases"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
