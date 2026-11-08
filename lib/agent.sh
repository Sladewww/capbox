# shellcheck shell=bash
# Agent commands use the existing exec launcher; private records never enter a guest.
_agent_command() {
  need_cmd python3
  local private key
  private="$(_capbox_host_state_dir)" || return 1
  local -a context=(env "CAPBOX_AGENT_PRIVATE=$private"
    "CAPBOX_AGENT_WORKSPACE=$CAPBOX_WORKSPACE" "CAPBOX_AGENT_ROOTFS=$CAPBOX_ROOTFS"
    "CAPBOX_AGENT_CLI=$_CAPBOX_CLI_BIN_DIR/capbox" "CAPBOX_AGENT_LIB=$CAPBOX_LIB_DIR"
    "CAPBOX_AGENT_ALLOW_ONCE=${CAPBOX_ALLOW_OLD_BWRAP_ONCE:-0}")
  for key in "${CAPBOX_CFG_KEYS[@]}"; do
    context+=("CAPBOX_AGENT_CFG_$key=$(_cfg_value "$key")"
      "CAPBOX_AGENT_SOURCE_$key=${CAPBOX_CFG_EXPLICIT[$key]:-default}")
  done
  "${context[@]}" python3 "${BASH_SOURCE[0]%/*}/agent-runtime.py" "$@"
}

cmd_task() {
  # Serialize submission with runtime upgrades. Readers and workers use private records.
  if [[ "${1:-}" == start ]]; then
    need_cmd flock
    with_lock upgrade -- _agent_command task "$@"
  else
    _agent_command task "$@"
  fi
}

cmd_policy() { _agent_command policy "$@"; }
