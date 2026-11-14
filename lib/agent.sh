# shellcheck shell=bash
# Agent 命令走现有 exec 启动器；私有记录永不进入 guest。
_agent_command() {
  need_cmd python3
  local private key
  private="$(_capbox_host_state_dir)" || return 1
  local -a context=(env "CAPBOX_AGENT_PRIVATE=$private"
    "CAPBOX_AGENT_WORKSPACE=$CAPBOX_WORKSPACE" "CAPBOX_AGENT_ROOTFS=$CAPBOX_ROOTFS"
    "CAPBOX_AGENT_CLI=$_CAPBOX_CLI_BIN_DIR/capbox" "CAPBOX_AGENT_LIB=$CAPBOX_LIB_DIR"
    "CAPBOX_AGENT_ALLOW_ONCE=${CAPBOX_ALLOW_OLD_BWRAP_ONCE:-0}")
  if [[ "${1:-}" == task && "${2:-}" == start ]]; then
    context+=("CAPBOX_AGENT_AUDIT_PATH=$(_audit_path)" "CAPBOX_AGENT_AUDIT_CMD=")
    if _audit_enabled; then
      context+=("CAPBOX_AGENT_AUDIT_CMD=$(_audit_cmd_field "task ${*:2}")")
    fi
  fi
  for key in "${CAPBOX_CFG_KEYS[@]}"; do
    context+=("CAPBOX_AGENT_CFG_$key=$(_cfg_value "$key")"
      "CAPBOX_AGENT_SOURCE_$key=${CAPBOX_CFG_EXPLICIT[$key]:-default}")
  done
  "${context[@]}" python3 "${BASH_SOURCE[0]%/*}/agent-runtime.py" "$@"
}

cmd_task() {
  case "${1:-}" in
    -h | --help) _agent_command task "$@"; return $? ;;
  esac
  local t0 rc=0 _audit_task_id=""
  t0=$(date +%s%3N 2>/dev/null || date +%s)
  # 串行化任务提交、归档和删除；归档期间保留私有工作树。
  if [[ "${1:-}" == start || "${1:-}" == checkpoint || "${1:-}" == rm ]]; then
    need_cmd flock
    with_lock upgrade -- _agent_command task "$@"
    rc=$?
  else
    _agent_command task "$@"
    rc=$?
    case "${1:-}" in
      status|wait|attach|cancel|logs|diff|rm)
        if [[ "${2:-}" =~ ^[0-9a-f]{32}$ ]]; then _audit_task_id="$2"; fi ;;
    esac
  fi
  if [[ "${1:-}" == start && "$rc" == 0 ]]; then return 0; fi
  if declare -F audit_command >/dev/null 2>&1; then
    if (( rc == 0 )); then
      audit_command task "$rc" "$t0" "cmd=task $*"
    else
      audit_command task "$rc" "$t0" "cmd=task $*" "detail=$(i18n_fmt audit.detail_cmd_failed cmd=task rc="$rc")"
    fi
  fi
  return "$rc"
}

cmd_policy() { _agent_command policy "$@"; }
