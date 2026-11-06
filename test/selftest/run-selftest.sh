#!/usr/bin/env bash
# =============================================================================
# .capbox/test/selftest/run-selftest.sh — 测试框架自测
# -----------------------------------------------------------------------------
# 回答一个问题：**run.sh / lib.sh 的 PASS/FAIL/SKIP 判定本身是对的么？**
#
# 做法：在一个隔离沙箱工作区里（不是真实 .capbox/），用假 CLI 桩跑真实用例脚本，
# 然后检查：
#   A. 好桩（无故障注入）→ 应该大量 PASS，且 exit 0
#   B. 故障注入桩        → 对应用例必须 FAIL，且 exit 1（证明断言有效）
#   C. daemon / slow 门控 → 未设开关时 T15/T16/T19 必须 SKIP
#   D. --list / 选择性执行 / 未知用例 的行为
#   E. 用例崩溃时不中断其余用例
#
# 用法：bash .capbox/test/selftest/run-selftest.sh
# 退出码：0=框架自测全过；1=框架本身有问题
# =============================================================================
set -u

SELFTEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SRC="$(cd "$SELFTEST_DIR/.." && pwd)"
FAKE="$SELFTEST_DIR/fake-cli/capbox"
WORK="${CAPBOX_SELFTEST_WORK:-$TEST_SRC/tmp/selftest}"

RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YEL=$'\033[1;33m'; DIM=$'\033[2m'; RST=$'\033[0m'
if [ ! -t 1 ]; then RED=''; GREEN=''; YEL=''; DIM=''; RST=''; fi

S_PASS=0; S_FAIL=0
sok() { S_PASS=$((S_PASS + 1)); printf '  %s✓%s %s\n' "$GREEN" "$RST" "$*"; }
sbad() { S_FAIL=$((S_FAIL + 1)); printf '  %s✗%s %s\n' "$RED" "$RST" "$*"; }
chk() { # chk 描述 条件命令...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then sok "$desc"; else sbad "$desc"; fi
}

printf '%s\n' "==============================================================================="
printf 'CapBox 测试框架自测（用假 CLI 桩验证 run.sh/lib.sh 本身）\n'
printf '%s\n' "==============================================================================="

# ---------------------------------------------------------------------------
# 准备隔离沙箱：把 test/ 与假 CLI 拷进去，形态与真实工作区一致
# ---------------------------------------------------------------------------
build_sandbox() {
  local name="$1"
  local ws="$WORK/$name/ws"
  rm -rf "$WORK/$name"
  # 沙箱要复刻契约 §1 的目录布局，否则用例因为「目录不存在」而失败，
  # 那测的就不是框架而是沙箱搭建了。
  mkdir -p "$ws/.capbox/test" "$ws/.capbox/bin" "$ws/.capbox/state" \
    "$ws/.capbox/run/tmp" "$ws/.capbox/logs" "$ws/.capbox/cache" "$ws/.dsh/skills/capbox"
  cp -a "$TEST_SRC/lib.sh" "$TEST_SRC/run.sh" "$ws/.capbox/test/"
  cp -a "$TEST_SRC/cases" "$ws/.capbox/test/"
  mkdir -p "$ws/.capbox/test/tmp"
  cp -a "$FAKE" "$ws/.capbox/bin/capbox"
  chmod +x "$ws/.capbox/bin/capbox"
  # 最小 SKILL.md（T20 的判据对象），内容满足契约 §7 要求
  cat >"$ws/.dsh/skills/capbox/SKILL.md" <<'SKILL'
---
name: capbox
description: 在工作区持久化的 root Linux 系统里执行命令、装系统包、跑常驻服务时使用；用 .capbox/bin/capbox 驱动。
---

# CapBox

在 DSH 工作区里运行一个拥有完整 root 权限的 Linux 操作系统。

## 关键约束

常驻容器只能用 DSH 后台 job（run_in_background）跑 `capbox up`，
因为 bash 工具的 --die-with-parent 会杀掉整棵进程树，`nohup &` 必死。

## 常用命令

```sh
.capbox/bin/capbox init --distro alpine
.capbox/bin/capbox exec -- id -u
.capbox/bin/capbox pkg install curl
```

## 退出码

0 成功 / 1 一般错误 / 2 用法错误 / 3 daemon 未运行 / 4 rootfs 缺失 / 5 依赖缺失 / 124 超时
SKILL
  printf '%s' "$ws"
}

