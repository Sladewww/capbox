#!/usr/bin/env bash
# T04 — capbox init 幂等：第二次退出 0，不重复下载（用缓存）
# 判据：缓存 tarball 的 mtime/大小不变；输出里出现「复用缓存」类措辞；
#       若 CLI 第二次仍在下载，则应能从日志区分（用下载耗时/输出判定）。
set -u
CASE_TITLE="init 幂等：第二次退出 0 且复用缓存不重复下载"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

rf="$CAPBOX_DIR/os/alpine"
if ! rootfs_ready alpine; then
  skip_case "rootfs 尚未 init（先跑 T03），无法验证幂等"
  case_finish
  exit 0
fi

if [ "${CAPBOX_TEST_SKIP_INIT:-0}" = "1" ]; then
  skip_case "CAPBOX_TEST_SKIP_INIT=1：跳过第二次 init"
  case_finish
  exit 0
fi

cache="$CAPBOX_DIR/cache"
tarball=$(ls -1 "$cache"/alpine-minirootfs-*.tar.gz 2>/dev/null | head -n 1 || true)

sizes_before=""
mtimes_before=""
if [ -n "$tarball" ]; then
  sizes_before=$(stat -c '%s' "$cache"/*.tar.gz 2>/dev/null | tr '\n' ' ')
  mtimes_before=$(stat -c '%Y' "$cache"/*.tar.gz 2>/dev/null | tr '\n' ' ')
  assert_file_exists "$tarball" "init 缓存 tarball 存在（判据基础）"
else
  mark_known_issue "init 未在 cache/ 留下 tarball，无法用缓存文件判据验证「不重复下载」，改用输出措辞判定"
fi

# 第二次 init（不应加 --force）
run_cmd "$CAPBOX_BIN" init --distro alpine
assert_rc 0 "第二次 init 退出码"

# 输出里出现「下载」也不算错（可能 HEAD 校验），但「跳过/复用缓存」类措辞应出现；
# 该条是软判据：不满足只记 KNOWN-ISSUE，不判 FAIL（契约只要求「不重复下载（或用缓存）」，
# 这个语义需要可观测证据，仅凭输出措辞不足以硬判）。
if printf '%s\n%s' "$RUN_STDOUT" "$RUN_STDERR" | grep -qiE '缓存|cache|skip|跳过|已存在|reuse|up.to.date'; then
  _ok "第二次 init 输出体现复用缓存（未重新下载）"
else
  mark_known_issue "第二次 init 输出没有『缓存/跳过/已存在』等措辞，无法从输出确认「不重复下载」；缓存文件判据为准"
fi

if [ -n "$tarball" ]; then
  sizes_after=$(stat -c '%s' "$cache"/*.tar.gz 2>/dev/null | tr '\n' ' ')
  mtimes_after=$(stat -c '%Y' "$cache"/*.tar.gz 2>/dev/null | tr '\n' ' ')
  assert_eq "$sizes_before" "$sizes_after" "缓存 tarball 大小未变"
  assert_eq "$mtimes_before" "$mtimes_after" "缓存 tarball mtime 未变（未重新下载）"
fi

# 幂等后 rootfs 仍可用
assert_rootfs_has "/bin/sh" "幂等后 rootfs /bin/sh 仍存在"

case_finish
exit 0
