# shellcheck shell=bash
# =============================================================================
# CapBox - resources.sh
# CPU / 内存 / PIDs /（诚实声明的）磁盘限额。
#
# CAPBOX_MEMORY_MAX  例: 512M 512Mi 1G 268435456
# CAPBOX_PIDS_MAX    例: 256
# CAPBOX_CPU_MAX     例: 50%  或 cgroup 原样 "50000 100000"
# CAPBOX_DISK_MAX    例: 1G — **仅当**能创建私有 sparse loop+挂载时才兑现；否则明确 unavailable
# CAPBOX_RESOURCES_MODE=warn|require
#   warn    （默认）cgroup 不可用时 WARN；MEMORY 可降级 prlimit RLIMIT_AS（近似，非 memory.max）
#   require （fail-closed）任一已配置限额无法按 cgroup（或声明的精确机制）兑现则硬失败
#
# 注意：
#   * RLIMIT_NPROC 按 UID 全局计数，绝不冒充 PIDs。
#   * 绝不把 prlimit 宣传成精确 cgroup memory.max。
#   * 本环境若无法写宿主 cgroup，doctor/status 会给出证据路径与权限错误。
# =============================================================================

_resources_parse_bytes() {
  local raw="${1:-}" n unit
  [[ -n "$raw" ]] || return 1
  if [[ "$raw" =~ ^([0-9]+)([KkMmGg]i?[Bb]?)?$ ]]; then
    n="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2],,}"
    case "$unit" in
      "" | b) printf '%s' "$n" ;;
      k | kb) printf '%s' $((n * 1000)) ;;
      ki | kib) printf '%s' $((n * 1024)) ;;
      m | mb) printf '%s' $((n * 1000 * 1000)) ;;
      mi | mib) printf '%s' $((n * 1024 * 1024)) ;;
      g | gb) printf '%s' $((n * 1000 * 1000 * 1000)) ;;
      gi | gib) printf '%s' $((n * 1024 * 1024 * 1024)) ;;
      *) return 1 ;;
    esac
    return 0
  fi
  return 1
}

_resources_parse_cpu_max() {
  local raw="${1:-}"
  if [[ "$raw" =~ ^([0-9]+)%$ ]]; then
    local pct="${BASH_REMATCH[1]}"
    (( pct >= 1 && pct <= 10000 )) || return 1
    printf '%s 100000' $((pct * 1000))
    return 0
  fi
  if [[ "$raw" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
    printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "$raw" == "max" ]]; then
    printf 'max 100000'
    return 0
  fi
  return 1
}

_resources_mode() {
  case "${CAPBOX_RESOURCES_MODE:-warn}" in
    require|strict|fail-closed|fail_closed) printf 'require' ;;
    *) printf 'warn' ;;
  esac
}

_resources_any_configured() {
  [[ -n "${CAPBOX_MEMORY_MAX:-}" || -n "${CAPBOX_PIDS_MAX:-}" || -n "${CAPBOX_CPU_MAX:-}" || -n "${CAPBOX_DISK_MAX:-}" ]]
}

_resources_probe_cgroup() {
  CAPBOX_CGROUP_STATUS=missing
  CAPBOX_CGROUP_DETAIL=""
  CAPBOX_CGROUP_ROOT=""

  if [[ ! -d /sys/fs/cgroup ]]; then
    CAPBOX_CGROUP_DETAIL="无 /sys/fs/cgroup"
    return 1
  fi
  if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
    CAPBOX_CGROUP_DETAIL="非 cgroup v2 统一层级（缺 cgroup.controllers）"
    return 1
  fi

  local root=""
  if root="$(_resources_find_cgroup_root 2>/dev/null)"; then
    CAPBOX_CGROUP_ROOT="$root"
    CAPBOX_CGROUP_STATUS=ready
    CAPBOX_CGROUP_DETAIL="可写 cgroup 根: $root"
    return 0
  fi

  local self cgpath err
  self="$(awk -F: '{print $NF; exit}' /proc/self/cgroup 2>/dev/null || true)"
  cgpath="/sys/fs/cgroup${self}"
  err="$(mkdir -p "${cgpath}/.capbox-probe-$$" 2>&1 || true)"
  rmdir "${cgpath}/.capbox-probe-$$" 2>/dev/null || true
  CAPBOX_CGROUP_STATUS=denied
  CAPBOX_CGROUP_DETAIL="无法在 cgroup 下建子目录（self=${self:-/}）；mkdir 证据: ${err:-permission denied}。控制器有 $(tr ' ' ',' </sys/fs/cgroup/cgroup.controllers 2>/dev/null || echo '?') 但当前用户无委派。"
  return 1
}

