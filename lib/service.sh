# shellcheck shell=bash
# =============================================================================
# CapBox - service.sh
# 配置化服务：start / stop / status / logs
#
# 服务定义：.capbox/services/<name>.env（纯 KEY=value，不 source）
#   CMD='nginx -g "daemon off;"'     # 必填
#   UID=33  GID=33  USER=www-data    # 可选
#   CWD=/  PIDFILE=  LOG=  NET=
#   REQUIRE_IDMAP=0                  # 1=需要 multi 映射
#
# 状态目录（宿主）：$CAPBOX_RUN_DIR/services/<name>/
# =============================================================================

_service_dir() { printf '%s' "${CAPBOX_DIR}/services"; }
_service_run_dir() { printf '%s' "${CAPBOX_RUN_DIR}/services/${1:-}"; }

_service_valid_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]]
}

_service_load() {
  local name="${1:-}"
  local -n _out="$2"
  _out=()
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
    case "$key" in
      CMD|UID|GID|USER|CWD|PIDFILE|LOG|NET|REQUIRE_IDMAP) ;;
      *) log_warn "服务 $name: 忽略未知键 $key"; continue ;;
    esac
    if [[ "$raw" == \'*\' && ${#raw} -ge 2 ]]; then
      raw="${raw:1:${#raw}-2}"
    elif [[ "$raw" == \"*\" && ${#raw} -ge 2 ]]; then
      raw="${raw:1:${#raw}-2}"
      if [[ "$raw" =~ [\$\`\\] ]]; then
        log_err "服务 $name: $key 值含非法展开符"
        return 2
      fi
    fi
    _out["$key"]="$raw"
  done <"$f"
  [[ -n "${_out[CMD]:-}" ]] || { log_err "服务 $name: 缺少 CMD"; return 2; }
  return 0
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
  local -A svc=()
  _service_load "$name" svc || return $?

  if _service_is_running "$name"; then
    log_info "服务 $name 已在运行（pid $(cat "$(_service_run_dir "$name")/supervisor.pid")）"
    return 0
  fi

  local uid="${svc[UID]:-}" gid="${svc[GID]:-}" user="${svc[USER]:-}"
  local cwd="${svc[CWD]:-/}" require_idmap="${svc[REQUIRE_IDMAP]:-0}"
  local net="${svc[NET]:-}"

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

  local rd
  rd="$(_service_run_dir "$name")"
  mkdir -p "$rd" || die 1 "无法创建 $rd"

  export CAPBOX_EXEC_UID_OVERRIDE="$uid"
  export CAPBOX_EXEC_GID_OVERRIDE="$gid"

  local cmd="${svc[CMD]}"
  local wrap
  wrap="mkdir -p /run/capbox-svc 2>/dev/null || true; echo \$\$ > /run/capbox-svc/${name}.pid; cd $(printf %q "$cwd") || exit 1; exec /bin/sh -c $(printf %q "$cmd")"

  local -a args=() full=()
  # 服务必须活过 `capbox service start` 进程本身，故去掉 --die-with-parent
  CAPBOX_BWRAP_NO_DIE_WITH_PARENT=1
  export CAPBOX_BWRAP_NO_DIE_WITH_PARENT
  mapfile -t args < <(build_bwrap_args oneshot "$cwd")
  ((${#args[@]} > 0)) || die 4 "无法构造 bwrap 参数"
  # 双保险：过滤残留
  local -a filtered=()
  local a
  for a in "${args[@]}"; do
    [[ "$a" == "--die-with-parent" ]] && continue
    filtered+=("$a")
  done
  args=("${filtered[@]}")
  mkdir -p "$rd/guest-run" 2>/dev/null || true
  args+=(--bind "$rd/guest-run" /run)
  full=("$CAPBOX_BWRAP" "${args[@]}" -- /bin/sh -c "$wrap")

  {
    printf 'NAME=%s\n' "$(_shq "$name")"
    printf 'UID=%s\n' "$(_shq "$uid")"
    printf 'GID=%s\n' "$(_shq "$gid")"
    printf 'CWD=%s\n' "$(_shq "$cwd")"
    printf 'CMD=%s\n' "$(_shq "$cmd")"
    printf 'STARTED_AT=%s\n' "$(_shq "$(date -Iseconds 2>/dev/null || date)")"
  } >"$rd/meta.env"

  local bp
  if declare -F _idmap_enabled >/dev/null 2>&1 && _idmap_enabled; then
    CAPBOX_IDMAP_SPAWN_LOG="$rd/service.log"
    bp="$(_idmap_spawn_bwrap_argv "${full[@]}")" || {
      unset CAPBOX_EXEC_UID_OVERRIDE CAPBOX_EXEC_GID_OVERRIDE
      _service_diagnose "$name" "idmap 启动失败"
      return 1
    }
  else
    # setsid：独立会话，便于 stop 时按进程组回收
    setsid "${full[@]}" >>"$rd/service.log" 2>&1 &
    bp=$!
  fi
  unset CAPBOX_EXEC_UID_OVERRIDE CAPBOX_EXEC_GID_OVERRIDE

  printf '%s\n' "$bp" >"$rd/supervisor.pid"
  sleep 0.3
  if ! kill -0 "$bp" 2>/dev/null; then
    wait "$bp" 2>/dev/null || true
    _service_diagnose "$name" "进程启动后立即退出"
    rm -f "$rd/supervisor.pid"
    return 1
  fi
  log_info "服务 $name 已启动（supervisor pid $bp, uid=$uid gid=$gid）"
  return 0
}

_service_stop() {
  local name="${1:-}"
  [[ -n "$name" ]] || die 2 "用法: capbox service stop NAME"
  local rd pid
  rd="$(_service_run_dir "$name")"
  if ! _service_is_running "$name"; then
    log_info "服务 $name 未在运行"
    rm -f "$rd/supervisor.pid" 2>/dev/null || true
    return 0
  fi
  pid="$(cat "$rd/supervisor.pid")"
  # 先杀进程组/子树，再按 guest-run 路径扫尾（防 idmap 子进程漏网）
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  pkill -TERM -P "$pid" 2>/dev/null || true
  pkill -TERM -f "$rd/guest-run" 2>/dev/null || true
  local i
  for i in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    pkill -KILL -P "$pid" 2>/dev/null || true
  fi
  pkill -KILL -f "$rd/guest-run" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$rd/supervisor.pid"
  log_info "服务 $name 已停止"
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