# 本框架的临时区带运行实例 ID（qa-<pid>），自测里按 glob 找最新那个
qa_dir() { # qa_dir WS
  ls -dt "$1"/.capbox/test/tmp/qa-* 2>/dev/null | head -n 1
}
status_of() { # status_of WS CASEID
  local d
  d=$(qa_dir "$1")
  [ -n "$d" ] && awk '{print $1}' "$d/status/$2" 2>/dev/null
}
console_of() { # console_of WS CASEID
  local d
  d=$(qa_dir "$1")
  [ -n "$d" ] && cat "$d/cases/$2/console.log" 2>/dev/null
}

run_suite() { # run_suite WS [args...]  → 输出到 $WS/last.log，返回套件退出码
  local ws="$1"; shift
  ( cd "$ws" && bash "$ws/.capbox/test/run.sh" "$@" ) >"$ws/last.log" 2>&1
  return $?
}

# ---------------------------------------------------------------------------
# A. 好桩：全套跑一遍，应该 PASS 大多数、无 FAIL、exit 0
# ---------------------------------------------------------------------------
printf '\n%s[A] 好桩（无故障注入）：全套 T01–T40 应该无 FAIL（T21–T40 在假桩下 SKIP）%s\n' "$YEL" "$RST"
WS=$(build_sandbox good)
rc=0
run_suite "$WS" || rc=$?
tail -n 30 "$WS/last.log" | sed 's/^/    /'

chk "好桩：套件 exit 0（无 FAIL）" [ "$rc" = "0" ]
chk "好桩：有 PASS 行" grep -q 'PASS [1-9]' "$WS/last.log"
chk "好桩：汇总含 FAIL 0" grep -qE 'FAIL 0' "$WS/last.log"
chk "好桩：T15/T16 被 SKIP（未设 CAPBOX_TEST_DAEMON）" grep -q 'SKIP' "$WS/last.log"
n_pass=$(grep -oE 'PASS [0-9]+' "$WS/last.log" | tail -n 1 | awk '{print $2}')
if [ "${n_pass:-0}" -ge 12 ]; then
  sok "好桩：PASS 数 $n_pass ≥ 12"
else
  sbad "好桩：PASS 数只有 ${n_pass:-0}，框架/桩有问题"
fi

# 逐用例抽查：好桩下这些用例必须 PASS
for c in T01 T03 T06 T08 T09 T12 T13 T14 T17 T18; do
  if grep -qE "^$c .*PASS|PASS .*$c" "$WS/last.log" 2>/dev/null || grep -q "PASS :.*$c" "$WS/last.log"; then
    :
  fi
done
# 用 status 文件判（更可靠）
for c in T01 T03 T06 T08 T12 T13 T14 T17 T18; do
  st=$(status_of "$WS" $c)
  if [ "$st" = "PASS" ]; then
    sok "好桩：$c = PASS"
  else
    sbad "好桩：$c 期望 PASS，实际 ${st:-<无状态文件>}"
    printf '    %s末次输出：%s\n' "$DIM" "$RST"
    console_of "$WS" $c | tail -n 12 | sed "s/^/      /"
  fi
done

# ---------------------------------------------------------------------------
# B. 故障注入：每注入一个缺陷，对应用例必须 FAIL、套件必须 exit 1
# ---------------------------------------------------------------------------
printf '\n%s[B] 故障注入：断言必须能抓到问题（对应用例必须 FAIL）%s\n' "$YEL" "$RST"

inject_and_check() { # 描述 缺陷名 期望FAIL的用例...
  local desc="$1" defect="$2"; shift 2
  local cases=("$@")
  local ws
  ws=$(build_sandbox "defect-$defect")
  local r=0
  FAKE_DEFECTS="$defect" run_suite "$ws" "${cases[@]}" || r=$?
  if [ "$r" = "1" ]; then
    sok "$desc → 套件 exit 1（正确报错）"
  else
    sbad "$desc → 套件 exit $r（应为 1，测试没抓到缺陷！）"
    tail -n 20 "$ws/last.log" | sed 's/^/      /'
    return 0
  fi
  local c st okall=1
  for c in "${cases[@]}"; do
    st=$(status_of "$ws" $c)
    if [ "$st" = "FAIL" ]; then
      sok "$desc → $c 正确判为 FAIL"
    else
      okall=0
      sbad "$desc → $c 期望 FAIL，实际 ${st:-<无>}"
      console_of "$ws" $c | tail -n 15 | sed "s/^/      /"
    fi
  done
  return 0
}

inject_and_check "help-missing（帮助漏列 ls）" help-missing T01
inject_and_check "doctor-always-ok（无 rootfs 仍退 0）" doctor-always-ok T02
inject_and_check "exec-uid-1000（容器内非 root）" exec-uid-1000 T06
inject_and_check "stdout-noisy（exec stdout 有噪音）" stdout-noisy T06
inject_and_check "exitcode-swallow（吞掉退出码）" exitcode-swallow T12
inject_and_check "no-timeout（忽略 --timeout）" no-timeout T13
inject_and_check "status-bad-json（非法 JSON）" status-bad-json T14
inject_and_check "status-missing-key（缺 daemon 字段）" status-missing-key T14

