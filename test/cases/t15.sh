#!/usr/bin/env bash
# T15 — daemon 全链路：status 显示 running → exec --daemon -- echo hi → down
# 契约 §5 + 契约 §0 坑 1：常驻容器只能由 DSH background job 承载，
# 测试脚本自己起不了 daemon，因此默认 SKIP 并给出手动指令。
#
# ⚠ 本用例末尾会执行 `capbox down`（契约 §7 要求），会停掉 daemon。
#    所以若与 T16 一起跑，T16 必须在它之前（run.sh 已把 T15 排到 daemon 用例末尾）。
set -u
CASE_TITLE="daemon 全链路：status running → exec --daemon → down"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

# 先判定开关门控，再判定前置条件：否则在「没 daemon」的机器上会先报 rootfs 缺失 FAIL，
# 而契约要求这种情况应该是 SKIP（跳过，不算失败）。
if ! require_daemon; then case_finish; exit 0; fi
require_rootfs || { case_finish; exit 0; }

# 1) status 显示 running
run_cmd "$CAPBOX_BIN" status --json
assert_rc 0 "status 退出码"
assert_json_value "daemon.running" "true" "status 显示 daemon running"
pid=$(printf '%s' "$RUN_STDOUT" | tr -d '\n' | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  _ok "daemon.json 中的 pid=$pid 存活（契约 §5 活性判据）"
else
  _fail "daemon.json 的 pid='$pid' 不存活（stale json）"
fi

# 契约 §5：daemon.json 是活性判据，字段应齐全
dj="$CAPBOX_DIR/run/daemon/daemon.json"
assert_file_exists "$dj" "run/daemon/daemon.json 存在"
if [ -f "$dj" ]; then
  for k in pid started_at distro rootfs v; do
    if json_get "$dj" "$k" >/dev/null 2>&1; then
      _ok "daemon.json 含字段 '$k'"
    else
      _fail "daemon.json 缺字段 '$k'（契约 §5 规定结构）"
    fi
  done
fi

# 2) exec --daemon
run_cmd "$CAPBOX_BIN" exec --daemon -- echo hi
assert_rc 0 "exec --daemon 退出码"
assert_stdout_eq "hi" "exec --daemon 输出"

run_cmd "$CAPBOX_BIN" exec --daemon -- sh -c 'echo d-1 > /root/daemon-probe.txt && cat /root/daemon-probe.txt'
assert_rc 0 "daemon 内写文件"
assert_stdout_eq "d-1" "daemon 内写读一致"

# 同一容器实例验证（daemon 模式状态应跨请求保留，且 /tmp 也保留——这是与一次性 exec 的关键差异）
run_cmd "$CAPBOX_BIN" exec -- echo "d-2" >/dev/null 2>&1; # 占位，避免空 RUN_*
run_cmd "$CAPBOX_BIN" exec --daemon -- sh -c 'echo keep > /tmp/daemon-tmp.txt; echo ok'
assert_stdout_eq "ok" "daemon 内写 /tmp"
run_cmd "$CAPBOX_BIN" exec --daemon -- cat /tmp/daemon-tmp.txt
assert_stdout_eq "keep" "daemon 的 /tmp 跨请求保留（同一容器实例）"

# 契约 §5：logs 有内容
run_cmd "$CAPBOX_BIN" logs -n 20
assert_rc 0 "logs -n 20 退出码"
if [ -n "$(printf '%s' "$RUN_STDOUT" | tr -d '[:space:]')" ]; then
  _ok "logs 有内容"
else
  _fail "logs 无内容（契约 §3.1：logs 读 daemon.log）"
fi

# 3) down
run_cmd "$CAPBOX_BIN" down
assert_rc 0 "down 退出码"

# down 后：daemon.json 应被清理，status 显示 stopped
sleep 1
if [ -f "$dj" ]; then
  _fail "down 后 daemon.json 仍存在（契约 §5：清理 daemon.json）"
else
  _ok "down 后 daemon.json 已清理"
fi

run_cmd "$CAPBOX_BIN" status --json
assert_rc 0 "down 后 status 退出码"
assert_json_value "daemon.running" "false" "down 后 status 显示 stopped"

# 契约 §3.2：daemon 未运行时需要 daemon 的命令返回 3
run_cmd "$CAPBOX_BIN" exec --daemon -- echo hi
assert_rc 3 "daemon 未运行时 exec --daemon 返回 3（契约 §3.2）"

printf '  %s提示：T15 已执行 down，daemon 已停止；如需再跑 daemon 用例请重新在后台 job 起 capbox up%s\n' \
  "$C_DIM" "$C_RST"

case_finish
exit 0
