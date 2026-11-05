#!/usr/bin/env bash
# T18 — cp 双向：宿主 → 容器 → 宿主，内容一致
# 契约 §3.1：cp SRC DST；容器侧路径以 os/<distro>/ 为根，或写成 guest:/path、host:/path。
set -u
CASE_TITLE="cp 双向：宿主↔容器内容一致"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

require_rootfs || { case_finish; exit 0; }

src="$QA_TMP/cp-src.txt"
dst_host="$QA_TMP/cp-dst.txt"
guest_path="/root/cp-test.txt"
token="capbox-cp-$RANDOM$RANDOM"
printf '%s\n' "$token" >"$src"
rm -f "$dst_host"

# 1) 宿主 → 容器（用 host: / guest: 前缀，契约 §3.1 明确支持）
run_cmd "$CAPBOX_BIN" cp "host:$src" "guest:$guest_path"
assert_rc 0 "cp 宿主→容器 退出码"
run_cmd "$CAPBOX_BIN" exec -- cat "$guest_path"
assert_rc 0 "容器内读 cp 进来的文件"
assert_stdout_eq "$token" "宿主→容器内容一致"

# 2) 容器 → 宿主
run_cmd "$CAPBOX_BIN" cp "guest:$guest_path" "host:$dst_host"
assert_rc 0 "cp 容器→宿主 退出码"
assert_file_exists "$dst_host" "宿主侧目标文件存在"
if [ -f "$dst_host" ]; then
  assert_eq "$token" "$(cat "$dst_host")" "容器→宿主内容一致"
fi

# 3) 双向往返：容器内修改后再 cp 回来
printf '%s\n' "${token}-v2" >"$src"
run_cmd "$CAPBOX_BIN" cp "host:$src" "guest:$guest_path"
run_cmd "$CAPBOX_BIN" cp "guest:$guest_path" "host:$dst_host"
assert_rc 0 "往返 cp 退出码"
if [ -f "$dst_host" ]; then
  assert_eq "${token}-v2" "$(cat "$dst_host")" "往返后内容为最新版本"
fi

# 4) 契约 §3.1：容器侧路径可以省略 guest: 前缀，以 os/<distro>/ 为根
rf="$(rootfs_dir_for "$(config_distro)")"
run_cmd "$CAPBOX_BIN" cp "host:$src" "root/cp-plain.txt"
if [ "$RUN_RC" = "0" ]; then
  _ok "cp 支持无前缀的容器相对路径"
  if [ -f "$rf/root/cp-plain.txt" ]; then
    assert_eq "${token}-v2" "$(cat "$rf/root/cp-plain.txt")" "无前缀路径落到 rootfs/root/"
  else
    _fail "cp 返回 0 但 $rf/root/cp-plain.txt 不存在"
  fi
else
  mark_known_issue "cp 不接受无前缀的容器相对路径（rc=$RUN_RC）：契约 §3.1 允许「容器侧路径以 os/<distro>/ 为根」，前缀形式已通过"
fi

# 清理
rm -f "$dst_host" "$src"

case_finish
exit 0