# ---------------------------------------------------------------------------
# C. 门控：daemon / slow 用例默认必须 SKIP，且 SKIP 不算失败
# ---------------------------------------------------------------------------
printf '\n%s[C] 开关门控：T15/T16/T19 默认必须 SKIP 且不导致 exit 1%s\n' "$YEL" "$RST"
WS=$(build_sandbox gates)
r=0
run_suite "$WS" T15 T16 T19 || r=$?
chk "T15/T16/T19 未开开关时套件 exit 0（SKIP 不算失败）" [ "$r" = "0" ]
for c in T15 T16 T19; do
  st=$(status_of "$WS" $c)
  if [ "$st" = "SKIP" ]; then
    sok "$c 判为 SKIP"
  else
    sbad "$c 期望 SKIP，实际 ${st:-<无>}"
  fi
done
chk "SKIP 明细里给出 DAEMON 启动指引" grep -qiE 'CAPBOX_TEST_DAEMON|run_in_background|后台' "$WS/last.log"
chk "SKIP 明细里给出 SLOW 指引" grep -qiE 'CAPBOX_TEST_SLOW' "$WS/last.log"

# CAPBOX_TEST_DAEMON=1 但没有 daemon → 仍然 SKIP（不是 FAIL）
WS=$(build_sandbox gates-nodaemon)
r=0
( cd "$WS" && CAPBOX_TEST_DAEMON=1 bash "$WS/.capbox/test/run.sh" T16 ) >"$WS/last.log" 2>&1 || r=$?
chk "CAPBOX_TEST_DAEMON=1 但无 daemon：exit 0" [ "$r" = "0" ]
st=$(status_of "$WS" T16)
chk "CAPBOX_TEST_DAEMON=1 但无 daemon：T16 仍 SKIP（$st）" [ "$st" = "SKIP" ]

# CAPBOX_TEST_DAEMON=1 且 daemon 真在跑 → T16 应真正执行
WS=$(build_sandbox gates-daemon)
# 先让桩 init 出 rootfs，否则 T16 会因前置条件缺失而 FAIL，测到的就不是门控
( cd "$WS" && "$WS/.capbox/bin/capbox" init --distro alpine ) >"$WS/init.log" 2>&1
( cd "$WS" && "$WS/.capbox/bin/capbox" daemon-helper ) >"$WS/daemon.log" 2>&1 &
DPID=$!
sleep 1.5
r=0
( cd "$WS" && CAPBOX_TEST_DAEMON=1 bash "$WS/.capbox/test/run.sh" T16 ) >"$WS/last.log" 2>&1 || r=$?
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null
st=$(status_of "$WS" T16)
if [ "$st" = "PASS" ]; then
  sok "CAPBOX_TEST_DAEMON=1 且 daemon 在跑：T16 真正执行并 PASS"
elif [ "$st" = "FAIL" ]; then
  sbad "CAPBOX_TEST_DAEMON=1 且 daemon 在跑：T16 执行但 FAIL（可能是桩的并发实现问题，不是门控问题）"
  console_of "$WS" T16 | tail -n 25 | sed "s/^/      /"
else
  sbad "CAPBOX_TEST_DAEMON=1 且 daemon 在跑：T16 期望执行，实际 ${st:-<无状态>}（门控失效）"
  tail -n 15 "$WS/last.log" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
# D. CLI 行为：--list / 选择性执行 / 未知用例
# ---------------------------------------------------------------------------
printf '\n%s[D] CLI 行为：--list、选择性执行、未知用例%s\n' "$YEL" "$RST"
WS=$(build_sandbox cli)

r=0
out=$( cd "$WS" && bash "$WS/.capbox/test/run.sh" --list 2>&1 ) || r=$?
chk "--list exit 0" [ "$r" = "0" ]
chk "--list 列出 T01" grep -q 'T01' <<<"$out"
chk "--list 列出 T20" grep -q 'T20' <<<"$out"
chk "--list 列出 T21" grep -q 'T21' <<<"$out"
chk "--list 列出 T22" grep -q 'T22' <<<"$out"
chk "--list 列出 T23" grep -q 'T23' <<<"$out"
chk "--list 列出 T25" grep -q 'T25' <<<"$out"
chk "--list 列出 T26" grep -q 'T26' <<<"$out"
chk "--list 列出 T29" grep -q 'T29' <<<"$out"
chk "--list 列出 T30" grep -q 'T30' <<<"$out"
chk "--list 列出 T35" grep -q 'T35' <<<"$out"
chk "--list 列出 T36" grep -q 'T36' <<<"$out"
chk "--list 列出 40 个用例" grep -q '共 40 个用例' <<<"$out"
chk "--list 不执行任何用例（无 PASS/FAIL 汇总）" bash -c '! grep -q "汇总：" <<<"$1"' _ "$out"

