#!/usr/bin/env bash
# T09 — 工作区互通：容器内写 $gpath/g.txt，宿主同路径可见
# 契约 §3.4：容器内 /workspace 即宿主工作区，读写双向即时可见。
set -u
CASE_TITLE="工作区互通：容器写 /workspace/... 宿主立即可见"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

require_rootfs || { case_finish; exit 0; }

# 容器内 /workspace 是宿主工作区的 bind 挂载点；本用例在 <capbox>/state/ 下交换文件。
# 路径必须相对工作区推导，不写死 ".capbox" —— 仓库可能以任意目录名存在。
mkdir -p "$CAPBOX_DIR/state"
# 容器内路径 = /workspace + CAPBOX_DIR 相对工作区的部分（测试不走 common.sh，故在此推导）
_rel="${CAPBOX_DIR#"$CAPBOX_TEST_WS"}"
gpath="/workspace${_rel}/state"
host_file="$CAPBOX_DIR/state/g.txt"
rm -f "$host_file"
sentinel="capbox-ws-$RANDOM$RANDOM"

run_cmd "$CAPBOX_BIN" exec -- sh -c "echo '$sentinel' > $gpath/g.txt && echo ws-ok"
assert_rc 0 "容器内写 $gpath/g.txt"
assert_stdout_contains "ws-ok" "写入成功标记"

assert_file_exists "$host_file" "宿主侧同路径存在"
if [ -f "$host_file" ]; then
  assert_eq "$sentinel" "$(cat "$host_file")" "宿主侧读到内容一致"
fi

# 反向：宿主写 → 容器读
back="host-to-guest-$RANDOM"
printf '%s\n' "$back" >"$CAPBOX_DIR/state/h2g.txt"
run_cmd "$CAPBOX_BIN" exec -- cat $gpath/h2g.txt
assert_rc 0 "容器内读宿主写的文件"
assert_stdout_eq "$back" "容器读到的宿主内容"

# 清理本用例产生的文件
rm -f "$host_file" "$CAPBOX_DIR/state/h2g.txt"

case_finish
exit 0
