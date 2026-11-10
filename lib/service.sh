# shellcheck shell=bash
# =============================================================================
# CapBox - service.sh
# 配置化服务：start / stop / status / logs
#
# 服务定义：.capbox/services/<name>.env（纯 KEY=value，不 source）
#   CMD='nginx -g "daemon off;"'     # 必填，是要执行的命令，不是环境变量
#   UID=33  GID=33  USER=www-data    # 可选；USER/CWD 会在 --clearenv 之后 --setenv
#   CWD=/  PIDFILE=  LOG=  NET=
#   MY_VAR=hello                     # 其它 KEY=value 原样注入 guest
#   REQUIRE_IDMAP=0                  # 1=需要 multi 映射
#
# 宿主控制文件放在工作区外；只有 guest-run/ 会挂到 guest /run。
# =============================================================================

_service_dir() { printf '%s' "${CAPBOX_DIR}/services"; }
_service_run_dir() {
  _service_valid_name "${1:-}" || { i18n_err svc.invalid_service_name arg="${1:-}"; return 2; }
  local private
  private="$(_capbox_host_state_dir)" || return 1
  printf '%s/services/%s' "$private" "${1:-}"
}

_service_valid_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]]
}

_service_reserved_key() {
  case "${1:-}" in
    CMD|UID|GID|USER|CWD|PIDFILE|LOG|NET|REQUIRE_IDMAP|\
    READY_CMD|READY_TCP|READY_HTTP|READY_TIMEOUT|\
    HEALTH_CMD|HEALTH_INTERVAL|HEALTH_RETRIES|\
    RESTART|RESTART_MAX|RESTART_BACKOFF|STOP_TIMEOUT|\
    DEPENDS_ON|PUBLISH) return 0 ;;
    *) return 1 ;;
  esac
}

