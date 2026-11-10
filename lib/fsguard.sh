# shellcheck shell=bash
# =============================================================================
# CapBox - fsguard.sh
# 文件系统策略：按目录 ro/rw/hide、敏感路径默认不可见、rootfs 只读+overlay、
# 快照/回滚。配置校验拒绝任意宿主 bind 与路径逃逸。
#
# CAPBOX_ROOTFS_RO=0|1
# CAPBOX_FS_HIDE=rel1,rel2          # 相对 /workspace 的路径，tmpfs 遮盖
# CAPBOX_FS_BINDS=spec,...          # 每项 host:guest:ro|rw  （host 必须在工作区内）
# CAPBOX_OVERLAY=0|1|auto           # rootfs 可写层（仅实测通过才启用）
# =============================================================================

_fsguard_validate_rel_path() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1
  [[ "$p" != /* ]] || { log_err "FS 路径不能是绝对路径: $p"; return 2; }
  [[ "$p" != *..* ]] || { log_err "FS 路径禁止 ..: $p"; return 2; }
  [[ "$p" != *//* ]] || { log_err "FS 路径禁止空段: $p"; return 2; }
  [[ "$p" =~ ^[A-Za-z0-9._@+=,/-]+$ ]] || { log_err "FS 路径含非法字符: $p"; return 2; }
  return 0
}

# host 路径必须解析后落在 CAPBOX_WORKSPACE 内
_fsguard_host_in_workspace() {
  local host="${1:-}" ws="${CAPBOX_WORKSPACE%/}"
  [[ -n "$host" && -n "$ws" ]] || return 1
  local abs
  abs="$(resolve_path "$host" 2>/dev/null)" || return 1
  case "$abs" in
    "$ws" | "$ws"/*) return 0 ;;
    *) return 1 ;;
  esac
}

_fsguard_parse_bind_spec() {
  # spec = host:guest:mode   guest 以 / 开头；mode=ro|rw
  local spec="${1:-}"
  _fs_bind_host="" _fs_bind_guest="" _fs_bind_mode=""
  # 从右拆 mode，再拆 guest（guest 必须绝对路径）
  if [[ ! "$spec" =~ ^(.+):(/[^:]+):(ro|rw)$ ]]; then
    log_err "FS_BINDS 项格式必须是 host:/guest/path:ro|rw（当前: $spec）"
    return 2
  fi
  _fs_bind_host="${BASH_REMATCH[1]}"
  _fs_bind_guest="${BASH_REMATCH[2]}"
  _fs_bind_mode="${BASH_REMATCH[3]}"
  [[ "$_fs_bind_guest" != *..* ]] || { log_err "guest 路径禁止 .."; return 2; }
  _fsguard_host_in_workspace "$_fs_bind_host" || {
    log_err "拒绝工作区外宿主 bind: $_fs_bind_host（只允许 CAPBOX_WORKSPACE 内）"
    return 2
  }
  return 0
}

_fsguard_validate_config() {
  local raw part
  raw="${CAPBOX_FS_HIDE:-}"
  if [[ -n "$raw" ]]; then
    IFS=',' read -r -a _fs_hide_parts <<<"$raw"
    for part in "${_fs_hide_parts[@]}"; do
      part="${part#"${part%%[![:space:]]*}"}"
      part="${part%"${part##*[![:space:]]}"}"
      [[ -n "$part" ]] || continue
      _fsguard_validate_rel_path "$part" || return 2
    done
  fi
  raw="${CAPBOX_FS_BINDS:-}"
  if [[ -n "$raw" ]]; then
    IFS=',' read -r -a _fs_bind_parts <<<"$raw"
    for part in "${_fs_bind_parts[@]}"; do
      part="${part#"${part%%[![:space:]]*}"}"
      part="${part%"${part##*[![:space:]]}"}"
      [[ -n "$part" ]] || continue
      _fsguard_parse_bind_spec "$part" || return 2
    done
  fi
  case "${CAPBOX_ROOTFS_RO:-0}" in
    0|1|true|false|yes|no|"") ;;
    *) log_err "CAPBOX_ROOTFS_RO 只能是 0/1"; return 2 ;;
  esac
  return 0
}

_fsguard_rootfs_ro() {
  case "${CAPBOX_ROOTFS_RO:-0}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

_fsguard_overlay_dir() {
  printf '%s' "${CAPBOX_RUN_DIR:-$CAPBOX_DIR/run}/overlay"
}

# 实测 overlay 是否可用；成功返回 0
_fsguard_probe_overlay() {
  local rf="${CAPBOX_ROOTFS:-}" u w
  [[ -d "$rf" ]] || return 1
  [[ -x "${CAPBOX_BWRAP:-}" ]] || return 1
  u="$(_fsguard_overlay_dir)/probe-u-$$"
  w="$(_fsguard_overlay_dir)/probe-w-$$"
  mkdir -p "$u" "$w" 2>/dev/null || return 1
  local out rc=0
  out="$("$CAPBOX_BWRAP" --clearenv --unshare-net --unshare-user --uid 0 --gid 0 --cap-add ALL \
    --setenv PATH /usr/bin:/bin \
    --proc /proc --dev /dev --tmpfs /tmp \
    --overlay-src "$rf" --overlay "$u" "$w" / --die-with-parent -- \
    /bin/sh -c 'echo probe > /capbox-overlay-probe; cat /capbox-overlay-probe' 2>&1)" || rc=$?
  rm -rf "$u" "$w" 2>/dev/null || true
  [[ $rc -eq 0 && "$out" == *probe* ]]
}

_fsguard_overlay_available() {
  case "${CAPBOX_OVERLAY:-auto}" in
    0|off|false|no) return 1 ;;
    1|on|true|yes)
      _fsguard_probe_overlay
      ;;
    auto|"")
      _fsguard_probe_overlay
      ;;
    *) return 1 ;;
  esac
}

# 替换/增强 rootfs 挂载：由 build_bwrap_args 调用
# 用法: _fsguard_apply_rootfs_mount ARR_NAME
# 若启用 RO+overlay，则不使用普通 --bind rootfs /
_fsguard_apply_rootfs_mount() {
  local -n _fm_arr="$1"
  local rf="${CAPBOX_ROOTFS}"
  CAPBOX_FS_OVERLAY_ACTIVE=0

  if _fsguard_rootfs_ro; then
    if _fsguard_overlay_available; then
      local base u w
      base="$(_fsguard_overlay_dir)/active"
      u="$base/upper"
      w="$base/work"
      mkdir -p "$u" "$w" || die 1 "无法创建 overlay 目录"
      _fm_arr+=(--overlay-src "$rf" --overlay "$u" "$w" /)
      CAPBOX_FS_OVERLAY_ACTIVE=1
      log_debug "rootfs: overlay RW upper=$u（底层 RO）"
    else
      _fm_arr+=(--ro-bind "$rf" /)
      log_warn "ROOTFS_RO=1 但 overlay 不可用：根只读挂载，写入 / 会失败（/tmp /run 仍为 tmpfs）"
    fi
  else
    _fm_arr+=(--bind "$rf" /)
  fi
}

_fsguard_append_default_hides() {
  local -n _fh_arr="$1"
  local rel
  # 配置的 hide
  if [[ -n "${CAPBOX_FS_HIDE:-}" ]]; then
    local part
    IFS=',' read -r -a _parts <<<"$CAPBOX_FS_HIDE"
    for part in "${_parts[@]}"; do
      part="${part#"${part%%[![:space:]]*}"}"
      part="${part%"${part##*[![:space:]]}"}"
      [[ -n "$part" ]] || continue
      _fsguard_validate_rel_path "$part" || continue
      _fh_arr+=(--tmpfs "/workspace/$part")
    done
  fi
  # 安全档默认 hide（若 security 已处理可重复 tmpfs，无害）
  if declare -F _security_is_hardened >/dev/null 2>&1 && _security_is_hardened; then
    if declare -F _security_default_workspace_hides >/dev/null 2>&1; then
      while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        _fh_arr+=(--tmpfs "/workspace/$rel")
      done < <(_security_default_workspace_hides)
    fi
  fi
}

_fsguard_append_binds() {
  local -n _fb_arr="$1"
  [[ -n "${CAPBOX_FS_BINDS:-}" ]] || return 0
  local part
  IFS=',' read -r -a _bparts <<<"$CAPBOX_FS_BINDS"
  for part in "${_bparts[@]}"; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ -n "$part" ]] || continue
    _fsguard_parse_bind_spec "$part" || die 2 "FS_BINDS 非法: $part"
    if declare -F _capbox_guest_covers_logs >/dev/null 2>&1 && _capbox_guest_covers_logs "$_fs_bind_guest"; then
      log_err "FS_BINDS 不能挂到 logs/ 上（审计日志必须保持只读）: $_fs_bind_guest"
      return 2
    fi
    local abs
    abs="$(resolve_path "$_fs_bind_host")" || die 2 "无法规范化 FS_BINDS 宿主路径: $_fs_bind_host"
    if [[ "$_fs_bind_mode" == "ro" ]]; then
      _fb_arr+=(--ro-bind "$abs" "$_fs_bind_guest")
    else
      _fb_arr+=(--bind "$abs" "$_fs_bind_guest")
    fi
  done
}

_fsguard_append_bwrap_args() {
  local -n _fa="$1"
  _fsguard_validate_config || return $?
  _fsguard_append_default_hides _fa
  _fsguard_append_binds _fa || return $?
}

# ---------- 快照 / 回滚 -------------------------------------------------------

_fsguard_snap_dir() {
  printf '%s' "${CAPBOX_DIR}/snapshots"
}

_fsguard_valid_snap_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]]
}

cmd_snapshot() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    -h|--help|"")
      i18n_print help.snapshot
      return 0
      ;;
    list)
      local d
      d="$(_fsguard_snap_dir)"
      if [[ ! -d "$d" ]] || [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then
        printf '(无快照)\n'
        return 0
      fi
      ls -lh -- "$d"
      return 0
      ;;
    create)
      local name="${1:-}"
      _fsguard_valid_snap_name "$name" || die 2 "快照名非法"
      require_rootfs
      local d out
      d="$(_fsguard_snap_dir)"
      mkdir -p "$d"
      if have_cmd zstd; then
        out="$d/${name}.tar.zst"
        tar --numeric-owner -C "$(dirname "$CAPBOX_ROOTFS")" -cf - "$(basename "$CAPBOX_ROOTFS")" \
          | zstd -q -T0 -o "$out"
      else
        out="$d/${name}.tar.gz"
        tar --numeric-owner -C "$(dirname "$CAPBOX_ROOTFS")" -czf "$out" "$(basename "$CAPBOX_ROOTFS")"
      fi
      local sum
      sum="$(sha256sum "$out" | awk '{print $1}')"
      printf '%s\n' "$sum" >"${out}.sha256"
      log_info "快照已创建: $out (sha256=$sum)"
      if declare -F audit_event >/dev/null 2>&1; then
        audit_event snapshot ok "object=$name" "detail=$out" "exit=0" "ms=0"
      fi
      printf '%s\n' "$out"
      return 0
      ;;
    restore)
      local name="${1:-}"
      _fsguard_valid_snap_name "$name" || die 2 "快照名非法"
      local d arch
      d="$(_fsguard_snap_dir)"
      if [[ -f "$d/${name}.tar.zst" ]]; then arch="$d/${name}.tar.zst"
      elif [[ -f "$d/${name}.tar.gz" ]]; then arch="$d/${name}.tar.gz"
      else die 1 "快照不存在: $name"; fi
      if [[ -f "${arch}.sha256" ]]; then
        local expect got
        expect="$(tr -d ' \n' <"${arch}.sha256" | cut -c1-64)"
        got="$(sha256sum "$arch" | awk '{print $1}')"
        [[ "$expect" == "$got" ]] || die 1 "快照校验失败: $arch"
      fi
      local parent tmp
      parent="$(dirname "$CAPBOX_ROOTFS")"
      tmp="$parent/.restore-$$"
      rm -rf "$tmp"
      mkdir -p "$tmp"
      if [[ "$arch" == *.zst ]]; then
        zstd -q -d -c "$arch" | tar --numeric-owner -C "$tmp" -xf -
      else
        tar --numeric-owner -C "$tmp" -xzf "$arch"
      fi
      local extracted="$tmp/$(basename "$CAPBOX_ROOTFS")"
      [[ -d "$extracted" ]] || die 1 "快照内容缺少 $(basename "$CAPBOX_ROOTFS")"
      local bak="$parent/.rootfs-bak-$$"
      mv -- "$CAPBOX_ROOTFS" "$bak"
      if ! mv -- "$extracted" "$CAPBOX_ROOTFS"; then
        mv -- "$bak" "$CAPBOX_ROOTFS" || true
        die 1 "恢复失败，已尝试回退"
      fi
      rm -rf "$bak" "$tmp"
      log_info "已从快照恢复: $name"
      if declare -F audit_event >/dev/null 2>&1; then
        audit_event snapshot ok "object=$name" "detail=restored" "exit=0" "ms=0"
      fi
      return 0
      ;;
    rm|remove)
      local name="${1:-}"
      _fsguard_valid_snap_name "$name" || die 2 "快照名非法"
      rm -f -- "$(_fsguard_snap_dir)/${name}.tar.zst" "$(_fsguard_snap_dir)/${name}.tar.gz" \
        "$(_fsguard_snap_dir)/${name}.tar.zst.sha256" "$(_fsguard_snap_dir)/${name}.tar.gz.sha256"
      log_info "已删除快照 $name"
      return 0
      ;;
    *) die 2 "snapshot: 未知子命令 $sub" ;;
  esac
}

_fsguard_doctor_report() {
  if _fsguard_rootfs_ro; then
    if _fsguard_overlay_available; then
      _doctor_pass "ROOTFS_RO=1 且 overlay 实测可用（写入进入 upper）"
    else
      _doctor_warn "ROOTFS_RO=1 但 overlay 不可用：根将只读挂载"
    fi
  else
    _doctor_pass "ROOTFS_RO 未启用（rootfs RW bind，兼容默认）"
  fi
  if [[ -n "${CAPBOX_FS_HIDE:-}" || -n "${CAPBOX_FS_BINDS:-}" ]]; then
    if _fsguard_validate_config; then
      _doctor_pass "FS_HIDE/FS_BINDS 配置校验通过（禁止工作区外 bind）"
    else
      _doctor_fail "FS_HIDE/FS_BINDS 配置非法"
    fi
  fi
}
