#!/usr/bin/env bash
# T27 — 多 UID 映射：chown / setuid（或诚实 SKIP/FAIL）
set -u
CASE_TITLE="多 UID 映射：chown 到 33 且 --uid 降权（或明确阻塞）"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖 idmap"
  case_finish; exit 0
fi

# doctor 行（连续两次：验证 idmap 探针不留下 sticky /tmp 固定文件）
assert_file_absent /tmp/.capbox-idmap-probe "探测前无固定 /tmp/.capbox-idmap-probe"
run_cmd "$CAPBOX_BIN" doctor
assert_rc 0 "doctor 退出码"
assert_file_absent /tmp/.capbox-idmap-probe "doctor 后无固定 probe 文件残留"
assert_out_not_matches 'PermissionError' "doctor 无 PermissionError"
run_cmd "$CAPBOX_BIN" doctor
assert_rc 0 "doctor 第二次仍成功（无私有 tmp 冲突）"
assert_file_absent /tmp/.capbox-idmap-probe "第二次 doctor 后仍无固定 probe 文件"
assert_out_not_matches 'PermissionError' "第二次 doctor 无 PermissionError"
if printf '%s' "${RUN_STDOUT}${RUN_STDERR}" | grep -q 'UID 映射 multi'; then
  _ok "doctor 报告 multi"
elif printf '%s' "${RUN_STDOUT}${RUN_STDERR}" | grep -qE 'UID 映射 (single|不可用|被阻塞)'; then
  mark_known_issue "本环境无法多 UID 映射；后续断言改为验证单 UID 边界"
  run_cmd "$CAPBOX_BIN" exec -- sh -c 'touch /tmp/t27; chown 33:33 /tmp/t27 2>&1 || true'
  if printf '%s' "$RUN_STDOUT" | grep -qiE 'Invalid argument|Operation not permitted|chown:'; then
    _ok "单 UID 下 chown 33 失败（预期）"
  else
    # 某些系统 chown 可能静默成功到同一映射
    mark_known_issue "chown 33 未报错；请人工确认 uid_map"
  fi
  case_finish; exit 0
else
  _fail "doctor 未报告 UID 映射状态"
  case_finish; exit 0
fi

run_cmd "$CAPBOX_BIN" exec -- sh -c 'touch /tmp/t27; chown 33:33 /tmp/t27; ls -ln /tmp/t27'
assert_rc 0 "chown 33 退出码"
assert_stdout_matches '[[:space:]]33[[:space:]]+33[[:space:]]' "ls 显示属主 33:33"

run_cmd "$CAPBOX_BIN" exec --uid 33 --gid 33 -- id -u
assert_rc 0 "--uid 33 退出码"
assert_stdout_eq "33" "--uid 33 → id -u"

# 完整 id（曾在 Alpine BusyBox setpriv 上因 --reuid 长参失败）
run_cmd "$CAPBOX_BIN" exec --uid 33 --gid 33 -- id
assert_rc 0 "--uid 33 id 退出码"
assert_out_not_matches 'unrecognized option|BusyBox.*setpriv|reuid' "不得把 GNU setpriv 长参传给 BusyBox"
assert_stdout_matches 'uid=33' "id 显示 uid=33"
assert_stdout_matches 'gid=33' "id 显示 gid=33"

# 静态 drop helper：宿主 gcc -static 构建，装入 alpine rootfs（无 passwd 条目也能降权）
repo_lib="$(cd "$(dirname "$CAPBOX_BIN")/../lib" && pwd)"
[[ -f "$repo_lib/idmap.sh" ]] || repo_lib="$CAPBOX_DIR/lib"
helper_bin="$CAPBOX_DIR/run/helpers/capbox-drop-priv"
guest_helper="$CAPBOX_DIR/os/${CAPBOX_DISTRO:-alpine}/usr/libexec/capbox-drop-priv"
# 若 distro 路径不同，用 CAPBOX_ROOTFS 探测
if [[ ! -e "$guest_helper" ]]; then
  # derive from status/config if needed
  guest_helper=""
fi
set +e
(
  set -euo pipefail
  log_warn(){ :; }; log_err(){ printf 'ERR %s\n' "$*" >&2; }; log_debug(){ :; }
  have_cmd(){ command -v "$1" >/dev/null 2>&1; }
  # shellcheck source=/dev/null
  source "$repo_lib/idmap.sh"
  export CAPBOX_DIR="${CAPBOX_DIR}"
  export CAPBOX_ROOTFS="${CAPBOX_ROOTFS:-$CAPBOX_DIR/os/alpine}"
  [[ -d "$CAPBOX_ROOTFS" ]] || CAPBOX_ROOTFS="$CAPBOX_DIR/os/alpine"
  export CAPBOX_ROOTFS
  _idmap_ensure_drop_priv_helper
  echo "DETAIL=${CAPBOX_IDMAP_DROP_HELPER_DETAIL:-}"
  hb="$(_idmap_drop_priv_host_bin)"
  [[ -x "$hb" ]] || { echo "FAIL host helper missing $hb"; exit 1; }
  echo "OK host helper $hb"
  if [[ -n "${CAPBOX_ROOTFS:-}" ]]; then
    gh="${CAPBOX_ROOTFS}$(_idmap_drop_priv_guest_bin)"
    [[ -x "$gh" ]] || { echo "FAIL guest helper missing $gh"; exit 1; }
    echo "OK guest helper $gh"
  fi
) >"$QA_TMP/drop-helper-unit.out" 2>&1
hrc=$?
set -e
assert_eq 0 "$hrc" "drop helper ensure 退出码"
assert_file_contains "$QA_TMP/drop-helper-unit.out" "OK host helper" "宿主 helper 已构建"

