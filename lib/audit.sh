# shellcheck shell=bash
# =============================================================================
# CapBox - audit.sh
# 统一 JSONL 审计日志（exec / pkg / service / security / resources / net / image）
#
# CAPBOX_AUDIT=off|summary|full   默认 summary（开启；cmd 记脱敏后的完整参数）
# CAPBOX_AUDIT_CMD=summary|full|off  命令字段：脱敏完整参数 / 同 summary / 不写
#   默认不把命令 stdout/stderr 写入 audit.jsonl；
#   只有 CAPBOX_AUDIT=full 才允许写入封顶后的脱敏 output 字段。
# 路径：$CAPBOX_DIR/logs/audit.jsonl
# 脱敏：password=/Bearer，以及 --password x、--password=x 这类长选项。
# 短选项只走明确的口令类允许列表（当前为空，不加 -p）。
# =============================================================================

_audit_enabled() {
  case "${CAPBOX_AUDIT:-summary}" in
    0|off|false|no|NONE|none) return 1 ;;
    *) return 0 ;;
  esac
}

_audit_path() {
  printf '%s' "${CAPBOX_DIR:-}/logs/audit.jsonl"
}

_audit_json_escape() {
  # 最小 JSON 字符串转义（不经 python，避免热路径依赖）
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  local code char escaped
  for ((code=1; code<32; code++)); do
    printf -v escaped '%02x' "$code"
    printf -v char '%b' "\x$escaped"
    s="${s//"$char"/\\u00$escaped}"
  done
  printf '%s' "$s"
}

_audit_secret_long_names='password|passwd|pwd|token|secret|api[_-]?key|authorization'

# CapBox 自身目前没有口令类短选项。列表先空，不要把 -p 加进去
# （exec 里的 -p 经常是端口或路径）。
_AUDIT_SECRET_SHORT_OPTS=()

