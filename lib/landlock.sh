# shellcheck shell=bash
# =============================================================================
# CapBox - landlock.sh
# 在 bwrap 完成挂载之后，对容器内命令加一层 Landlock VFS 限制。
#
# 不能包在 bwrap 外面：只要规则集处理了文件系统，内核就拒绝该进程 mount / pivot_root。
# 所以静态 helper 被只读绑进 guest，作为容器内命令的前缀，restrict_self 之后再 exec。
#
# CAPBOX_LANDLOCK=on|off
#   未设置：strict 默认 on，compat / untrusted 默认 off。
#   显式 on/off 覆盖档位默认。空值仍走默认。
# 这一层不限制 TCP 端口。允许目录之下不能再挖洞（FS_HIDE 仍靠挂载遮盖）。
# =============================================================================

_landlock_src() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$here/guest/capbox-landlock.c" ]]; then
    printf '%s' "$here/guest/capbox-landlock.c"
    return 0
  fi
  if [[ -n "${CAPBOX_GUEST_DIR:-}" && -f "${CAPBOX_GUEST_DIR}/capbox-landlock.c" ]]; then
    printf '%s' "${CAPBOX_GUEST_DIR}/capbox-landlock.c"
    return 0
  fi
  return 1
}

# 二进制放在工作区外面。guest 可写的 run/、state/ 不能当宿主执行体。
_landlock_private_dir() {
  local base d
  base="${XDG_RUNTIME_DIR:-}"
  if [[ -z "$base" || ! -d "$base" || ! -w "$base" ]]; then
    base="/run/user/$(id -u)"
  fi
  if [[ ! -d "$base" || ! -w "$base" ]]; then
    base="${TMPDIR:-/tmp}"
  fi
  d="$base/capbox-landlock"
  if [[ -L "$d" ]]; then
    log_err "Landlock 目录是符号链接: $d"
    return 1
  fi
  mkdir -p "$d" 2>/dev/null || {
    log_err "无法创建 Landlock 目录: $d"
    return 1
  }
  if [[ -L "$d" || ! -d "$d" ]]; then
    log_err "Landlock 目录不可用: $d"
    return 1
  fi
  chmod 700 "$d" 2>/dev/null || true
  printf '%s' "$d"
}

# 0=启用  1=关闭  2=配置非法
_landlock_enabled() {
  local v profile
  v="${CAPBOX_LANDLOCK-}"
  case "$v" in
    on) return 0 ;;
    off) return 1 ;;
    "")
      profile="compat"
      if declare -F _security_profile >/dev/null 2>&1; then
        profile="$(_security_profile)" || return $?
      fi
      [[ "$profile" == "strict" ]] && return 0
      return 1
      ;;
    *)
      log_err "CAPBOX_LANDLOCK 只能是 on 或 off（当前: ${v}）"
      return 2
      ;;
  esac
}

_landlock_ensure_helper() {
  local src dir bin cc tmp err
  src="$(_landlock_src)" || {
    log_err "缺少 lib/guest/capbox-landlock.c"
    return 5
  }
  dir="$(_landlock_private_dir)" || return 5
  bin="$dir/capbox-landlock"
  if [[ -L "$bin" ]]; then
    log_err "Landlock helper 是符号链接: $bin"
    return 5
  fi
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    if have_cmd gcc; then
      cc=gcc
    elif have_cmd cc; then
      cc=cc
    else
      log_err "CAPBOX_LANDLOCK 需要宿主 gcc -static 来构建 helper"
      return 5
    fi
    tmp="$(mktemp "$dir/build.XXXXXX")" || {
      log_err "无法创建 Landlock 构建临时文件"
      return 5
    }
    err="$("$cc" -static -O2 -s -o "$tmp" "$src" 2>&1)" || {
      rm -f "$tmp"
      log_err "构建 capbox-landlock 失败（需要 gcc -static）: ${err:-unknown}"
      return 5
    }
    chmod 755 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$bin" || {
      rm -f "$tmp"
      log_err "无法安装 capbox-landlock: $bin"
      return 5
    }
  fi
  [[ -x "$bin" && ! -L "$bin" ]] || {
    log_err "capbox-landlock 不可执行: $bin"
    return 5
  }
  printf '%s' "$bin"
}

# 根在 guest 里是只读还是可写。overlay 的写入发生在合并后的挂载上，规则要给 rw。
_landlock_rootfs_mode() {
  if declare -F _fsguard_rootfs_ro >/dev/null 2>&1 && _fsguard_rootfs_ro; then
    if [[ "${CAPBOX_FS_OVERLAY_ACTIVE:-0}" == "1" ]]; then
      printf 'rw'
    else
      printf 'ro'
    fi
  else
    printf 'rw'
  fi
}