_service_load() {
  local name="${1:-}"
  local -n _out="$2"
  local -n _env="$3"
  _out=()
  _env=()
  _service_valid_name "$name" || { i18n_err svc.invalid_service_name_2 name="$name"; return 2; }
  local f="$(_service_dir)/${name}.env"
  [[ -f "$f" ]] || { i18n_err svc.service_definition_does_not_exist f="$f"; return 1; }
  local line key raw
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" && "$line" != \#* ]] || continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    raw="${BASH_REMATCH[2]}"
    if [[ "$raw" == \'*\' && ${#raw} -ge 2 ]]; then
      raw="${raw:1:${#raw}-2}"
    elif [[ "$raw" == \"*\" && ${#raw} -ge 2 ]]; then
      raw="${raw:1:${#raw}-2}"
      if [[ "$raw" =~ [\$\`\\] ]]; then
        i18n_err svc.service_value_contains_illegal_expansion_characters name="$name" key="$key"
        return 2
      fi
    fi
    if [[ "$raw" == *$'\n'* ]]; then
      i18n_err svc.service_value_contains_newline name="$name" key="$key"
      return 2
    fi
    if _service_reserved_key "$key"; then
      _out["$key"]="$raw"
    else
      _env["$key"]="$raw"
    fi
  done <"$f"
  [[ -n "${_out[CMD]:-}" ]] || { i18n_err svc.service_missing_cmd name="$name"; return 2; }
  return 0
}

# --clearenv 之后把 USER、CWD 和自定义键注入 guest。CMD 仍只是要执行的命令。
_service_append_env_args() {
  local -n _sa="$1"
  local -n _sc="$2"
  local -n _se="$3"
  local k
  if [[ -n "${_sc[USER]:-}" ]]; then
    _sa+=(--setenv USER "${_sc[USER]}")
  fi
  if [[ -n "${_sc[CWD]:-}" ]]; then
    _sa+=(--setenv CWD "${_sc[CWD]}")
  fi
  for k in "${!_se[@]}"; do
    _sa+=(--setenv "$k" "${_se[$k]}")
  done
}

_service_diagnose() {
  local name="${1:-}" reason="${2:-}"
  local rd rootfs
  rd="$(_service_run_dir "$name")" || return 1
  rootfs="${CAPBOX_ROOTFS:-}"
  i18n_err svc.service_diagnostics name="$name" reason="$reason"
  if declare -F _idmap_probe >/dev/null 2>&1; then
    _idmap_probe >/dev/null 2>&1 || true
    i18n_err svc.idmap status="${CAPBOX_IDMAP_STATUS:-?}" detail="${CAPBOX_IDMAP_DETAIL:-}"
  fi
  if have_cmd ss; then
    i18n_err svc.listening_ports_ss_lntu_head
    ss -lntu 2>/dev/null | head -n 8 | while IFS= read -r L; do i18n_err svc.msg L="$L"; done
  fi
  if [[ -n "$rootfs" ]]; then
    for d in /var/lib /var/log /run /etc; do
      if [[ -d "$rootfs$d" ]]; then i18n_err svc.rootfs_present d="$d"
      else i18n_err svc.rootfs_missing d="$d"; fi
    done
  fi
  if [[ -f "$rd/service.log" ]]; then
    i18n_err svc.recent_logs
    tail -n 15 -- "$rd/service.log" 2>/dev/null | while IFS= read -r L; do i18n_err svc.msg L="$L"; done
  fi
}

cmd_service() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    -h|--help|"")
      i18n_print help.service
      return 0
      ;;
    list)
      local d f base any=0
      d="$(_service_dir)"
      if [[ ! -d "$d" ]]; then
        printf '(无服务定义目录 %s)\n' "$d"
        return 0
      fi
      for f in "$d"/*.env; do
        [[ -f "$f" ]] || continue
        any=1
        base="$(basename "$f" .env)"
        if _service_is_running "$base"; then printf '%s\trunning\n' "$base"
        else printf '%s\tstopped\n' "$base"; fi
      done
      (( any == 1 )) || printf '(尚无 *.env 服务定义)\n'
      return 0
      ;;
    start) _service_start "$@" ;;
    stop) _service_stop "$@" ;;
    status) _service_status "$@" ;;
    logs) _service_logs "$@" ;;
    *) i18n_die 2 svc.service_unknown_subcommand_start_stop_status_logs sub="$sub" ;;
  esac
}

_service_is_running() {
  local name="${1:-}" rd pid
  rd="$(_service_run_dir "$name")" || return 1
  [[ -f "$rd/supervisor.pid" ]] || return 1
  pid="$(cat "$rd/supervisor.pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  local identity
  identity="$(_capbox_process_identity "$pid")" || return 1
  [[ "$identity" == "$(cat "$rd/supervisor.pid.identity" 2>/dev/null)" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

_service_supervisor_py() {
  local cands=(
    "${CAPBOX_LIB_DIR:-}/service-supervisor.py"
    "${_CAPBOX_TEMPLATE_DIR:-}/lib/service-supervisor.py"
    "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/service-supervisor.py"
  )
  local p
  for p in "${cands[@]}"; do
    [[ -n "$p" && -f "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

_service_start_deps() {
  local deps="${1:-}" d
  [[ -n "$deps" ]] || return 0
  IFS=',' read -r -a _deps <<<"$deps"
  for d in "${_deps[@]}"; do
    d="${d#"${d%%[![:space:]]*}"}"
    d="${d%"${d##*[![:space:]]}"}"
    [[ -n "$d" ]] || continue
    _service_valid_name "$d" || i18n_die 2 svc.depends_has_invalid_service_name d="$d"
    if ! _service_is_running "$d"; then
      i18n_info svc.dependency_not_running_starting_first d="$d"
      _service_start "$d" || {
        i18n_err svc.failed_start_dependency_service d="$d"
        return 1
      }
    fi
  done
  return 0
}

_service_check_id() {
  local v="${1:-}" label="${2:-id}" who="${3:-}" n
  [[ "$v" =~ ^[0-9]+$ ]] || {
    i18n_err svc.service_not_decimal_number who="${who}" label="${label}" v="${v:-<empty>}"
    return 2
  }
  n="$v"
  while [[ "$n" == 0* && ${#n} -gt 1 ]]; do
    n="${n#0}"
  done
  if (( ${#n} > 10 )) || (( 10#$n > 4294967295 )); then
    i18n_err svc.service_outside_32_bit_range who="${who}" label="${label}" v="$v"
    return 2
  fi
  printf '%s' "$n"
}

_service_net_tag() {
  local safe="${1//[^A-Za-z0-9_-]/-}"
  printf 'svc-%s' "$safe"
}

# 启动失败时收掉本次 restricted 代理。动态作用域能看见调用方的 name / _svc_restricted。
_service_abort() {
  local rc="${1:-1}"
  shift || true
  unset CAPBOX_EXEC_UID_OVERRIDE CAPBOX_EXEC_GID_OVERRIDE
  if [[ "${_svc_restricted:-0}" == 1 ]]; then
    if [[ -z "${CAPBOX_NET_SESSION:-}" ]]; then
      export CAPBOX_NET_SESSION="$(_service_net_tag "${name:-svc}")"
    fi
    if declare -F _net_cleanup_restricted_session >/dev/null 2>&1; then
      _net_cleanup_restricted_session || true
    fi
    unset CAPBOX_NET_SESSION
    _svc_restricted=0
  fi
  if [[ $# -gt 0 && -n "${name:-}" ]]; then
    _service_diagnose "$name" "$*"
  elif [[ $# -gt 0 ]]; then
    log_err "$*"
  fi
  return "$rc"
}

_service_release_net() {
  local who="${1:-}" rd meta net="" sess="" line saved=""
  rd="$(_service_run_dir "$who")" || return 1
  meta="$rd/meta.env"
  if [[ -f "$meta" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^NET=\'([A-Za-z0-9_-]+)\'$ ]]; then
        net="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^NET_SESSION=\'(svc-[A-Za-z0-9_-]+)\'$ ]]; then
        sess="${BASH_REMATCH[1]}"
      fi
    done <"$meta"
  fi
  [[ "$net" == "restricted" ]] || return 0
  [[ -n "$sess" ]] || sess="$(_service_net_tag "$who")"
  if declare -F _net_cleanup_restricted_session >/dev/null 2>&1; then
    saved="${CAPBOX_NET_SESSION:-}"
    export CAPBOX_NET_SESSION="$sess"
    _net_cleanup_restricted_session || true
    if [[ -n "$saved" ]]; then
      export CAPBOX_NET_SESSION="$saved"
    else
      unset CAPBOX_NET_SESSION
    fi
  fi
}

_service_start() {
  local name="${1:-}"
  [[ -n "$name" ]] || i18n_die 2 svc.usage_capbox_service_start_name
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) cmd_service --help; return 0 ;;
      *) i18n_die 2 svc.service_start_unknown_option arg="$1" ;;
    esac
  done

  require_rootfs
  local -A svc=() svc_env=()
  _service_load "$name" svc svc_env || return $?

  if _service_is_running "$name"; then
    i18n_info svc.service_already_running_pid name="$name" pid="$(cat "$(_service_run_dir "$name")/supervisor.pid")"
    return 0
  fi

  _service_start_deps "${svc[DEPENDS_ON]:-}" || return 1

  local uid="${svc[UID]:-}" gid="${svc[GID]:-}" user="${svc[USER]:-}"
  local cwd="${svc[CWD]:-/}" require_idmap="${svc[REQUIRE_IDMAP]:-0}"
  local net="${svc[NET]:-}"
  local stop_timeout="${svc[STOP_TIMEOUT]:-10}"
  local restart="${svc[RESTART]:-no}"
  local restart_max="${svc[RESTART_MAX]:-3}"
  local restart_backoff="${svc[RESTART_BACKOFF]:-1}"
  local ready_timeout="${svc[READY_TIMEOUT]:-30}"
  local health_interval="${svc[HEALTH_INTERVAL]:-0}"
  local health_retries="${svc[HEALTH_RETRIES]:-3}"

  [[ "$stop_timeout" =~ ^[0-9]+([.][0-9]+)?$ ]] || i18n_die 2 svc.invalid_stop_timeout
  [[ "$restart_max" =~ ^[0-9]+$ ]] || i18n_die 2 svc.invalid_restart_max
  [[ "$ready_timeout" =~ ^[0-9]+$ ]] || i18n_die 2 svc.invalid_ready_timeout
  case "$restart" in no|on-failure|always) ;; *) i18n_die 2 svc.restart_must_no_failure_always ;; esac

  if [[ -n "$user" ]]; then
    local resolved
    if declare -F _idmap_resolve_user >/dev/null 2>&1 && resolved="$(_idmap_resolve_user "$user")"; then
      if [[ "$resolved" == *:* ]]; then
        uid="${resolved%%:*}"; gid="${resolved#*:}"
      else
        uid="$resolved"; : "${gid:=$uid}"
      fi
    else
      i18n_err svc.service_unable_resolve_user_guest_passwd name="$name" user="$user"
      _service_diagnose "$name" "USER 不存在于 ${CAPBOX_ROOTFS}/etc/passwd"
      return 1
    fi
  fi
  : "${uid:=${CAPBOX_EXEC_UID:-0}}"
  : "${gid:=${CAPBOX_EXEC_GID:-0}}"
  uid="$(_service_check_id "$uid" UID "$name")" || return 2
  gid="$(_service_check_id "$gid" GID "$name")" || return 2

  if [[ "$require_idmap" == "1" ]]; then
    if ! declare -F _idmap_probe >/dev/null 2>&1 || ! _idmap_probe; then
      _service_diagnose "$name" "REQUIRE_IDMAP=1 但多 UID 映射不可用"
      return 1
    fi
    if [[ "${CAPBOX_IDMAP_STATUS}" != "multi" ]]; then
      _service_diagnose "$name" "REQUIRE_IDMAP=1 但当前为 ${CAPBOX_IDMAP_STATUS}"
      return 1
    fi
  fi

  if [[ -n "$net" ]]; then
    case "$net" in
      none|restricted|open|host) CAPBOX_NET="$net" ;;
      *) i18n_die 2 svc.service_invalid_net name="$name" net="$net" ;;
    esac
  fi

  local effective_net="" _svc_restricted=0 ready_guest=""
  if declare -F _net_mode >/dev/null 2>&1; then
    effective_net="$(_net_mode)" || return $?
  else
    effective_net="${CAPBOX_NET:-open}"
    [[ "$effective_net" == "host" ]] && effective_net="open"
  fi
  if [[ "$effective_net" == "restricted" ]]; then
    _svc_restricted=1
    export CAPBOX_NET_SESSION="$(_service_net_tag "$name")"
    if declare -F _net_restricted_prereqs >/dev/null 2>&1; then
      _net_restricted_prereqs >/dev/null || {
        _service_abort $? "restricted 前置不满足" || return $?
      }
    fi
    if declare -F _net_start_host_proxy >/dev/null 2>&1; then
      _net_start_host_proxy || {
        _service_abort 1 "restricted 代理启动失败" || return $?
      }
    fi
    if declare -F _guest_workspace_path >/dev/null 2>&1 && declare -F _net_bridge_ready >/dev/null 2>&1; then
      ready_guest="$(_net_guest_path "$(_net_bridge_ready)")"
    fi
    [[ -n "$ready_guest" ]] || {
      _service_abort 1 "guest 看不到 bridge ready 路径" || return $?
    }
  else
    unset CAPBOX_NET_SESSION
  fi

  local rd
  rd="$(_service_run_dir "$name")" || return 1
  mkdir -p "$rd" || {
    _service_abort 1 "无法创建 $rd" || return $?
  }
  [[ ! -L "$rd" && -d "$rd" ]] || {
    _service_abort 1 "服务运行目录是符号链接" || return $?
  }

  export CAPBOX_EXEC_UID_OVERRIDE="$uid"
  export CAPBOX_EXEC_GID_OVERRIDE="$gid"

  local cmd="${svc[CMD]}"
  local wrap pidpath
  pidpath="/run/capbox-svc/${name}.pid"
  if [[ -n "$ready_guest" ]]; then
    wrap="mkdir -p /run/capbox-svc 2>/dev/null || true; echo \$\$ > $(printf %q "$pidpath"); cd $(printf %q "$cwd") || exit 1; f=$(printf %q "$ready_guest"); i=0; while [ ! -f \"\$f\" ]; do i=\$((i+1)); [ \"\$i\" -gt 400 ] && exit 1; sleep 0.05; done; exec /bin/sh -c $(printf %q "$cmd")"
  else
    wrap="mkdir -p /run/capbox-svc 2>/dev/null || true; echo \$\$ > $(printf %q "$pidpath"); cd $(printf %q "$cwd") || exit 1; exec /bin/sh -c $(printf %q "$cmd")"
  fi

  local -a args=() full=()
  local _bbrc=0
  CAPBOX_BWRAP_NO_DIE_WITH_PARENT=1
  export CAPBOX_BWRAP_NO_DIE_WITH_PARENT
  CAPBOX_BWRAP_BASELINE_CMD="service start ${name}"
  mapfile -t args < <(build_bwrap_args oneshot "$cwd"; printf 'CAPBOX_BWRAP_ARGS_RC=%s\n' "$?")
  if [[ ${#args[@]} -gt 0 && "${args[-1]}" == CAPBOX_BWRAP_ARGS_RC=* ]]; then
    _bbrc="${args[-1]#CAPBOX_BWRAP_ARGS_RC=}"
    unset 'args[-1]'
  fi
  if (( _bbrc == 6 )); then
    _service_abort 6 || return $?
  fi
  if (( _bbrc != 0 )); then
    _service_abort "$_bbrc" "无法构造 bwrap 参数（rc=${_bbrc}；常见原因：bwrap 版本不足）" || return $?
  fi
  if ((${#args[@]} == 0)); then
    _service_abort 4 "无法构造 bwrap 参数" || return $?
  fi
  local -a filtered=()
  local a
  for a in "${args[@]}"; do
    [[ "$a" == "--die-with-parent" ]] && continue
    filtered+=("$a")
  done
  args=("${filtered[@]}")
  _service_append_env_args args svc svc_env
  mkdir -p "$rd/guest-run" 2>/dev/null || true
  args+=(--bind "$rd/guest-run" /run)
  _net_append_ready_bind args || return $?
  full=("$CAPBOX_BWRAP" "${args[@]}" -- /bin/sh -c "$wrap")

  if declare -F _security_wrap_argv >/dev/null 2>&1; then
    _security_wrap_argv full || {
      _service_abort $? "安全档无法应用" || return $?
    }
  fi
  if declare -F _resources_wrap_argv >/dev/null 2>&1; then
    _resources_wrap_argv full || {
      _service_abort 1 "资源限额无法应用" || return $?
    }
  fi
  if declare -F _landlock_apply_argv >/dev/null 2>&1; then
    _landlock_apply_argv full || {
      _service_abort $? "Landlock 未能启用" || return $?
    }
  fi

  local idmap_rc=1
  if declare -F _capbox_idmap_decision >/dev/null 2>&1; then
    idmap_rc=0
    _capbox_idmap_decision || idmap_rc=$?
  elif declare -F _idmap_enabled >/dev/null 2>&1; then
    idmap_rc=0
    _idmap_enabled || idmap_rc=$?
  fi
  if (( idmap_rc == 2 )); then
    _service_abort 1 "CAPBOX_IDMAP=on 但多 UID 映射不可用" || return $?
  fi
  local _svc_info=0
  if (( _svc_restricted == 1 )) || [[ -n "${svc[PUBLISH]:-}" ]]; then
    _svc_info=1
  fi
  if (( _svc_info == 1 && idmap_rc != 0 )); then
    if declare -F _net_inject_bwrap_info_fd >/dev/null 2>&1; then
      _net_inject_bwrap_info_fd full 3 || {
        _service_abort 1 "无法注入 --info-fd" || return $?
      }
    fi
  fi

  {
    printf 'NAME=%s\n' "$(_shq "$name")"
    printf 'UID=%s\n' "$(_shq "$uid")"
    printf 'GID=%s\n' "$(_shq "$gid")"
    printf 'CWD=%s\n' "$(_shq "$cwd")"
    printf 'CMD=%s\n' "$(_shq "$cmd")"
    printf 'NET=%s\n' "$(_shq "$effective_net")"
    printf 'NET_SESSION=%s\n' "$(_shq "${CAPBOX_NET_SESSION:-}")"
    printf 'RESTART=%s\n' "$(_shq "$restart")"
    printf 'STOP_TIMEOUT=%s\n' "$(_shq "$stop_timeout")"
    printf 'STARTED_AT=%s\n' "$(_shq "$(date -Iseconds 2>/dev/null || date)")"
  } >"$rd/meta.env"

  local sup py bp
  py="$(_service_supervisor_py 2>/dev/null || true)"
  local -a sup_cmd=()
  if [[ -n "$py" ]] && have_cmd python3; then
    rm -f -- "$rd/startup.status" "$rd/supervisor.pid" "$rd/supervisor.pid.child"
    # 写 child argv（NUL 分隔）。多 UID 时由 run-child 内调用 idmap 包装。
    : >"$rd/child.argv"
    local x
    for x in "${full[@]}"; do
      printf '%s\0' "$x" >>"$rd/child.argv"
    done
    if (( idmap_rc == 0 )); then
      cat >"$rd/run-child.sh" <<EOS
#!/usr/bin/env bash
set -euo pipefail
export CAPBOX_DIR=$(printf %q "$CAPBOX_DIR")
export CAPBOX_NET=$(printf %q "$effective_net")
export CAPBOX_NET_SESSION=$(printf %q "${CAPBOX_NET_SESSION:-}")
# shellcheck source=/dev/null
source "\$CAPBOX_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "\$CAPBOX_DIR/lib/idmap.sh"
# shellcheck source=/dev/null
source "\$CAPBOX_DIR/lib/net.sh"
export CAPBOX_NET=$(printf %q "$effective_net")
export CAPBOX_NET_SESSION=$(printf %q "${CAPBOX_NET_SESSION:-}")
ARGV_FILE=$(printf %q "$rd")/child.argv
mapfile -d '' -t args <"\$ARGV_FILE"
if [[ "\${CAPBOX_NET_SESSION:-}" == svc-* ]]; then
  rm -f -- "\$(_net_bridge_ready)"
fi
_idmap_after_map_hook() {
  printf '%s\n' "\$1" >$(printf %q "$rd")/sandbox.pid
  if [[ "\${CAPBOX_NET_SESSION:-}" == svc-* ]]; then
    _net_stop_bridge || true
    _net_start_bridge_for_child "\$1"
  fi
}
_idmap_run_bwrap_argv "\${args[@]}"
EOS
    elif (( _svc_info == 1 )); then
      cat >"$rd/run-child.sh" <<EOS
#!/usr/bin/env bash
set -euo pipefail
export CAPBOX_DIR=$(printf %q "$CAPBOX_DIR")
export CAPBOX_NET=$(printf %q "$effective_net")
export CAPBOX_NET_SESSION=$(printf %q "${CAPBOX_NET_SESSION:-}")
# shellcheck source=/dev/null
source "\$CAPBOX_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "\$CAPBOX_DIR/lib/net.sh"
export CAPBOX_NET=$(printf %q "$effective_net")
export CAPBOX_NET_SESSION=$(printf %q "${CAPBOX_NET_SESSION:-}")
cd $(printf %q "$rd")
ARGV_FILE="\$PWD/child.argv"
INFO="\$PWD/bwrap-info.json"
rm -f -- "\$INFO"
[[ "\$CAPBOX_NET" != restricted ]] || rm -f -- "\$(_net_bridge_ready)"
mapfile -d '' -t args <"\$ARGV_FILE"
"\${args[@]}" 3>"\$INFO" &
bp=\$!
child=""
for _i in \$(seq 1 100); do
  if [[ -s "\$INFO" ]]; then
    child="\$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("child-pid") or "")
except Exception:
    print("")' "\$INFO" 2>/dev/null || true)"
    [[ -n "\$child" ]] && break
  fi
  kill -0 "\$bp" 2>/dev/null || break
  sleep 0.05
done
if [[ -z "\$child" ]]; then
  kill "\$bp" 2>/dev/null || true
  wait "\$bp" 2>/dev/null || true
  exit 1
fi
if [[ "\$CAPBOX_NET" == restricted ]] && ! _net_start_bridge_for_child "\$child"; then
  kill "\$bp" 2>/dev/null || true
  wait "\$bp" 2>/dev/null || true
  exit 1
fi
printf '%s\n' "\$child" >"\$PWD/sandbox.pid"
wait "\$bp"
exit \$?
EOS
    else
      cat >"$rd/run-child.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
ARGV_FILE="$(dirname "$0")/child.argv"
mapfile -d '' -t args <"$ARGV_FILE"
exec "${args[@]}"
EOS
    fi
    chmod +x "$rd/run-child.sh"
    sup_cmd=(
      python3 "$py"
      --name "$name"
      --log "$rd/service.log"
      --pidfile "$rd/supervisor.pid"
      --status-file "$rd/startup.status"
      --ready-timeout "$ready_timeout"
      --restart "$restart"
      --restart-max "$restart_max"
      --restart-backoff "$restart_backoff"
      --stop-timeout "$stop_timeout"
      --health-interval "$health_interval"
      --health-retries "$health_retries"
    )
    if [[ -n "${CAPBOX_SECURITY_SECCOMP_FD_HOLD:-}" ]]; then
      sup_cmd+=(--pass-fd "$CAPBOX_SECURITY_SECCOMP_FD_HOLD")
    fi
    [[ -n "${svc[READY_CMD]:-}" ]] && sup_cmd+=(--ready-cmd "${svc[READY_CMD]}")
    [[ -n "${svc[READY_TCP]:-}" ]] && sup_cmd+=(--ready-tcp "${svc[READY_TCP]}")
    [[ -n "${svc[READY_HTTP]:-}" ]] && sup_cmd+=(--ready-http "${svc[READY_HTTP]}")
    [[ -n "${svc[HEALTH_CMD]:-}" ]] && sup_cmd+=(--health-cmd "${svc[HEALTH_CMD]}")
    # PUBLISH: open 模式无需转发；none/restricted 记录到 meta（port proxy 由 net 管理）
    if [[ -n "${svc[PUBLISH]:-}" ]]; then
      printf 'PUBLISH=%s\n' "$(_shq "${svc[PUBLISH]}")" >>"$rd/meta.env"
    fi
    setsid "${sup_cmd[@]}" -- "$rd/run-child.sh" >>"$rd/service.log" 2>&1 &
    bp=$!
  else
    # 无 supervisor：同一进程里挂桥。idmap 的 hook 在放行 guest 之前运行。
    if (( idmap_rc == 0 )); then
      if (( _svc_restricted == 1 )); then
        rm -f -- "$(_net_bridge_ready)" 2>/dev/null || true
        _idmap_after_map_hook() {
          printf '%s\n' "$1" >"$rd/sandbox.pid"
          _net_stop_bridge || true
          _net_start_bridge_for_child "$1"
        }
      fi
      CAPBOX_IDMAP_SPAWN_LOG="$rd/service.log"
      bp="$(_idmap_spawn_bwrap_argv "${full[@]}")" || {
        unset -f _idmap_after_map_hook
        _service_abort 1 "idmap 启动失败" || return $?
      }
      unset -f _idmap_after_map_hook
    elif (( _svc_restricted == 1 )); then
      local info="$rd/bwrap-info.json" sandboxed=""
      rm -f -- "$info" "$(_net_bridge_ready)" 2>/dev/null || true
      setsid "${full[@]}" 3>"$info" >>"$rd/service.log" 2>&1 &
      bp=$!
      sandboxed="$(_net_wait_info_child "$info" "$bp" || true)"
      if [[ -z "$sandboxed" ]] || ! _net_start_bridge_for_child "$sandboxed"; then
        kill "$bp" 2>/dev/null || true
        wait "$bp" 2>/dev/null || true
        _service_abort 1 "restricted 服务网络桥未就绪" || return $?
      fi
      printf '%s\n' "$sandboxed" >"$rd/sandbox.pid"
    else
      setsid "${full[@]}" >>"$rd/service.log" 2>&1 &
      bp=$!
    fi
    printf '%s\n' "$bp" >"$rd/supervisor.pid"
    _capbox_process_identity "$bp" >"$rd/supervisor.pid.identity" || return 1
  fi
  unset CAPBOX_EXEC_UID_OVERRIDE CAPBOX_EXEC_GID_OVERRIDE

  # 只有宿主 supervisor 能发布 startup.status；仅有 PID 不代表已就绪。
  local i
  local startup_ok=0 startup_state=""
  for (( i=0; i < (ready_timeout + 5) * 10; i++ )); do
    if [[ -n "$py" ]] && have_cmd python3; then
      startup_state="$(cat "$rd/startup.status" 2>/dev/null || true)"
      [[ "$startup_state" == ready ]] && { startup_ok=1; break; }
      [[ "$startup_state" == failed || "$startup_state" == stopped ]] && break
      kill -0 "$bp" 2>/dev/null || break
    else
      # 无 Python supervisor：确认沙箱进程在初始设置后仍存活。
      kill -0 "$bp" 2>/dev/null || break
      (( i >= 3 )) && { startup_ok=1; break; }
    fi
    sleep 0.1
  done
  if (( startup_ok != 1 )); then
    kill -TERM "$bp" 2>/dev/null || true
    _service_abort 1 "服务未就绪或启动失败（见 service logs）" || return $?
  fi
  if [[ -n "${svc[PUBLISH]:-}" ]]; then
    _net_publish_start "$name" "${svc[PUBLISH]}" || i18n_warn svc.publish_failed_start_see_logs
  fi
  unset CAPBOX_NET_SESSION
  _svc_restricted=0
  i18n_info svc.service_started_supervisor_pid_uid_gid name="$name" pid="$(cat "$rd/supervisor.pid")" uid="$uid" gid="$gid"
  if declare -F audit_event >/dev/null 2>&1; then
    audit_event service start "object=$name" "uid=$uid" "detail=restart=$restart" "exit=0" "ms=0"
  fi
  return 0
}

_service_stop() {
  local name="${1:-}"
  [[ -n "$name" ]] || i18n_die 2 svc.usage_capbox_service_stop_name
  local rd pid stop_timeout=10
  rd="$(_service_run_dir "$name")" || return 1
  if [[ -f "$rd/meta.env" ]]; then
    local line
    while IFS= read -r line; do
      if [[ "$line" =~ ^STOP_TIMEOUT=\'([0-9.]+)\'$ ]] || [[ "$line" =~ ^STOP_TIMEOUT=([0-9.]+)$ ]]; then
        stop_timeout="${BASH_REMATCH[1]}"
      fi
    done <"$rd/meta.env"
  fi
  if ! _service_is_running "$name"; then
    i18n_info svc.service_not_running name="$name"
    rm -f "$rd/supervisor.pid" 2>/dev/null || true
    _service_release_net "$name"
    if declare -F _net_publish_stop >/dev/null 2>&1; then
      _net_publish_stop "$name" 2>/dev/null || true
    fi
    return 0
  fi
  pid="$(cat "$rd/supervisor.pid")"
  # 已校验身份的 supervisor 自行停止其子进程组；sandbox.pid 可能过期。
  kill -TERM "$pid" 2>/dev/null || true
  local i max
  # 秒 → 100ms 轮询次数
  max=100
  if [[ "$stop_timeout" =~ ^([0-9]+)([.][0-9]+)?$ ]]; then
    max=$(( ${BASH_REMATCH[1]} * 10 ))
    (( max < 1 )) && max=1
    (( max > 6000 )) && max=6000
  fi
  for i in $(seq 1 "$max"); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    pkill -KILL -P "$pid" 2>/dev/null || true
  fi
  pkill -KILL -f "$rd/guest-run" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$rd/supervisor.pid" "$rd/supervisor.pid.child" "$rd/sandbox.pid"
  _service_release_net "$name"
  if declare -F _net_publish_stop >/dev/null 2>&1; then
    _net_publish_stop "$name" 2>/dev/null || true
  fi
  i18n_info svc.service_stopped name="$name"
  if declare -F audit_event >/dev/null 2>&1; then
    audit_event service stop "object=$name" "exit=0" "ms=0"
  fi
  return 0
}

_service_status() {
  local name="${1:-}"
  [[ -n "$name" ]] || i18n_die 2 svc.usage_capbox_service_status_name
  local rd
  rd="$(_service_run_dir "$name")" || return 1
  if _service_is_running "$name"; then
    printf 'name=%s\nstate=running\nsupervisor_pid=%s\n' "$name" "$(cat "$rd/supervisor.pid")"
    [[ -f "$rd/meta.env" ]] && cat "$rd/meta.env"
    if declare -F _idmap_probe >/dev/null 2>&1; then
      _idmap_probe >/dev/null 2>&1 || true
      printf 'idmap_status=%s\n' "${CAPBOX_IDMAP_STATUS}"
    fi
    return 0
  fi
  printf 'name=%s\nstate=stopped\n' "$name"
  if [[ -f "$rd/service.log" ]]; then
    printf 'last_log=\n'
    tail -n 20 -- "$rd/service.log" 2>/dev/null || true
  fi
  return 0
}

_service_logs() {
  local name="" follow=0 lines=50
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--follow) follow=1; shift ;;
      -n) lines="${2:-50}"; shift 2 || shift ;;
      -n=*) lines="${1#*=}"; shift ;;
      -h|--help) i18n_print help.service.logs; return 0 ;;
      -*) i18n_die 2 svc.service_logs_unknown_option arg="$1" ;;
      *) if [[ -z "$name" ]]; then name="$1"; shift; else i18n_die 2 svc.extra_argument arg="$1"; fi ;;
    esac
  done
  [[ -n "$name" ]] || i18n_die 2 svc.usage_capbox_service_logs_name
  local rd f
  rd="$(_service_run_dir "$name")" || return 1
  f="$rd/service.log"
  [[ -f "$f" ]] || i18n_die 1 svc.no_log f="$f"
  if (( follow == 1 )); then tail -n "$lines" -f -- "$f"
  else tail -n "$lines" -- "$f"; fi
}