_resources_find_cgroup_root() {
  local candidates=() cur
  cur="$(awk -F: '($1=="0" || $1==""){print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
  [[ "$cur" == *:* ]] && cur="${cur##*:}"
  [[ -n "$cur" ]] && candidates+=("/sys/fs/cgroup$cur" "/sys/fs/cgroup/$cur")
  candidates+=(
    "/sys/fs/cgroup"
    "${XDG_RUNTIME_DIR:-}/cgroup"
    "${CAPBOX_RUN_DIR:-}/cgroup"
  )
  local c
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -d "$c" ]] || continue
    if mkdir -p "$c/.capbox-probe-$$" 2>/dev/null; then
      rmdir "$c/.capbox-probe-$$" 2>/dev/null || true
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

_resources_setup_cgroup() {
  local root leaf
  root="$(_resources_find_cgroup_root)" || return 1
  leaf="$root/capbox-$$-$RANDOM"
  mkdir -p "$leaf" 2>/dev/null || return 1

  if [[ -w "$root/cgroup.subtree_control" ]]; then
    for ctrl in memory pids cpu io; do
      echo "+$ctrl" >"$root/cgroup.subtree_control" 2>/dev/null || true
    done
  fi

  local applied=0
  CAPBOX_RESOURCES_APPLIED_MEMORY=""
  CAPBOX_RESOURCES_APPLIED_PIDS=""
  CAPBOX_RESOURCES_APPLIED_CPU=""
  CAPBOX_RESOURCES_APPLIED_IO=""

  if [[ -n "${CAPBOX_MEMORY_MAX:-}" ]]; then
    local bytes
    if bytes="$(_resources_parse_bytes "$CAPBOX_MEMORY_MAX")"; then
      if [[ -w "$leaf/memory.max" ]] && echo "$bytes" >"$leaf/memory.max" 2>/dev/null; then
        applied=1
        CAPBOX_RESOURCES_APPLIED_MEMORY="cgroup:$bytes"
      else
        log_warn "MEMORY_MAX=$CAPBOX_MEMORY_MAX 无法写入 cgroup memory.max（未应用）"
      fi
    else
      log_warn "MEMORY_MAX 无法解析: $CAPBOX_MEMORY_MAX"
    fi
  fi
  if [[ -n "${CAPBOX_PIDS_MAX:-}" ]]; then
    if [[ "$CAPBOX_PIDS_MAX" =~ ^[0-9]+$ ]]; then
      if [[ -w "$leaf/pids.max" ]] && echo "$CAPBOX_PIDS_MAX" >"$leaf/pids.max" 2>/dev/null; then
        applied=1
        CAPBOX_RESOURCES_APPLIED_PIDS="cgroup:$CAPBOX_PIDS_MAX"
      else
        log_warn "PIDS_MAX=$CAPBOX_PIDS_MAX 无法写入 cgroup pids.max（未应用；不会用 RLIMIT_NPROC 冒充）"
      fi
    else
      log_warn "PIDS_MAX 必须是正整数（当前: $CAPBOX_PIDS_MAX）"
    fi
  fi
  if [[ -n "${CAPBOX_CPU_MAX:-}" ]]; then
    local cpuv
    if cpuv="$(_resources_parse_cpu_max "$CAPBOX_CPU_MAX")"; then
      if [[ -w "$leaf/cpu.max" ]] && echo "$cpuv" >"$leaf/cpu.max" 2>/dev/null; then
        applied=1
        CAPBOX_RESOURCES_APPLIED_CPU="cgroup:$cpuv"
      else
        log_warn "CPU_MAX=$CAPBOX_CPU_MAX 无法写入 cgroup cpu.max（未应用）"
      fi
    else
      log_warn "CPU_MAX 无法解析: $CAPBOX_CPU_MAX（支持 50% 或 'quota period'）"
    fi
  fi
  if [[ -n "${CAPBOX_IO_MAX:-}" && -w "$leaf/io.max" ]]; then
    if echo "$CAPBOX_IO_MAX" >"$leaf/io.max" 2>/dev/null; then
      applied=1
      CAPBOX_RESOURCES_APPLIED_IO="cgroup:$CAPBOX_IO_MAX"
    fi
  fi

  (( applied == 1 )) || {
    rmdir "$leaf" 2>/dev/null || true
    return 1
  }
  CAPBOX_RESOURCES_CGROUP_LEAF="$leaf"
  printf '%s' "$leaf"
  return 0
}

