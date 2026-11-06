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
# 状态目录（宿主）：$CAPBOX_RUN_DIR/services/<name>/
# =============================================================================

_service_dir() { printf '%s' "${CAPBOX_DIR}/services"; }
_service_run_dir() { printf '%s' "${CAPBOX_RUN_DIR}/services/${1:-}"; }

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
  _service_valid_name "$name" || { log_err "服务名非法: $name"; return 2; }
  local f="$(_service_dir)/${name}.env"
  [[ -f "$f" ]] || { log_err "服务定义不存在: $f"; return 1; }
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
        log_err "服务 $name: $key 值含非法展开符"
        return 2
      fi
    fi
    if [[ "$raw" == *$'\n'* ]]; then
      log_err "服务 $name: $key 值含换行"
      return 2
    fi
    if _service_reserved_key "$key"; then
      _out["$key"]="$raw"
    else
      _env["$key"]="$raw"
    fi
  done <"$f"
  [[ -n "${_out[CMD]:-}" ]] || { log_err "服务 $name: 缺少 CMD"; return 2; }
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
  rd="$(_service_run_dir "$name")"
  rootfs="${CAPBOX_ROOTFS:-}"
  log_err "服务 '$name' 诊断: $reason"
  if declare -F _idmap_probe >/dev/null 2>&1; then
    _idmap_probe >/dev/null 2>&1 || true
    log_err "  idmap: ${CAPBOX_IDMAP_STATUS:-?} — ${CAPBOX_IDMAP_DETAIL:-}"
  fi
  if have_cmd ss; then
    log_err "  监听端口(ss -lntu | head):"
    ss -lntu 2>/dev/null | head -n 8 | while IFS= read -r L; do log_err "    $L"; done
  fi
  if [[ -n "$rootfs" ]]; then
    for d in /var/lib /var/log /run /etc; do
      if [[ -d "$rootfs$d" ]]; then log_err "  rootfs$d: 存在"
      else log_err "  rootfs$d: 缺失"; fi
    done
  fi
  if [[ -f "$rd/service.log" ]]; then
    log_err "  最近日志:"
    tail -n 15 -- "$rd/service.log" 2>/dev/null | while IFS= read -r L; do log_err "    $L"; done
  fi
}

cmd_service() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    -h|--help|"")
      cat <<'HELP'
用法: capbox service <start|stop|status|logs|list> NAME [options]

  start NAME     按 .capbox/services/NAME.env 启动（独立 bwrap）
  stop NAME      停止服务
  status NAME    查看状态与诊断
  logs NAME [-f] [-n N]
  list           列出已定义服务

示例 (.capbox/services/nginx.env):
  CMD='nginx -g "daemon off;"'
  USER=www-data
  CWD=/
  READY_TCP=127.0.0.1:18080
  HEALTH_INTERVAL=5
  RESTART=on-failure
  RESTART_MAX=3
  STOP_TIMEOUT=10
  DEPENDS_ON=other
HELP
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
    *) die 2 "service: 未知子命令 $sub（start|stop|status|logs|list）" ;;
  esac
}

_service_is_running() {
  local name="${1:-}" rd pid
  rd="$(_service_run_dir "$name")"
  [[ -f "$rd/supervisor.pid" ]] || return 1
  pid="$(cat "$rd/supervisor.pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
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
    _service_valid_name "$d" || die 2 "DEPENDS_ON 非法服务名: $d"
    if ! _service_is_running "$d"; then
      log_info "依赖 $d 未运行，先启动"
      _service_start "$d" || {
        log_err "依赖服务 $d 启动失败"
        return 1
      }
    fi
  done
  return 0
}

