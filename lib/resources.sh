# shellcheck shell=bash
# =============================================================================
# CapBox - resources.sh
# CPU / 内存 / PIDs 限额：优先 cgroup v2；不可用时诚实告警，绝不谎称已生效。
#
# CAPBOX_MEMORY_MAX  例: 512M 512Mi 1G 268435456
# CAPBOX_PIDS_MAX    例: 256
# CAPBOX_CPU_MAX     例: 50%  或 cgroup 原样 "50000 100000"
#
# 注意：
#   * RLIMIT_NPROC 是按 UID 全局计数，不能用于沙箱 PIDs，故绝不滥用。
#   * 无 cgroup 时 MEMORY 可降级为 RLIMIT_AS（虚拟地址空间近似），并 WARN。
#   * CPU 配额无 cgroup 时无法兑现 → WARN，不应用。
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

_resources_any_configured() {
  [[ -n "${CAPBOX_MEMORY_MAX:-}" || -n "${CAPBOX_PIDS_MAX:-}" || -n "${CAPBOX_CPU_MAX:-}" ]]
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
    for ctrl in memory pids cpu; do
      echo "+$ctrl" >"$root/cgroup.subtree_control" 2>/dev/null || true
    done
  fi

  local applied=0
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
  (( applied == 1 )) || {
    rmdir "$leaf" 2>/dev/null || true
    return 1
  }
  printf '%s' "$leaf"
  return 0
}

# 用法: local -a cmd=(bwrap ...); _resources_wrap_argv cmd
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
    return 0
  fi

  if [[ -n "${CAPBOX_CPU_MAX:-}" ]]; then
    log_warn "CPU_MAX=$CAPBOX_CPU_MAX 未应用：当前环境无可用 cgroup v2 委派"
  fi
  if [[ -n "${CAPBOX_PIDS_MAX:-}" ]]; then
    log_warn "PIDS_MAX=$CAPBOX_PIDS_MAX 未应用：需要 cgroup pids（拒绝使用 RLIMIT_NPROC，因其按 UID 全局生效）"
  fi
  if [[ -n "${CAPBOX_MEMORY_MAX:-}" ]]; then
    local bytes
    if bytes="$(_resources_parse_bytes "$CAPBOX_MEMORY_MAX")" && have_cmd prlimit; then
      log_warn "MEMORY_MAX=$CAPBOX_MEMORY_MAX 降级为 prlimit RLIMIT_AS=${bytes}（虚拟地址空间近似，不是 cgroup memory.max）"
      local -a inner2=("${_rw_cmd[@]}")
      _rw_cmd=(prlimit "--as=$bytes" -- "${inner2[@]}")
      CAPBOX_RESOURCES_APPLIED_MEMORY="prlimit-as:$bytes"
    else
      log_warn "MEMORY_MAX=$CAPBOX_MEMORY_MAX 未应用：无 cgroup 且无 prlimit/无法解析"
    fi
  fi
  return 0
}

_resources_doctor_report() {
  if ! _resources_any_configured; then
    _doctor_pass "资源限额未配置（CAPBOX_MEMORY_MAX / CPU_MAX / PIDS_MAX 为空）"
    return 0
  fi
  local root
  if root="$(_resources_find_cgroup_root 2>/dev/null)"; then
    _doctor_pass "检测到可写 cgroup 根 ($root)；配置的限额将尝试经 cgroup 应用"
  else
    _doctor_warn "资源限额已配置但无可用 cgroup v2 委派：CPU/PIDS 无法强制；MEMORY 可能降级为 RLIMIT_AS"
  fi
  [[ -n "${CAPBOX_MEMORY_MAX:-}" ]] && _doctor_pass "已配置 MEMORY_MAX=$CAPBOX_MEMORY_MAX"
  [[ -n "${CAPBOX_CPU_MAX:-}" ]] && _doctor_pass "已配置 CPU_MAX=$CAPBOX_CPU_MAX"
  [[ -n "${CAPBOX_PIDS_MAX:-}" ]] && _doctor_pass "已配置 PIDS_MAX=$CAPBOX_PIDS_MAX"
}
