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
  local private d
  private="$(_capbox_host_state_dir)" || return 1
  d="$private/landlock"
  mkdir -p "$d" || return 1
  [[ ! -L "$d" && -d "$d" ]] || return 1
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
      i18n_err landlock.capbox_landlock_must_off_got v="${v}"
      return 2
      ;;
  esac
}

_landlock_ensure_helper() {
  local src dir bin cc tmp err
  src="$(_landlock_src)" || {
    i18n_err landlock.missing_lib_guest_capbox_landlock_c
    return 5
  }
  dir="$(_landlock_private_dir)" || return 5
  bin="$dir/capbox-landlock"
  if [[ -L "$bin" ]]; then
    i18n_err landlock.landlock_helper_symlink bin="$bin"
    return 5
  fi
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    if have_cmd gcc; then
      cc=gcc
    elif have_cmd cc; then
      cc=cc
    else
      i18n_err landlock.capbox_landlock_requires_host_gcc_static_build
      return 5
    fi
    tmp="$(mktemp "$dir/build.XXXXXX")" || {
      i18n_err landlock.unable_create_temporary_file_landlock_build
      return 5
    }
    err="$("$cc" -static -O2 -s -o "$tmp" "$src" 2>&1)" || {
      rm -f "$tmp"
      i18n_err landlock.failed_build_capbox_landlock_gcc_static_required err="${err:-unknown}"
      return 5
    }
    chmod 755 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$bin" || {
      rm -f "$tmp"
      i18n_err landlock.unable_install_capbox_landlock bin="$bin"
      return 5
    }
  fi
  [[ -x "$bin" && ! -L "$bin" ]] || {
    i18n_err landlock.capbox_landlock_not_executable bin="$bin"
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
    i18n_err landlock.unable_create_landlock_rules_file
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
    i18n_err landlock.failed_write_landlock_rules
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
    i18n_err landlock.landlock_enabled_launch_command_has_no_bwrap
    return 5
  fi
  for (( i = bwrap_i + 1; i < ${#_ll_cmd[@]}; i++ )); do
    if [[ "${_ll_cmd[$i]}" == "--" ]]; then
      dd=$i
      break
    fi
  done
  if (( dd < 0 )); then
    i18n_err landlock.landlock_enabled_bwrap_arguments_missing_command_separator
    return 5
  fi
  if (( dd + 1 >= ${#_ll_cmd[@]} )); then
    i18n_err landlock.landlock_enabled_there_no_guest_command
    return 5
  fi

  # 挂到已经存在的 /run 上。bwrap 会给不存在的目标创建挂载点；
  # 若目标在可写 rootfs 上（例如 /usr/bin/capbox-landlock），这个空文件会留在宿主 rootfs 里。
  # oneshot 的 /run 是 tmpfs。daemon/service 会先把 guest-run 绑到 /run，再走到这里。
  local guest_helper=/run/capbox-landlock
  local guest_rules=/run/capbox-landlock.rules
  local -a head=("${_ll_cmd[@]:0:dd}")
  local -a tail=("${_ll_cmd[@]:dd+1}")
  # bwrap 会 --clearenv；把已规范的 CAPBOX_UI_LANG 传给 guest 里的 helper。
  _ll_cmd=(
    "${head[@]}"
    --ro-bind "$helper" "$guest_helper"
    --ro-bind "$rules" "$guest_rules"
    --setenv CAPBOX_UI_LANG "${CAPBOX_UI_LANG:-en}"
    --
    "$guest_helper" --rules "$guest_rules" --
    "${tail[@]}"
  )
  log_debug "Landlock prefix added helper=$helper"
  return 0
}

_landlock_doctor_report() {
  local en=0 abi helper
  _landlock_enabled || en=$?
  if (( en == 2 )); then
    _doctor_fail_i18n doctor.landlock_invalid value="${CAPBOX_LANDLOCK}"
    return 0
  fi
  if (( en == 1 )); then
    _doctor_pass_i18n doctor.landlock_off
    return 0
  fi
  if ! helper="$(_landlock_ensure_helper)"; then
    _doctor_fail_i18n doctor.landlock_helper_failed
    return 0
  fi
  abi="$("$helper" --probe 2>/dev/null || true)"
  if [[ ! "$abi" =~ ^[0-9]+$ || "$abi" -lt 1 ]]; then
    _doctor_fail_i18n doctor.landlock_kernel_unsupported
    return 0
  fi
  _doctor_pass_i18n doctor.landlock_abi abi="${abi}"
}