_resources_probe_disk() {
  CAPBOX_DISK_STATUS=unavailable
  CAPBOX_DISK_DETAIL=""
  if [[ -z "${CAPBOX_DISK_MAX:-}" ]]; then
    CAPBOX_DISK_STATUS=unset
    CAPBOX_DISK_DETAIL="未配置 CAPBOX_DISK_MAX"
    return 1
  fi
  if [[ ! -e /dev/loop-control ]]; then
    CAPBOX_DISK_DETAIL="无 /dev/loop-control"
    return 1
  fi
  if [[ ! -w /dev/loop-control ]]; then
    local lsout
    lsout="$(ls -l /dev/loop-control 2>&1 || true)"
    CAPBOX_DISK_DETAIL="无写权限: $lsout（通常需 disk 组或 root；拒绝假装已限额）"
    return 1
  fi
  CAPBOX_DISK_STATUS=capable
  CAPBOX_DISK_DETAIL="loop-control 可写；完整磁盘限额需 losetup+mkfs+mount（尚未默认自动挂到 guest）"
  return 0
}

_resources_fail_closed_check() {
  [[ "$(_resources_mode)" == "require" ]] || return 0
  local missing=()
  if [[ -n "${CAPBOX_MEMORY_MAX:-}" && "${CAPBOX_RESOURCES_APPLIED_MEMORY:-}" != cgroup:* ]]; then
    missing+=("MEMORY_MAX(need cgroup memory.max, not prlimit)")
  fi
  if [[ -n "${CAPBOX_PIDS_MAX:-}" && "${CAPBOX_RESOURCES_APPLIED_PIDS:-}" != cgroup:* ]]; then
    missing+=("PIDS_MAX(need cgroup pids.max)")
  fi
  if [[ -n "${CAPBOX_CPU_MAX:-}" && "${CAPBOX_RESOURCES_APPLIED_CPU:-}" != cgroup:* ]]; then
    missing+=("CPU_MAX(need cgroup cpu.max)")
  fi
  if [[ -n "${CAPBOX_DISK_MAX:-}" ]]; then
    _resources_probe_disk || true
    if [[ "${CAPBOX_DISK_STATUS}" != "capable" ]]; then
      missing+=("DISK_MAX(${CAPBOX_DISK_DETAIL})")
    fi
  fi
  if (( ${#missing[@]} > 0 )); then
    log_err "CAPBOX_RESOURCES_MODE=require：以下限额无法精确兑现: ${missing[*]}"
    return 1
  fi
  return 0
}

_resources_wrap_argv() {
  local -n _rw_cmd="$1"
  CAPBOX_RESOURCES_APPLIED_MEMORY="${CAPBOX_RESOURCES_APPLIED_MEMORY:-}"
  CAPBOX_RESOURCES_APPLIED_PIDS="${CAPBOX_RESOURCES_APPLIED_PIDS:-}"
  CAPBOX_RESOURCES_APPLIED_CPU="${CAPBOX_RESOURCES_APPLIED_CPU:-}"

  _resources_any_configured || return 0

  local cg=""
  if cg="$(_resources_setup_cgroup)"; then
    local -a inner=("${_rw_cmd[@]}")
    _rw_cmd=(
      /bin/bash -c
      'echo $$ >"$1/cgroup.procs" 2>/dev/null || true; shift; exec "$@"'
      bash
      "$cg"
      "${inner[@]}"
    )
    log_debug "资源限额经 cgroup 应用: $cg"
    _resources_fail_closed_check || return 1
    if declare -F audit_event >/dev/null 2>&1; then
      audit_event resources ok "detail=cgroup:$cg"
    fi
    return 0
  fi

  _resources_probe_cgroup || true

  if [[ -n "${CAPBOX_CPU_MAX:-}" ]]; then
    log_warn "CPU_MAX=$CAPBOX_CPU_MAX 未应用：${CAPBOX_CGROUP_DETAIL:-无 cgroup 委派}"
  fi
  if [[ -n "${CAPBOX_PIDS_MAX:-}" ]]; then
    log_warn "PIDS_MAX=$CAPBOX_PIDS_MAX 未应用：需要 cgroup pids（拒绝使用 RLIMIT_NPROC）"
  fi
  if [[ -n "${CAPBOX_DISK_MAX:-}" ]]; then
    _resources_probe_disk || true
    log_warn "DISK_MAX=$CAPBOX_DISK_MAX 未应用：${CAPBOX_DISK_DETAIL}"
  fi

  if [[ -n "${CAPBOX_MEMORY_MAX:-}" ]]; then
    local bytes
    if [[ "$(_resources_mode)" == "require" ]]; then
      log_err "MEMORY_MAX=$CAPBOX_MEMORY_MAX：require 模式拒绝 prlimit 降级（不是 cgroup memory.max）"
      _resources_fail_closed_check
      return 1
    fi
    if bytes="$(_resources_parse_bytes "$CAPBOX_MEMORY_MAX")" && have_cmd prlimit; then
      log_warn "MEMORY_MAX=$CAPBOX_MEMORY_MAX 降级为 prlimit RLIMIT_AS=${bytes}（虚拟地址空间近似，**不是** cgroup memory.max）"
      local -a inner2=("${_rw_cmd[@]}")
      _rw_cmd=(prlimit "--as=$bytes" -- "${inner2[@]}")
      CAPBOX_RESOURCES_APPLIED_MEMORY="prlimit-as:$bytes"
    else
      log_warn "MEMORY_MAX=$CAPBOX_MEMORY_MAX 未应用：无 cgroup 且无 prlimit/无法解析"
    fi
  fi

  if [[ "$(_resources_mode)" == "require" ]]; then
    _resources_fail_closed_check || return 1
  fi
  return 0
}

_resources_metrics_json() {
  _resources_probe_cgroup || true
  _resources_probe_disk || true
  printf '{'
  printf '"cgroup_status":"%s",' "${CAPBOX_CGROUP_STATUS:-unknown}"
  printf '"cgroup_detail":"%s",' "${CAPBOX_CGROUP_DETAIL//\"/\\\"}"
  printf '"disk_status":"%s",' "${CAPBOX_DISK_STATUS:-unset}"
  printf '"disk_detail":"%s",' "${CAPBOX_DISK_DETAIL//\"/\\\"}"
  printf '"memory_applied":"%s",' "${CAPBOX_RESOURCES_APPLIED_MEMORY:-}"
  printf '"cpu_applied":"%s",' "${CAPBOX_RESOURCES_APPLIED_CPU:-}"
  printf '"pids_applied":"%s",' "${CAPBOX_RESOURCES_APPLIED_PIDS:-}"
  printf '"mode":"%s"' "$(_resources_mode)"
  printf '}\n'
}

_resources_doctor_report() {
  _resources_probe_cgroup || true
  case "${CAPBOX_CGROUP_STATUS}" in
    ready) _doctor_pass "cgroup v2 可写（${CAPBOX_CGROUP_DETAIL}）" ;;
    denied) _doctor_warn "cgroup v2 存在但不可委派：${CAPBOX_CGROUP_DETAIL}" ;;
    *) _doctor_warn "cgroup 不可用：${CAPBOX_CGROUP_DETAIL:-unknown}" ;;
  esac
  if [[ -n "${CAPBOX_DISK_MAX:-}" ]]; then
    _resources_probe_disk || true
    if [[ "${CAPBOX_DISK_STATUS}" == "capable" ]]; then
      _doctor_pass "DISK_MAX 探测：loop 可用（${CAPBOX_DISK_DETAIL}）"
    else
      _doctor_warn "DISK_MAX 无法兑现：${CAPBOX_DISK_DETAIL}"
    fi
  fi
  if ! _resources_any_configured; then
    _doctor_pass "资源限额未配置（MEMORY/CPU/PIDS/DISK 为空）"
    return 0
  fi
  _doctor_pass "RESOURCES_MODE=$(_resources_mode)"
  [[ -n "${CAPBOX_MEMORY_MAX:-}" ]] && _doctor_pass "已配置 MEMORY_MAX=$CAPBOX_MEMORY_MAX"
  [[ -n "${CAPBOX_CPU_MAX:-}" ]] && _doctor_pass "已配置 CPU_MAX=$CAPBOX_CPU_MAX"
  [[ -n "${CAPBOX_PIDS_MAX:-}" ]] && _doctor_pass "已配置 PIDS_MAX=$CAPBOX_PIDS_MAX"
}
