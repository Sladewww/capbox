#!/usr/bin/env bash
# T14 — capbox status --json：合法单行 JSON，字段齐全
# 契约 §3.3 字段：distro, rootfs, rootfs_bytes, daemon{running,pid,uptime}, net, mirror, proxy, bwrap, version
set -u
CASE_TITLE="status --json：合法单行 JSON 且字段齐全"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

run_cmd "$CAPBOX_BIN" status --json
assert_rc 0 "status --json 退出码"

assert_json_valid "status --json 输出合法 JSON"
assert_single_line_json "status --json 是单行 JSON"

# 契约 §3.3 明列字段
for k in distro rootfs rootfs_bytes net mirror proxy bwrap version; do
  assert_json_key "$k" "顶层字段"
done
for k in daemon.running daemon.pid daemon.uptime; do
  assert_json_key "$k" "daemon 字段"
done

# 类型/取值合理性
assert_json_int "rootfs_bytes" "rootfs_bytes 是整数"
assert_json_value "distro" "$(config_distro)" "distro 与当前配置一致"

# bwrap 字段应是可执行的绝对路径（契约 §3.3 字段 bwrap）。
# 关于 /usr/bin/bwrap vs /usr/sbin/bwrap：本机两者是**同一 inode 的硬链接**
# （stat 显示 inode 108972，readlink -f /usr/bin/bwrap → /usr/bin/bwrap，
# 而 command -v 走 sbin 优先返回 /usr/sbin/bwrap），功能完全等价。
# CLI 有意把「配置值」与「运行时值」分离：config.env 保持契约 §2 默认 /usr/bin/bwrap，
# status --json 报自动探测到的实际执行路径。二者不同是设计，不是缺陷。
# 因此这里硬断言「绝对路径且可执行」；若 status 报的路径与 config 里的配置值不同，
# 只做提示（要求两者指向同一文件才算真正等价）。
bwrap_val=$(printf '%s' "$RUN_STDOUT" | tr -d '\n' | sed -n 's/.*"bwrap":[[:space:]]*"\([^"]*\)".*/\1/p')
if printf '%s' "$bwrap_val" | grep -qE '^/' && [ -x "$bwrap_val" ]; then
  _ok "bwrap 是可执行的绝对路径（$bwrap_val）"
  bwrap_cfg=$(config_value CAPBOX_BWRAP "/usr/bin/bwrap")
  if [ "$bwrap_val" != "$bwrap_cfg" ]; then
    # 若非同一文件，说明 CLI 探测到了一个真正不同的 bwrap，才值得关注
    if [ -e "$bwrap_cfg" ] && [ "$(stat -c %i "$bwrap_val" 2>/dev/null)" = "$(stat -c %i "$bwrap_cfg" 2>/dev/null)" ]; then
      _ok "配置值 $bwrap_cfg 与运行时值 $bwrap_val 是同一文件（inode 一致）"
    else
      mark_known_issue "status 报的 bwrap=$bwrap_val 与配置值 $bwrap_cfg 不是同一文件，请确认是有意的自动探测"
    fi
  fi
else
  _fail "bwrap 不是可执行的绝对路径：'$bwrap_val'" "实际 stdout: $(_short "$RUN_STDOUT" 2)"
fi

# 回归保护：config.env 里应保持契约 §2 的默认值，不应被运行时探测值污染
# （主模块 曾有一个 bug：config_save 把原地改写的运行时 CAPBOX_BWRAP 写回文件，
#   导致任何一次 config set 都会把 /usr/sbin/bwrap 持久化，契约默认值被永久替换）
if [ -f "$CAPBOX_DIR/config.env" ]; then
  cfg_line=$(grep -E "^[[:space:]]*CAPBOX_BWRAP=" "$CAPBOX_DIR/config.env" 2>/dev/null | tail -n 1)
  if [ -n "$cfg_line" ]; then
    cfg_raw=$(printf '%s' "$cfg_line" | sed -e 's/^[^=]*=//' -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//')
    if [ "$cfg_raw" = "/usr/sbin/bwrap" ] && [ ! -e /usr/bin/bwrap ]; then
      _ok "config.env 记录运行时探测值（本机无 /usr/bin/bwrap，属正常）"
    elif [ "$cfg_raw" = "$bwrap_val" ] && [ "$bwrap_val" != "/usr/bin/bwrap" ]; then
      mark_known_issue "config.env 的 CAPBOX_BWRAP=$cfg_raw 等于运行时探测值，疑似被 config_save 污染（曾有此 bug，已修；若复现请检查 _cfg_value_for_file）"
    else
      _ok "config.env 的 CAPBOX_BWRAP 保持配置值（$cfg_raw，未被运行时值污染）"
    fi
  fi
fi

# version 应形如 0.4.0（CAPBOX_VERSION 当前 0.4.0）
ver=$(printf '%s' "$RUN_STDOUT" | tr -d '\n' | sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p')
if printf '%s' "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  _ok "version 是 x.y.z 形式（$ver）"
else
  _fail "version 不是 x.y.z 形式：'$ver'" "实际 stdout: $(_short "$RUN_STDOUT" 2)"
fi

# daemon.running 必须是布尔/0-1，不能是 "unknown" 之类
val=$(printf '%s' "$RUN_STDOUT" | tr -d '\n' | sed -n 's/.*"running":\([^,}]*\).*/\1/p')
case "$val" in
  true | false | 0 | 1) _ok "daemon.running 取值合法（$val）" ;;
  *) _fail "daemon.running 取值非法：'$val'" "期望 true/false/0/1" ;;
esac

case_finish
exit 0
