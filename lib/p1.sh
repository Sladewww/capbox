# shellcheck shell=bash
[[ -f "${BASH_SOURCE[0]%/*}/p1-runtime.py" && -f "${BASH_SOURCE[0]%/*}/mcp-stdio.py" ]] || return 5
# Installation plans, portable snapshots and the stdio adapter share validated context.
_p1_command() {
  need_cmd python3
  local key lib="${BASH_SOURCE[0]%/*}"
  local -a context=(env "CAPBOX_P1_KEYS=${CAPBOX_CFG_KEYS[*]}"
    "CAPBOX_P1_WORKSPACE=$CAPBOX_WORKSPACE" "CAPBOX_P1_ROOTFS=$CAPBOX_ROOTFS"
    "CAPBOX_P1_DIR=$CAPBOX_DIR" "CAPBOX_P1_CLI=$_CAPBOX_CLI_BIN_DIR/capbox"
    "CAPBOX_P1_LIB=$lib" "CAPBOX_P1_VERSION=$CAPBOX_VERSION")
  for key in "${CAPBOX_CFG_KEYS[@]}"; do
    context+=("CAPBOX_P1_CFG_$key=$(_cfg_value "$key")"
      "CAPBOX_P1_SOURCE_$key=${CAPBOX_CFG_EXPLICIT[$key]:-default}")
  done
  "${context[@]}" python3 "$lib/p1-runtime.py" "$@"
}

cmd_setup() { _p1_command setup "$@"; }
_bundle_locked() { _upgrade_assert_stopped && _p1_command bundle "$@"; }
cmd_bundle() {
  case "${1:-}" in
    pack|restore) need_cmd flock; with_lock upgrade -- _bundle_locked "$@" ;;
    *) _p1_command bundle "$@" ;;
  esac
}
cmd_mcp() { _p1_command mcp "$@"; }
