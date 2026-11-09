# shellcheck shell=bash
[[ -f "${BASH_SOURCE[0]%/*}/envkit-runtime.py" && -f "${BASH_SOURCE[0]%/*}/mcp-stdio.py" ]] || return 5
# 安装计划、可移植快照与 stdio 适配器共用已校验的上下文。
_envkit_command() {
  need_cmd python3
  local key lib="${BASH_SOURCE[0]%/*}"
  local -a context=(env "CAPBOX_ENVKIT_KEYS=${CAPBOX_CFG_KEYS[*]}"
    "CAPBOX_ENVKIT_WORKSPACE=$CAPBOX_WORKSPACE" "CAPBOX_ENVKIT_ROOTFS=$CAPBOX_ROOTFS"
    "CAPBOX_ENVKIT_DIR=$CAPBOX_DIR" "CAPBOX_ENVKIT_CLI=$_CAPBOX_CLI_BIN_DIR/capbox"
    "CAPBOX_ENVKIT_LIB=$lib" "CAPBOX_ENVKIT_VERSION=$CAPBOX_VERSION")
  for key in "${CAPBOX_CFG_KEYS[@]}"; do
    context+=("CAPBOX_ENVKIT_CFG_$key=$(_cfg_value "$key")"
      "CAPBOX_ENVKIT_SOURCE_$key=${CAPBOX_CFG_EXPLICIT[$key]:-default}")
  done
  "${context[@]}" python3 "$lib/envkit-runtime.py" "$@"
}

cmd_setup() { _envkit_command setup "$@"; }
_bundle_locked() { _upgrade_assert_stopped && _envkit_command bundle "$@"; }
cmd_bundle() {
  case "${1:-}" in
    pack|restore) need_cmd flock; with_lock upgrade -- _bundle_locked "$@" ;;
    *) _envkit_command bundle "$@" ;;
  esac
}
cmd_mcp() {
  case "${1:-}" in
    -h | --help) _envkit_command mcp "$@"; return $? ;;
  esac
  local t0 rc=0
  t0=$(date +%s%3N 2>/dev/null || date +%s)
  _envkit_command mcp "$@"
  rc=$?
  if declare -F audit_command >/dev/null 2>&1; then
    if (( rc == 0 )); then
      audit_command mcp "$rc" "$t0" "cmd=mcp $*"
    else
      audit_command mcp "$rc" "$t0" "cmd=mcp $*" "detail=mcp 失败，退出码 $rc"
    fi
  fi
  return "$rc"
}
