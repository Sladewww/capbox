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
      CMD|UID|GID|USER|CWD|PIDFILE|LOG|NET|REQUIRE_IDMAP|\
      READY_CMD|READY_TCP|READY_HTTP|READY_TIMEOUT|\
      HEALTH_CMD|HEALTH_INTERVAL|HEALTH_RETRIES|\
      RESTART|RESTART_MAX|RESTART_BACKOFF|STOP_TIMEOUT|\
      DEPENDS_ON|PUBLISH) ;;
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
  CAPBOX_BWRAP_NO_DIE_WITH_PARENT=1
  export CAPBOX_BWRAP_NO_DIE_WITH_PARENT
  mapfile -t args < <(build_bwrap_args oneshot "$cwd")
  ((${#args[@]} > 0)) || die 4 "无法构造 bwrap 参数"
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

  if declare -F _security_wrap_argv >/dev/null 2>&1; then
    _security_wrap_argv full || true
  fi
  if declare -F _resources_wrap_argv >/dev/null 2>&1; then
    _resources_wrap_argv full || {
      unset CAPBOX_EXEC_UID_OVERRIDE CAPBOX_EXEC_GID_OVERRIDE
      _service_diagnose "$name" "资源限额无法应用"
      return 1
    }
  fi

  {
    printf 'NAME=%s\n' "$(_shq "$name")"
    printf 'UID=%s\n' "$(_shq "$uid")"
    printf 'GID=%s\n' "$(_shq "$gid")"
    printf 'CWD=%s\n' "$(_shq "$cwd")"
    printf 'CMD=%s\n' "$(_shq "$cmd")"
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
    if declare -F _idmap_enabled >/dev/null 2>&1 && _idmap_enabled; then
      cat >"$rd/run-child.sh" <<EOS
#!/usr/bin/env bash
set -euo pipefail
CAPBOX_DIR=$(printf %q "$CAPBOX_DIR")
# shellcheck source=/dev/null
source "\$CAPBOX_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "\$CAPBOX_DIR/lib/idmap.sh"
ARGV_FILE="$(printf %q "$rd")/child.argv"
mapfile -d '' -t args <"\$ARGV_FILE"
_idmap_run_bwrap_argv "\${args[@]}"
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
    # 无 supervisor：回退旧行为
    if declare -F _idmap_enabled >/dev/null 2>&1 && _idmap_enabled; then
      CAPBOX_IDMAP_SPAWN_LOG="$rd/service.log"
      bp="$(_idmap_spawn_bwrap_argv "${full[@]}")" || {
        unset CAPBOX_EXEC_UID_OVERRIDE CAPBOX_EXEC_GID_OVERRIDE
        _service_diagnose "$name" "idmap 启动失败"
        return 1
      }
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
    _service_diagnose "$name" "进程启动后立即退出"
    return 1
  fi
  # ready 等待（supervisor 内部也会等；这里再给一点时间）
  if [[ -n "${svc[READY_CMD]:-}${svc[READY_TCP]:-}${svc[READY_HTTP]:-}" ]]; then
    sleep 0.3
  fi
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
    if declare -F _net_publish_stop >/dev/null 2>&1; then
      _net_publish_stop "$name" 2>/dev/null || true
    fi
    return 0
  fi
  pid="$(cat "$rd/supervisor.pid")"
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
  rm -f "$rd/supervisor.pid" "$rd/supervisor.pid.child"
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
