#!/usr/bin/env bash
# T08 — 持久化：exec 写 /root/p.txt，新的 exec 读回，内容一致
# 契约 §1/§3.4：rootfs 是工作区里的普通目录，容器内写入立刻落盘，跨调用保留。
set -u
CASE_TITLE="持久化：exec 写 /root/p.txt，新 exec 读回一致"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

require_rootfs || { case_finish; exit 0; }

sentinel="capbox-persist-$RANDOM$RANDOM"

# 第一次 exec：写
run_cmd "$CAPBOX_BIN" exec -- sh -c "echo '$sentinel' > /root/p.txt && cat /root/p.txt"
assert_rc 0 "写入 /root/p.txt 退出码"
assert_stdout_eq "$sentinel" "写入时回读"

# 落盘验证：宿主侧应能直接看到（rootfs 就是普通目录）
rf="$(rootfs_dir_for "$(config_distro)")"
if [ -f "$rf/root/p.txt" ]; then
  _ok "宿主侧可见 rootfs 内的 /root/p.txt（$rf/root/p.txt）"
  host_content=$(cat "$rf/root/p.txt" 2>/dev/null || true)
  assert_eq "$sentinel" "$host_content" "宿主侧读到的内容"
else
  _fail "宿主侧看不到 $rf/root/p.txt（容器写入未落盘到 rootfs）"
fi

# 第二次全新 exec：读回
run_cmd "$CAPBOX_BIN" exec -- cat /root/p.txt
assert_rc 0 "新 exec 读回退出码"
assert_stdout_eq "$sentinel" "新 exec 读回内容（跨调用持久化）"

# 契约 §1：一次性 exec 的 /tmp 是无状态 tmpfs，不应跨调用保留（这是「什么会丢」的对照）
run_cmd "$CAPBOX_BIN" exec -- sh -c 'echo tmp-should-vanish > /tmp/oneshot-probe; echo ok'
assert_stdout_eq "ok" "一次性 exec 写 /tmp"
run_cmd "$CAPBOX_BIN" exec -- sh -c 'test -e /tmp/oneshot-probe && echo LEAKED || echo clean'
assert_stdout_eq "clean" "一次性 exec 的 /tmp 不跨调用残留（契约 §3.4 --tmpfs /tmp）"

case_finish
exit 0