_audit_redact() {
  local s="${1-}"
  local names="${_audit_secret_long_names}"
  local script
  # 同时覆盖未加引号、以及 join_cmd_str 生成的 'arg' / "arg" 形式。
  script=$(cat <<'SED'
s/(^|[[:space:]])(--(__NAMES__))=([^[:space:]'"]+)/\1\2=***REDACTED***/Ig
s/(^|[[:space:]])('--(__NAMES__)=)[^']*'/\1\2***REDACTED***'/Ig
s/(^|[[:space:]])("--(__NAMES__)=)[^"]*"/\1\2***REDACTED***"/Ig
s/(^|[[:space:]])(--(__NAMES__))[[:space:]]+[^[:space:]'"]+/\1\2 ***REDACTED***/Ig
s/(^|[[:space:]])('--(__NAMES__)')[[:space:]]+('[^']*'|"[^"]*"|[^[:space:]]+)/\1\2 ***REDACTED***/Ig
s/(^|[[:space:]])("--(__NAMES__)")[[:space:]]+('[^']*'|"[^"]*"|[^[:space:]]+)/\1\2 ***REDACTED***/Ig
s/(__NAMES__)=([^[:space:]'"]+)/\1=***REDACTED***/Ig
s/(Bearer[[:space:]]+)[^[:space:]]+/\1***REDACTED***/Ig
SED
)
  script="${script//__NAMES__/${names}}"
  s="$(printf '%s' "$s" | sed -E -f <(printf '%s\n' "$script"))"
  printf '%s' "$s"
}

_audit_truncate() {
  local s="${1-}" max="${2:-256}"
  local n=${#s}
  if (( n > max )); then
    printf '%s...' "${s:0:max}"
  else
    printf '%s' "$s"
  fi
}

_audit_now_ms() {
  date +%s%3N 2>/dev/null || date +%s
}

_audit_cmd_field() {
  local cmd="${1-}"
  local mode="${CAPBOX_AUDIT_CMD:-}"
  if [[ -z "$mode" ]]; then
    case "${CAPBOX_AUDIT:-summary}" in
      full) mode=full ;;
      *) mode=summary ;;
    esac
  fi
  case "$mode" in
    off|0|none) printf '' ; return 0 ;;
    full|summary|*)
      # summary 与 full 都记脱敏后的完整参数，不再写成 argv0 (+N args)
      _audit_redact "$cmd"
      ;;
  esac
}

# audit_event KIND STATUS [KEY=VAL ...]
# KIND: exec|pkg|init|shell|doctor|upgrade|task|mcp|recipe|service|security|resources|net|image|snapshot|fs
# STATUS: ok|fail|warn|skip|start|stop
# 可选键：cmd, exit, ms, object, detail, profile, net, uid, output
# detail 失败时用，截断约 256 字。output 仅 CAPBOX_AUDIT=full 时写入，且封顶脱敏。
audit_event() {
  _audit_enabled || return 0
  local kind="${1:-}" status="${2:-}"
  shift 2 || true
  [[ -n "$kind" && -n "$status" ]] || return 0

  local dir f ts
  f="${_audit_task_path:-$(_audit_path)}"
  dir="$(dirname "$f")"
  if [[ -z "${_audit_task_path:-}" ]]; then
    mkdir -p "$dir" 2>/dev/null || return 0
  fi
  if [[ -L "$dir" || -L "$f" || ( -e "$f" && ! -f "$f" ) ]]; then
    i18n_err audit.audit_log_must_regular_file_refusing_write f="$f"
    return 1
  fi
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date)"

  local cmd="" exit_c="" ms="" object="" detail="" profile="" net="" uid="" output=""
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    case "$k" in
      cmd) cmd="$v" ;;
      exit|rc) exit_c="$v" ;;
      ms|elapsed_ms) ms="$v" ;;
      object|obj) object="$v" ;;
      detail) detail="$v" ;;
      profile) profile="$v" ;;
      net) net="$v" ;;
      uid) uid="$v" ;;
      output|out) output="$v" ;;
    esac
  done

  local cmd_out
  cmd_out="$(_audit_cmd_field "$cmd")"

  local record
  record="$(
    printf '{'
    printf '"ts":"%s",' "$(_audit_json_escape "$ts")"
    printf '"kind":"%s",' "$(_audit_json_escape "$kind")"
    printf '"status":"%s"' "$(_audit_json_escape "$status")"
    if [[ "${_audit_task_id:-}" =~ ^[0-9a-f]{32}$ ]]; then
      printf ',"task_id":"%s"' "$_audit_task_id"
    fi
    [[ -n "$exit_c" ]] && printf ',"exit":%s' "$exit_c"
    [[ -n "$ms" ]] && printf ',"ms":%s' "$ms"
    [[ -n "$object" ]] && printf ',"object":"%s"' "$(_audit_json_escape "$object")"
    [[ -n "$cmd_out" ]] && printf ',"cmd":"%s"' "$(_audit_json_escape "$cmd_out")"
    [[ -n "$detail" ]] && printf ',"detail":"%s"' "$(_audit_json_escape "$(_audit_truncate "$(_audit_redact "$detail")" 256)")"
    [[ -n "$profile" ]] && printf ',"profile":"%s"' "$(_audit_json_escape "$profile")"
    [[ -n "$net" ]] && printf ',"net":"%s"' "$(_audit_json_escape "$net")"
    [[ -n "$uid" ]] && printf ',"uid":"%s"' "$(_audit_json_escape "$uid")"
    if [[ -n "$output" && "${CAPBOX_AUDIT:-summary}" == "full" ]]; then
      printf ',"output":"%s"' "$(_audit_json_escape "$(_audit_truncate "$(_audit_redact "$output")" 2048)")"
    fi
    printf ',"distro":"%s"' "$(_audit_json_escape "${CAPBOX_DISTRO:-}")"
    printf '}\n'
  )"
  if [[ -n "${_audit_task_path:-}" ]]; then
    printf '%s\n' "$record" | python3 "${BASH_SOURCE[0]%/*}/audit_store.py" "$f" 2>/dev/null || true
  else
    printf '%s\n' "$record" >>"$f" 2>/dev/null || true
  fi
}

