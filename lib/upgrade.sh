# shellcheck shell=bash
# Runtime upgrades use an explicitly selected local template and private backups.
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
  # Pre-0.3.5 has no private process identities. Do not trust its PID to send signals.
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
      cat <<'HELP'
用法: capbox upgrade check --from TEMPLATE [--json]
      capbox upgrade apply --from TEMPLATE
      capbox upgrade rollback

  TEMPLATE 是工作区外、由你信任的完整 CapBox 安装目录（含 bin/lib）。
  check 比较运行文件；apply 暂存并校验成套 bin/lib，私有备份后替换。
  替换或冒烟检查失败时恢复原文件；rollback 恢复最近一次成功升级前的文件。
  必须先用旧 CLI 停止所有 service/daemon，并停止其它 exec；不会替你杀进程。
  仅更新运行文件；配置、rootfs、业务数据保持原位置。备份持久保存在工作区外的 XDG_STATE_HOME/capbox（默认 ~/.local/state/capbox）。
  旧项目请从新版模板的 bin/capbox 调用本命令（--root 指定项目）。
HELP
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
  with_lock upgrade -- _upgrade_locked "$action" "$source" "$json"
}
