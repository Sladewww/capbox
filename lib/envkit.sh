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
  if [[ "${1:-}" == setup ]]; then
    local rootfs=missing userns=not_probed netns=not_probed cgroup=not_probed
    local probe=0 arg namespace_detail="" cgroup_detail=""
    rootfs_ready && rootfs=ready
    if [[ "${2:-}" == check || "${2:-}" == plan ]]; then
      for arg in "${@:3}"; do
        case "$arg" in
          -h|--help) probe=0; break ;;
          --probe) probe=1 ;;
        esac
      done
    fi
    if (( probe )); then
      if [[ -f "${CAPBOX_BWRAP:-}" && -x "$CAPBOX_BWRAP" ]]; then
        if _doctor_probe_userns; then
          userns=ready
          if [[ "${CAPBOX_NET:-open}" == open ]]; then
            netns=not_required
          elif _doctor_probe_userns network; then
            netns=ready
          else
            netns=failed
          fi
        else
          userns=failed
        fi
      else
        userns=dependency_missing
      fi
      namespace_detail="${CAPBOX_USERNS_DETAIL:-}"
      _resources_probe_cgroup inspect || true
      cgroup="$CAPBOX_CGROUP_STATUS"
      cgroup_detail="$CAPBOX_CGROUP_DETAIL"
    fi
    context+=("CAPBOX_SETUP_ROOTFS=$rootfs" "CAPBOX_SETUP_USERNS=$userns"
      "CAPBOX_SETUP_NETNS=$netns" "CAPBOX_SETUP_NAMESPACE_DETAIL=$namespace_detail"
      "CAPBOX_SETUP_CGROUP=$cgroup"
      "CAPBOX_SETUP_CGROUP_DETAIL=$cgroup_detail")
  fi
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
      audit_command mcp "$rc" "$t0" "cmd=mcp $*" "detail=$(i18n_fmt audit.detail_cmd_failed cmd=mcp rc="$rc")"
    fi
  fi
  return "$rc"
}