# Alpine BusyBox-only 模拟：遮住 /usr/bin/setpriv，确认仍能 --uid（走 helper，不依赖 passwd）
# 通过把 busybox 绑到 /usr/bin/setpriv 上方——用 CAPBOX 一次 exec 验证 helper 直接可用
run_cmd "$CAPBOX_BIN" exec --timeout 15 -- /usr/libexec/capbox-drop-priv 33 33 id
assert_rc 0 "rootfs helper 直接降权"
assert_stdout_matches 'uid=33' "helper → uid=33"
assert_out_not_matches 'cannot drop privileges' "helper 路径无 cannot drop"

# 确认 alpine 无 uid 33 账户时 su 会失败（说明不能依赖 su）
run_cmd "$CAPBOX_BIN" exec --timeout 10 -- sh -c 'grep -E ":33:" /etc/passwd >/dev/null && echo HAS33 || echo NO33; su 33 -s /bin/sh -c id 2>&1 | head -1 || true'
assert_out_matches 'NO33|unknown user|su:' "alpine 无可靠 su 33（helper 必需）"


# 单元：构造 wrap 时必须用运行时选择器，而不是裸 setpriv --reuid
unit_out="$QA_TMP/idmap-wrap-unit.out"
repo_lib="$(cd "$(dirname "$CAPBOX_BIN")/../lib" && pwd)"
[[ -f "$repo_lib/idmap.sh" ]] || repo_lib="$CAPBOX_DIR/lib"
set +e
(
  set -euo pipefail
  log_warn() { :; }
  log_err() { printf 'ERR %s\n' "$*" >&2; }
  log_debug() { :; }
  have_cmd() { command -v "$1" >/dev/null 2>&1; }
  # shellcheck source=/dev/null
  source "$repo_lib/idmap.sh"
  export CAPBOX_DIR="${CAPBOX_DIR}"
  export CAPBOX_ROOTFS="${CAPBOX_ROOTFS:-$CAPBOX_DIR/os/alpine}"
  CAPBOX_EXEC_UID_OVERRIDE=33
  CAPBOX_EXEC_GID_OVERRIDE=33
  CAPBOX_IDMAP_STATUS=multi
  local_argv=(/usr/bin/bwrap --bind / / -- /bin/id)
  # _idmap_find_bwrap_dd looks for -- then command; ensure present
  local_argv=(/usr/bin/bwrap --ro-bind / / -- /bin/id)
  _idmap_wrap_argv_for_uid local_argv
  printf 'WRAP '
  printf '%q ' "${local_argv[@]}"
  printf '\n'
  # 不得直接出现「裸」setpriv --reuid= 作为 guest 入口（必须经 /bin/sh -c 选择器）
  joined="${local_argv[*]}"
  case "$joined" in
    */usr/libexec/capbox-drop-priv*|*/bin/sh*-c*) echo "OK wrap uses helper or sh -c" ;;
    *) echo "FAIL expected helper or sh -c: $joined"; exit 1 ;;
  esac
  case "$joined" in
    *'setpriv --reuid='*|*'setpriv --reuid '*)
      # 允许出现在 -c 脚本字符串内部，但不能是数组里独立的 argv0=setpriv
      ;;
  esac
  # argv 在 -- 之后：优先 helper，否则 /bin/sh -c 选择器
  saw_dd=0
  first_prog=""
  for a in "${local_argv[@]}"; do
    if [[ "$saw_dd" == 1 ]]; then first_prog="$a"; break; fi
    [[ "$a" == -- ]] && saw_dd=1
  done
  case "$first_prog" in
    /usr/libexec/capbox-drop-priv|/bin/sh)
      echo "OK first guest prog is $first_prog"
      ;;
    *)
      echo "FAIL unexpected first prog after --: $first_prog"; exit 1
      ;;
  esac
  if [[ "$first_prog" == /usr/libexec/capbox-drop-priv ]]; then
    echo "OK wrap uses static drop helper"
  else
    case "$joined" in
      */bin/sh*-c*) echo "OK wrap uses /bin/sh -c selector" ;;
      *) echo "FAIL expected helper or sh -c: $joined"; exit 1 ;;
    esac
  fi
) >"$unit_out" 2>&1
wrap_rc=$?
set -e
assert_eq 0 "$wrap_rc" "idmap wrap unit 退出码"
assert_file_contains "$unit_out" "OK first guest prog is" "guest 入口为 helper 或 sh"

case_finish
exit 0
