#!/usr/bin/env bash
# T06 — capbox exec -- id -u：输出 0
set -u
CASE_TITLE="exec -- id -u：输出 0（容器内 root）"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

require_rootfs || { case_finish; exit 0; }

run_cmd "$CAPBOX_BIN" exec -- id -u
assert_rc 0 "exec 退出码"
assert_stdout_eq "0" "id -u 输出（契约：容器内 uid=0）"

# 契约 §3.3：exec 的 stdout 必须只含容器内命令输出（可被管道消费）
# 这里用一行哨兵输出验证 stdout 无额外噪音
run_cmd "$CAPBOX_BIN" exec -- echo "CAPBOX_STDOUT_SENTINEL"
assert_stdout_eq "CAPBOX_STDOUT_SENTINEL" "exec stdout 纯净（不含 CLI 自身信息）"

# --- --cwd 行为（契约 §3.1 exec 的 --cwd DIR）---
# 回归保护：主模块 曾有 bug —— _resolve_guest_cwd 在 $( ) 子 shell 里调 die 2，
# 子 shell 的 exit 不终止父进程，导致无效 --cwd 被静默降级到 /workspace 且 rc=0：
#   $ capbox exec --cwd /nonexistent -- pwd   →  打印 /workspace，RC=0（用户以为在指定目录跑了）
# 正确行为：报错、不执行命令、返回用法错误码 2（契约 §3.2）。
run_cmd "$CAPBOX_BIN" exec --cwd /workspace -- pwd
assert_rc 0 "有效 --cwd=/workspace 退出码"
assert_stdout_eq "/workspace" "有效 --cwd 生效"

run_cmd "$CAPBOX_BIN" exec --cwd /nonexistent -- pwd
assert_rc 2 "无效 --cwd 返回用法错误码 2"
assert_stdout_eq "" "无效 --cwd 不执行命令（stdout 为空，不得降级到 /workspace）"
assert_out_matches_i '不存在|not exist|no such' "无效 --cwd 有清晰报错"

case_finish
exit 0