_landlock_write_rules() {
  local dir file mode base ent disk
  dir="$(_landlock_private_dir)" || return 5
  file="$(mktemp "$dir/rules.XXXXXX")" || {
    log_err "无法创建 Landlock 规则文件"
    return 5
  }
  chmod 644 "$file" 2>/dev/null || true
  mode="$(_landlock_rootfs_mode)"
  {
    printf 'rw /workspace\n'
    printf 'rw /tmp\n'
    printf 'rw /run\n'
    printf 'rw /dev\n'
    printf 'rw /proc\n'
    if [[ -d "${CAPBOX_ROOTFS:-}" ]]; then
      for ent in "$CAPBOX_ROOTFS"/*; do
        [[ -e "$ent" || -L "$ent" ]] || continue
        base="$(basename -- "$ent")"
        case "$base" in
          tmp | run | dev | proc | sys | workspace) continue ;;
        esac
        [[ "$base" =~ ^[A-Za-z0-9._@+=,-]+$ ]] || continue
        printf '%s /%s\n' "$mode" "$base"
      done
    fi
    if [[ -n "${CAPBOX_DISK_MAX:-}" ]] && declare -F _resources_disk_guest_path >/dev/null 2>&1; then
      disk="$(_resources_disk_guest_path 2>/dev/null || true)"
      if [[ "$disk" == /* && "$disk" != *".."* ]]; then
        printf 'rw %s\n' "$disk"
      fi
    fi
  } >"$file" || {
    rm -f "$file"
    log_err "写入 Landlock 规则失败"
    return 5
  }
  printf '%s' "$file"
}

# 在 bwrap 的命令分隔符 `--` 之前插入 helper 的只读绑定，并把容器命令改成 helper 前缀。
# 用法: _landlock_apply_argv ARRAY_NAME
_landlock_apply_argv() {
  local -n _ll_cmd="$1"
  local en=0
  _landlock_enabled || en=$?
  if (( en == 1 )); then
    return 0
  fi
  if (( en != 0 )); then
    return "$en"
  fi

  local helper rules bwrap_i=-1 dd=-1 i
  helper="$(_landlock_ensure_helper)" || return $?
  rules="$(_landlock_write_rules)" || return $?

  for (( i = 0; i < ${#_ll_cmd[@]}; i++ )); do
    if [[ "${_ll_cmd[$i]}" == */bwrap || "${_ll_cmd[$i]}" == "bwrap" || "${_ll_cmd[$i]}" == "${CAPBOX_BWRAP:-}" ]]; then
      bwrap_i=$i
      break
    fi
  done
  if (( bwrap_i < 0 )); then
    log_err "Landlock 已启用，但启动命令里没有 bwrap"
    return 5
  fi
  for (( i = bwrap_i + 1; i < ${#_ll_cmd[@]}; i++ )); do
    if [[ "${_ll_cmd[$i]}" == "--" ]]; then
      dd=$i
      break
    fi
  done
  if (( dd < 0 )); then
    log_err "Landlock 已启用，但 bwrap 参数缺少命令分隔符 --"
    return 5
  fi
  if (( dd + 1 >= ${#_ll_cmd[@]} )); then
    log_err "Landlock 已启用，但没有容器内命令"
    return 5
  fi

  # 挂到已经存在的 /run 上。bwrap 会给不存在的目标创建挂载点；
  # 若目标在可写 rootfs 上（例如 /usr/bin/capbox-landlock），这个空文件会留在宿主 rootfs 里。
  # oneshot 的 /run 是 tmpfs。daemon/service 会先把 guest-run 绑到 /run，再走到这里。
  local guest_helper=/run/capbox-landlock
  local guest_rules=/run/capbox-landlock.rules
  local -a head=("${_ll_cmd[@]:0:dd}")
  local -a tail=("${_ll_cmd[@]:dd+1}")
  _ll_cmd=(
    "${head[@]}"
    --ro-bind "$helper" "$guest_helper"
    --ro-bind "$rules" "$guest_rules"
    --
    "$guest_helper" --rules "$guest_rules" --
    "${tail[@]}"
  )
  log_debug "Landlock 前缀已加上 helper=$helper"
  return 0
}

_landlock_doctor_report() {
  local en=0 abi helper
  _landlock_enabled || en=$?
  if (( en == 2 )); then
    _doctor_fail "CAPBOX_LANDLOCK 只能是 on 或 off（当前: ${CAPBOX_LANDLOCK}）"
    return 0
  fi
  if (( en == 1 )); then
    _doctor_pass "Landlock 关闭（未设置时 strict 默认开启，compat/untrusted 默认关闭）"
    return 0
  fi
  if ! helper="$(_landlock_ensure_helper)"; then
    _doctor_fail "Landlock 已启用，但无法构建 helper（需要宿主 gcc -static 与 lib/guest/capbox-landlock.c）"
    return 0
  fi
  abi="$("$helper" --probe 2>/dev/null || true)"
  if [[ ! "$abi" =~ ^[0-9]+$ || "$abi" -lt 1 ]]; then
    _doctor_fail "Landlock 已启用，但内核不支持（需要 5.13+ 且 LSM 已启用）"
    return 0
  fi
  _doctor_pass "Landlock ABI ${abi}（挂载完成之后限制 VFS；不限制 TCP 端口；允许目录之下不能再挖洞）"
}