_service_check_id() {
  local v="${1:-}" label="${2:-id}" who="${3:-}" n
  [[ "$v" =~ ^[0-9]+$ ]] || {
    log_err "服务 ${who}: ${label} 不是十进制数字: ${v:-<empty>}"
    return 2
  }
  n="$v"
  while [[ "$n" == 0* && ${#n} -gt 1 ]]; do
    n="${n#0}"
  done
  if (( ${#n} > 10 )) || { (( ${#n} == 10 )) && [[ "$n" > "4294967295" ]]; }; then
    log_err "服务 ${who}: ${label} 超出 32 位范围: $v"
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
  rd="$(_service_run_dir "$who")"
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
  [[ -n "$name" ]] || die 2 "用法: capbox service start NAME"
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) cmd_service --help; return 0 ;;
      *) die 2 "service start: 未知选项 $1" ;;
    esac
  done

  require_rootfs
  local -A svc=() svc_env=()
  _service_load "$name" svc svc_env || return $?

  if _service_is_running "$name"; then
    log_info "服务 $name 已在运行（pid $(cat "$(_service_run_dir "$name")/supervisor.pid")）"
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

  [[ "$stop_timeout" =~ ^[0-9]+([.][0-9]+)?$ ]] || die 2 "STOP_TIMEOUT 非法"
  [[ "$restart_max" =~ ^[0-9]+$ ]] || die 2 "RESTART_MAX 非法"
  case "$restart" in no|on-failure|always) ;; *) die 2 "RESTART 只能是 no|on-failure|always" ;; esac

  if [[ -n "$user" ]]; then
    local resolved
    if declare -F _idmap_resolve_user >/dev/null 2>&1 && resolved="$(_idmap_resolve_user "$user")"; then
      if [[ "$resolved" == *:* ]]; then
        uid="${resolved%%:*}"; gid="${resolved#*:}"
      else
        uid="$resolved"; : "${gid:=$uid}"
      fi
    else
      log_err "服务 $name: 无法在 guest passwd 解析 USER=$user"
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
      *) die 2 "服务 $name: NET 非法: $net" ;;
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
      ready_guest="$(_guest_workspace_path "$(_net_bridge_ready)")"
    fi
    [[ -n "$ready_guest" ]] || {
      _service_abort 1 "guest 看不到 bridge ready 路径" || return $?
    }
  else
    unset CAPBOX_NET_SESSION
  fi

  local rd
  rd="$(_service_run_dir "$name")"
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
  if (( _svc_restricted == 1 && idmap_rc != 0 )); then
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
  _idmap_after_map_hook() {
    printf '%s\n' "\$1" >$(printf %q "$rd")/sandbox.pid
    _net_stop_bridge || true
    _net_start_bridge_for_child "\$1"
  }
fi
_idmap_run_bwrap_argv "\${args[@]}"
EOS
    elif (( _svc_restricted == 1 )); then
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
rm -f -- "\$INFO" "\$(_net_bridge_ready)"
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
if [[ -z "\$child" ]] || ! _net_start_bridge_for_child "\$child"; then
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
      --ready-timeout "$ready_timeout"
      --restart "$restart"
      --restart-max "$restart_max"
      --restart-backoff "$restart_backoff"
      --stop-timeout "$stop_timeout"
      --health-interval "$health_interval"
      --health-retries "$health_retries"
    )
    [[ -n "${svc[READY_CMD]:-}" ]] && sup_cmd+=(--ready-cmd "${svc[READY_CMD]}")
    [[ -n "${svc[READY_TCP]:-}" ]] && sup_cmd+=(--ready-tcp "${svc[READY_TCP]}")
    [[ -n "${svc[READY_HTTP]:-}" ]] && sup_cmd+=(--ready-http "${svc[READY_HTTP]}")
    [[ -n "${svc[HEALTH_CMD]:-}" ]] && sup_cmd+=(--health-cmd "${svc[HEALTH_CMD]}")
    # PUBLISH: open 模式无需转发；none/restricted 记录到 meta（port proxy 由 net 管理）
    if [[ -n "${svc[PUBLISH]:-}" ]]; then
      printf 'PUBLISH=%s\n' "$(_shq "${svc[PUBLISH]}")" >>"$rd/meta.env"
      if declare -F _net_publish_start >/dev/null 2>&1; then
        _net_publish_start "$name" "${svc[PUBLISH]}" || log_warn "PUBLISH 启动失败（见日志）"
      fi
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
  fi
  unset CAPBOX_EXEC_UID_OVERRIDE CAPBOX_EXEC_GID_OVERRIDE

  # supervisor 自己写 pidfile；稍等
  local i
  for i in $(seq 1 30); do
    [[ -f "$rd/supervisor.pid" ]] && kill -0 "$(cat "$rd/supervisor.pid")" 2>/dev/null && break
    sleep 0.1
  done
  if [[ ! -f "$rd/supervisor.pid" ]] || ! kill -0 "$(cat "$rd/supervisor.pid")" 2>/dev/null; then
    _service_abort 1 "进程启动后立即退出" || return $?
  fi
  # ready 等待（supervisor 内部也会等；这里再给一点时间）
  if [[ -n "${svc[READY_CMD]:-}${svc[READY_TCP]:-}${svc[READY_HTTP]:-}" ]]; then
    sleep 0.3
  fi
  unset CAPBOX_NET_SESSION
  _svc_restricted=0
  log_info "服务 $name 已启动（supervisor pid $(cat "$rd/supervisor.pid"), uid=$uid gid=$gid）"
  if declare -F audit_event >/dev/null 2>&1; then
    audit_event service start "object=$name" "uid=$uid" "detail=restart=$restart"
  fi
  return 0
}