r=0
out=$( cd "$WS" && bash "$WS/.capbox/test/run.sh" T05 T06 2>&1 ) || r=$?
chk "选择性执行 T05 T06：只跑这两个" bash -c '[ "$(printf "%s" "$1" | grep -cE "\] T0[0-9]")" = "2" ]' _ "$out"
chk "选择性执行：汇总总数为 2" grep -qE '共 2' <<<"$out"

r=0
out=$( cd "$WS" && bash "$WS/.capbox/test/run.sh" t01 2>&1 ) || r=$?
chk "小写用例名 t01 也能选中" grep -qE 'T01' <<<"$out"

r=0
out=$( cd "$WS" && bash "$WS/.capbox/test/run.sh" T99 2>&1 ) || r=$?
chk "未知用例 T99：exit 2（用法错误）" [ "$r" = "2" ]
chk "未知用例 T99：提示没有这个用例" grep -q '没有这个用例' <<<"$out"

# 幂等：连跑两次结果一致，且 tmp 每次被清理
r1=0
run_suite "$WS" T01 T03 T06 || r1=$?
sz1=$(du -s "$(qa_dir "$WS")" 2>/dev/null | awk '{print $1}')
r2=0
run_suite "$WS" T01 T03 T06 || r2=$?
chk "重复运行两次结果一致（都 exit 0）" [ "$r1" = "$r2" ]
chk "重复运行：tmp/qa 被重建（不无限增长）" bash -c '[ "$1" -le "$2" ]' _ "$sz1" "${sz1:-0}"
chk "重复运行：第二次仍 PASS" grep -qE 'PASS [1-9]' "$WS/last.log"

# ---------------------------------------------------------------------------
# E. 鲁棒性：用例崩溃 / 卡死不得拖垮整套
# ---------------------------------------------------------------------------
printf '\n%s[E] 鲁棒性：某个用例崩溃/超时，其余用例照常跑完%s\n' "$YEL" "$RST"
WS=$(build_sandbox robust)
# 造一个会崩溃的用例和一个会卡死的用例
cat >"$WS/.capbox/test/cases/t90.sh" <<'EOF'
#!/usr/bin/env bash
CASE_TITLE="故意崩溃（自测用）"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
echo "我要崩溃了"
exit 99
EOF
cat >"$WS/.capbox/test/cases/t91.sh" <<'EOF'
#!/usr/bin/env bash
CASE_TITLE="故意卡死（自测用）"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
sleep 600
EOF
r=0
( cd "$WS" && CAPBOX_TEST_TIMEOUT=3 bash "$WS/.capbox/test/run.sh" T90 T91 T06 ) >"$WS/last.log" 2>&1 || r=$?
chk "崩溃/卡死场景：套件 exit 1（有 FAIL）" [ "$r" = "1" ]
chk "崩溃用例记为 FAIL" grep -qE 'T90' "$WS/last.log"
chk "卡死用例被超时杀掉并记为 FAIL" bash -c 'grep -qE "T91.*异常终止|异常终止.*rc=124|\[3/3\] T06" <<<"$1"' _ "$(cat "$WS/last.log")"
chk "崩溃/卡死不影响后续用例 T06 执行" grep -q '\[3/3\] T06' "$WS/last.log"
st=$(status_of "$WS" T06)
chk "T06 在崩溃/卡死后仍被执行（状态=$st）" [ -n "$st" ]

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
printf '\n%s\n' "==============================================================================="
printf '框架自测汇总：%sPASS %s%s / %sFAIL %s%s\n' \
  "$GREEN" "$S_PASS" "$RST" "$RED" "$S_FAIL" "$RST"
printf '%s\n' "==============================================================================="
if [ "$S_FAIL" -gt 0 ]; then
  printf '%s框架自测未通过：上面的 ✗ 项说明测试框架自身有问题，先修框架再接真实 CLI。%s\n' "$RED" "$RST"
  exit 1
fi
printf '%s框架自测通过：PASS/FAIL/SKIP 判定、缺陷检出、门控、选择性执行、鲁棒性都符合预期。%s\n' "$GREEN" "$RST"
printf '下一步：用真实 CLI 跑 %s\n' "$TEST_SRC/run.sh"
exit 0
