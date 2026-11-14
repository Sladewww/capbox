#!/usr/bin/env bash
# T09 — 工作区互通：容器内写 $gpath/g.txt，宿主同路径可见
# 契约 §3.4：容器内 /workspace 即宿主工作区，读写双向即时可见。
set -u
CASE_TITLE="工作区互通：容器写 /workspace/... 宿主立即可见"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

require_rootfs || { case_finish; exit 0; }

# 容器内 /workspace 是宿主工作区的 bind 挂载点。
# 注意：.capbox 整体对 guest 只读（只有 run/ 与 cache/ 例外），state/、logs/、services/
# 都不可写——这是防改写 CLI 与配置的安全设计。所以交换文件放在工作区顶层的普通目录，
# 这也正是文档推荐的「业务数据放 /workspace」。
xdir="$CAPBOX_TEST_WS/.capbox-test-t09"
mkdir -p "$xdir"
gpath="/workspace/.capbox-test-t09"
host_file="$xdir/g.txt"
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
printf '%s\n' "$back" >"$xdir/h2g.txt"
run_cmd "$CAPBOX_BIN" exec -- cat $gpath/h2g.txt
assert_rc 0 "容器内读宿主写的文件"
assert_stdout_eq "$back" "容器读到的宿主内容"

# 清理本用例产生的文件
rm -f "$host_file" "$xdir/h2g.txt"; rmdir "$xdir" 2>/dev/null || true

case_finish
exit 0
