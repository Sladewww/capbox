# shellcheck shell=bash
# =============================================================================
# CapBox - audit.sh
# 统一 JSONL 审计日志（exec / pkg / service / security / resources / net / image）
#
# CAPBOX_AUDIT=off|summary|full   默认 summary（开启但命令可摘要）
# CAPBOX_AUDIT_CMD=summary|full|off  命令字段：摘要 / 原文 / 不写
# 路径：$CAPBOX_DIR/logs/audit.jsonl
# 绝不记录明显的 secret 形态（password=/token=/Authorization: 等）
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
  printf '%s' "$s"
}

_audit_redact() {
  local s="${1-}"
  # 粗粒度脱敏：常见密钥赋值与 Bearer
  s="$(printf '%s' "$s" | sed -E \
    -e 's/(password|passwd|pwd|token|secret|api[_-]?key|authorization)=[^[:space:]]+/\1=***REDACTED***/Ig' \
    -e 's/(Bearer[[:space:]]+)[^[:space:]]+/\1***REDACTED***/Ig')"
  printf '%s' "$s"
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
    full)
      _audit_redact "$cmd"
      ;;
    summary|*)
      # 只保留 argv0 + 参数个数，避免泄露长命令/密钥
      local first rest
      first="${cmd%%[[:space:]]*}"
      rest="${cmd#"$first"}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      local n=0
      if [[ -n "$rest" ]]; then
        # shellcheck disable=SC2206
        local -a _a=($rest)
        n=${#_a[@]}
      fi
      printf '%s (+%s args)' "$(_audit_redact "$first")" "$n"
      ;;
  esac
}

# audit_event KIND STATUS [KEY=VAL ...]
# KIND: exec|pkg|service|security|resources|net|image|snapshot|fs|doctor
# STATUS: ok|fail|warn|skip|start|stop
# 可选键：cmd, exit, ms, object, detail, profile, net, uid
audit_event() {
  _audit_enabled || return 0
  local kind="${1:-}" status="${2:-}"
  shift 2 || true
  [[ -n "$kind" && -n "$status" ]] || return 0

  local dir f ts
  dir="$(dirname "$(_audit_path)")"
  mkdir -p "$dir" 2>/dev/null || return 0
  f="$(_audit_path)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"

  local cmd="" exit_c="" ms="" object="" detail="" profile="" net="" uid=""
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
    esac
  done

  local cmd_out
  cmd_out="$(_audit_cmd_field "$cmd")"

  {
    printf '{'
    printf '"ts":"%s",' "$(_audit_json_escape "$ts")"
    printf '"kind":"%s",' "$(_audit_json_escape "$kind")"
    printf '"status":"%s"' "$(_audit_json_escape "$status")"
    [[ -n "$exit_c" ]] && printf ',"exit":%s' "$exit_c"
    [[ -n "$ms" ]] && printf ',"ms":%s' "$ms"
    [[ -n "$object" ]] && printf ',"object":"%s"' "$(_audit_json_escape "$object")"
    [[ -n "$cmd_out" ]] && printf ',"cmd":"%s"' "$(_audit_json_escape "$cmd_out")"
    [[ -n "$detail" ]] && printf ',"detail":"%s"' "$(_audit_json_escape "$(_audit_redact "$detail")")"
    [[ -n "$profile" ]] && printf ',"profile":"%s"' "$(_audit_json_escape "$profile")"
    [[ -n "$net" ]] && printf ',"net":"%s"' "$(_audit_json_escape "$net")"
    [[ -n "$uid" ]] && printf ',"uid":"%s"' "$(_audit_json_escape "$uid")"
    printf ',"distro":"%s"' "$(_audit_json_escape "${CAPBOX_DISTRO:-}")"
    printf '}\n'
  } >>"$f" 2>/dev/null || true
}

cmd_audit() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    -h|--help|"")
      cat <<'H'
用法: capbox audit <tail|path|clear> [N]

  tail [N]   显示最近 N 条（默认 50）
  path       打印审计文件路径
  clear      清空审计文件（需确认意图：直接执行即清空）

CAPBOX_AUDIT=off|summary|full
CAPBOX_AUDIT_CMD=summary|full|off
H
      return 0
      ;;
    path)
      printf '%s\n' "$(_audit_path)"
      return 0
      ;;
    clear)
      local f="$(_audit_path)"
      : >"$f" 2>/dev/null || die 1 "无法清空 $f"
      log_info "已清空审计日志: $f"
      return 0
      ;;
    tail)
      local n="${1:-50}"
      [[ "$n" =~ ^[0-9]+$ ]] || die 2 "audit tail: N 必须是非负整数"
      local f="$(_audit_path)"
      [[ -f "$f" ]] || { printf '(无审计日志)\n'; return 0; }
      tail -n "$n" -- "$f"
      return 0
      ;;
    *)
      die 2 "audit: 未知子命令 $sub（tail|path|clear）"
      ;;
  esac
}


cmd_metrics() {
  local json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help)
        printf '用法: capbox metrics [--json]\n  显示 cgroup/磁盘/安全档/网络等真实探测结果（不编造已限额）。\n'
        return 0
        ;;
      *) die 2 "metrics: 未知选项 $1" ;;
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