# audit_command KIND RC T0 [KEY=VAL ...]
# 按退出码写成 ok/fail，并补上 exit 与 ms（T0 为 _audit_now_ms 的起点）。
audit_command() {
  local kind="${1:-}" rc="${2:-0}" t0="${3:-}"
  shift 3 || true
  [[ -n "$kind" ]] || return 0
  declare -F audit_event >/dev/null 2>&1 || return 0
  local status=ok
  [[ "$rc" == "0" ]] || status=fail
  local t1 ms=""
  if [[ -n "$t0" ]]; then
    t1="$(_audit_now_ms)"
    ms=$((10#${t1} - 10#${t0}))
    (( ms < 0 )) && ms=0
  fi
  local -a kv=( "exit=$rc" )
  [[ -n "$ms" ]] && kv+=( "ms=$ms" )
  audit_event "$kind" "$status" "${kv[@]}" "$@"
}

cmd_audit() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    -h|--help|"")
      i18n_print help.audit
      return 0
      ;;
    path)
      printf '%s\n' "$(_audit_path)"
      return 0
      ;;
    report|query)
      need_cmd python3
      local report_lib="${BASH_SOURCE[0]%/*}" private=""
      if [[ " $* " == *" --task-id "* || " $* " == *" --task-id="* ]]; then
        private="$(_capbox_host_state_dir)" || private=""
      fi
      env "CAPBOX_AUDIT_REPORT_SOURCE=$(_audit_path)" \
        "CAPBOX_AUDIT_REPORT_WORKSPACE=$CAPBOX_WORKSPACE" \
        "CAPBOX_AUDIT_REPORT_PRIVATE=$private" \
        python3 "$report_lib/audit-report.py" "$sub" "$@"
      ;;
    clear)
      local f="$(_audit_path)"
      : >"$f" 2>/dev/null || i18n_die 1 audit.unable_truncate f="$f"
      i18n_info audit.cleared_audit_log f="$f"
      return 0
      ;;
    tail)
      local n="${1:-50}"
      [[ "$n" =~ ^[0-9]+$ ]] || i18n_die 2 audit.audit_tail_n_must_non_negative_integer
      local f="$(_audit_path)"
      [[ -f "$f" ]] || { printf '%s\n' "$(i18n_get audit.no_log)"; return 0; }
      tail -n "$n" -- "$f"
      return 0
      ;;
    *)
      i18n_die 2 audit.audit_unknown_subcommand_report_tail_path_clear sub="$sub"
      ;;
  esac
}


cmd_metrics() {
  local json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help)
        i18n_print help.metrics
        return 0
        ;;
      *) i18n_die 2 audit.metrics_unknown_option arg="$1" ;;
    esac
  done
  if (( json == 1 )); then
    if declare -F _resources_metrics_json >/dev/null 2>&1; then
      _resources_metrics_json
    else
      printf '{"error":"resources module missing"}\n'
    fi
    return 0
  fi
  printf 'security_profile=%s\n' "${CAPBOX_SECURITY_PROFILE:-compat}"
  printf 'net=%s\n' "${CAPBOX_NET:-open}"
  printf 'rootfs_ro=%s\n' "${CAPBOX_ROOTFS_RO:-0}"
  printf 'resources_mode=%s\n' "${CAPBOX_RESOURCES_MODE:-warn}"
  if declare -F _resources_probe_cgroup >/dev/null 2>&1; then
    _resources_probe_cgroup || true
    printf 'cgroup_status=%s\n' "${CAPBOX_CGROUP_STATUS:-}"
    printf 'cgroup_detail=%s\n' "${CAPBOX_CGROUP_DETAIL:-}"
  fi
  if declare -F _resources_probe_disk >/dev/null 2>&1; then
    _resources_probe_disk || true
    printf 'disk_status=%s\n' "${CAPBOX_DISK_STATUS:-}"
    printf 'disk_detail=%s\n' "${CAPBOX_DISK_DETAIL:-}"
  fi
  if declare -F _resources_any_configured >/dev/null 2>&1 && _resources_any_configured; then
    printf 'memory_max=%s applied=%s\n' "${CAPBOX_MEMORY_MAX:-}" "${CAPBOX_RESOURCES_APPLIED_MEMORY:-}"
    printf 'cpu_max=%s applied=%s\n' "${CAPBOX_CPU_MAX:-}" "${CAPBOX_RESOURCES_APPLIED_CPU:-}"
    printf 'pids_max=%s applied=%s\n' "${CAPBOX_PIDS_MAX:-}" "${CAPBOX_RESOURCES_APPLIED_PIDS:-}"
  else
    printf 'limits=none_configured\n'
  fi
  # 运行中服务
  if declare -F _service_dir >/dev/null 2>&1; then
    local d f base
    d="$(_service_dir)"
    if [[ -d "$d" ]]; then
      for f in "$d"/*.env; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f" .env)"
        if declare -F _service_is_running >/dev/null 2>&1 && _service_is_running "$base"; then
          printf 'service.%s=running pid=%s\n' "$base" "$(cat "$(_service_run_dir "$base")/supervisor.pid" 2>/dev/null || echo '?')"
        else
          printf 'service.%s=stopped\n' "$base"
        fi
      done
    fi
  fi
  return 0
}
