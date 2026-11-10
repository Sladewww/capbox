# shellcheck shell=bash
# 运行时升级使用显式选定的本地模板与私有备份。
_upgrade_assert_stopped() {
  if daemon_running; then
    log_err '升级前请先 capbox down'; return 1
  fi
  if declare -F _agent_command >/dev/null 2>&1; then
    _agent_command task list | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(any(t["status"] not in ("succeeded","failed","cancelled","timed_out","lost") for t in d["tasks"]))' || {
      log_err "升级前请先取消或等待所有 task"; return 1;
    }
  fi
  local private dir name
  private="$(_capbox_host_state_dir)" || return 1
  for dir in "$private"/services/*; do
    [[ -d "$dir" ]] || continue
    name="${dir##*/}"
    if _service_is_running "$name"; then
      log_err "升级前请先 capbox service stop $name"; return 1
    fi
  done
  # 0.3.5 之前没有私有进程身份；不要信任其 PID 去发信号。
  for dir in "$CAPBOX_DIR"/run/services/*; do
    if [[ -e "$dir/supervisor.pid" ]]; then
      log_err '发现旧版运行记录，请先用旧 CLI 停服并确认没有运行中的旧进程'
      return 1
    fi
  done
}

_upgrade_locked() {
  local action="$1" source="$2" json="$3" private data_root
  [[ "$action" == check ]] || _upgrade_assert_stopped || return $?
  private="$(_capbox_host_state_dir)" || return 1
  data_root="${XDG_STATE_HOME:-$HOME/.local/state}/capbox"
  local -a args=("$action" --target "$CAPBOX_DIR" --workspace "$CAPBOX_WORKSPACE"
    --private "$private" --data-root "$data_root")
  [[ -z "$source" ]] || args+=(--source "$source")
  [[ -z "$json" ]] || args+=(--json)
  python3 "${BASH_SOURCE[0]%/*}/upgrade-runtime.py" "${args[@]}"
}

cmd_upgrade() {
  local action=check source="" json=""
  case "${1:-}" in
    check|apply|rollback) action="$1"; shift ;;
    -h|--help)
      i18n_print help.upgrade
      return 0 ;;
  esac
  while (( $# )); do
    case "$1" in
      --from)
        [[ $# -ge 2 ]] || die 2 '--from 需要模板目录'
        source="$2"; shift 2 ;;
      --json) json=1; shift ;;
      *) die 2 "upgrade 未知参数: $1" ;;
    esac
  done
  if [[ "$action" == rollback ]]; then
    [[ -z "$source" ]] || die 2 'rollback 不接受 --from'
  else
    [[ -n "$source" ]] || die 2 'upgrade 需要 --from TEMPLATE'
  fi
  need_cmd python3
  need_cmd flock
  local t0 rc=0 _up_cmd="upgrade $action"
  t0=$(date +%s%3N 2>/dev/null || date +%s)
  [[ -n "$source" ]] && _up_cmd+=" --from $source"
  [[ -n "$json" ]] && _up_cmd+=" --json"
  with_lock upgrade -- _upgrade_locked "$action" "$source" "$json"
  rc=$?
  if declare -F audit_command >/dev/null 2>&1; then
    if (( rc == 0 )); then
      audit_command upgrade "$rc" "$t0" "cmd=$_up_cmd"
    else
      audit_command upgrade "$rc" "$t0" "cmd=$_up_cmd" "detail=upgrade $action 失败，退出码 $rc"
    fi
  fi
  return "$rc"
}
