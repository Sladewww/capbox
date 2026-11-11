# shellcheck shell=bash
# 运行时升级使用显式选定的本地模板与私有备份。
_upgrade_assert_stopped() {
  if daemon_running; then
    i18n_err upgrade.run_capbox_down_before_upgrading; return 1
  fi
  if declare -F _agent_command >/dev/null 2>&1; then
    _agent_command task list | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(any(t["status"] not in ("succeeded","failed","cancelled","timed_out","lost") for t in d["tasks"]))' || {
      i18n_err upgrade.cancel_wait_all_tasks_before_upgrading; return 1;
    }
  fi
  local private dir name
  private="$(_capbox_host_state_dir)" || return 1
  for dir in "$private"/services/*; do
    [[ -d "$dir" ]] || continue
    name="${dir##*/}"
    if _service_is_running "$name"; then
      i18n_err upgrade.run_capbox_service_stop_before_upgrading name="$name"; return 1
    fi
  done
  # 0.3.5 之前没有私有进程身份；不要信任其 PID 去发信号。
  for dir in "$CAPBOX_DIR"/run/services/*; do
    if [[ -e "$dir/supervisor.pid" ]]; then
      i18n_err upgrade.found_leftover_state_older_version_stop_services
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
        [[ $# -ge 2 ]] || i18n_die 2 upgrade.requires_template_directory
        source="$2"; shift 2 ;;
      --json) json=1; shift ;;
      *) i18n_die 2 upgrade.upgrade_unknown_argument arg="$1" ;;
    esac
  done
  if [[ "$action" == rollback ]]; then
    [[ -z "$source" ]] || i18n_die 2 upgrade.rollback_does_not_accept
  else
    [[ -n "$source" ]] || i18n_die 2 upgrade.upgrade_requires_template
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