_service_stop() {
  local name="${1:-}"
  [[ -n "$name" ]] || die 2 "用法: capbox service stop NAME"
  local rd pid stop_timeout=10
  rd="$(_service_run_dir "$name")"
  if [[ -f "$rd/meta.env" ]]; then
    local line
    while IFS= read -r line; do
      if [[ "$line" =~ ^STOP_TIMEOUT=\'([0-9.]+)\'$ ]] || [[ "$line" =~ ^STOP_TIMEOUT=([0-9.]+)$ ]]; then
        stop_timeout="${BASH_REMATCH[1]}"
      fi
    done <"$rd/meta.env"
  fi
  if ! _service_is_running "$name"; then
    log_info "服务 $name 未在运行"
    rm -f "$rd/supervisor.pid" 2>/dev/null || true
    _service_release_net "$name"
    if declare -F _net_publish_stop >/dev/null 2>&1; then
      _net_publish_stop "$name" 2>/dev/null || true
    fi
    return 0
  fi
  pid="$(cat "$rd/supervisor.pid")"
  if [[ -f "$rd/sandbox.pid" ]]; then
    local sp
    sp="$(tr -d '[:space:]' <"$rd/sandbox.pid" || true)"
    if [[ "$sp" =~ ^[0-9]+$ ]]; then
      kill -TERM "$sp" 2>/dev/null || true
    fi
  fi
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
  log_info "服务 $name 已停止"
  if declare -F audit_event >/dev/null 2>&1; then
    audit_event service stop "object=$name"
  fi
  return 0
}

_service_status() {
  local name="${1:-}"
  [[ -n "$name" ]] || die 2 "用法: capbox service status NAME"
  local rd
  rd="$(_service_run_dir "$name")"
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
      -h|--help) printf '用法: capbox service logs NAME [-f] [-n N]\n'; return 0 ;;
      -*) die 2 "service logs: 未知选项 $1" ;;
      *) if [[ -z "$name" ]]; then name="$1"; shift; else die 2 "多余参数 $1"; fi ;;
    esac
  done
  [[ -n "$name" ]] || die 2 "用法: capbox service logs NAME"
  local f="$(_service_run_dir "$name")/service.log"
  [[ -f "$f" ]] || die 1 "无日志: $f"
  if (( follow == 1 )); then tail -n "$lines" -f -- "$f"
  else tail -n "$lines" -- "$f"; fi
}
