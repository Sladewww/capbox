# shellcheck shell=bash
# =============================================================================
# CapBox - recipe.sh
# 声明式项目配方：安全 KEY=value（绝不 source / eval）。
#
# 默认路径（按序）：
#   1) 参数指定
#   2) $CAPBOX_WORKSPACE/capbox.recipe
#   3) $CAPBOX_DIR/recipe.env
#
# 支持键（短键，亦可写 CAPBOX_ 前缀）：CAPBOX_RECIPE_KEYS。
# apply 会把除 PACKAGES、INIT 以外、且出现在配方里的键全部 config_set。
#   PACKAGES   —— 逗号/空白分隔，apply 时 pkg install
#   INIT       —— 1/yes 时若 rootfs 未就绪则执行 init（默认 1）
# =============================================================================

readonly CAPBOX_RECIPE_KEYS=(
  DISTRO MIRROR MIRROR_ALPINE MIRROR_UBUNTU PROXY NET NET_ALLOW
  HOSTNAME EXEC_TIMEOUT BWRAP
  MEMORY_MAX CPU_MAX PIDS_MAX DISK_MAX RESOURCES_MODE
  IDMAP UID_MAP GID_MAP SETGROUPS EXEC_UID EXEC_GID
  SECURITY_PROFILE LANDLOCK ROOTFS_RO FS_HIDE FS_BINDS OVERLAY
  AUDIT AUDIT_CMD
  PACKAGES INIT
)

_recipe_norm_key() {
  local k="${1:-}"
  k="${k^^}"
  k="${k#CAPBOX_}"
  printf '%s' "$k"
}

_recipe_known() {
  local k="${1:-}" x
  for x in "${CAPBOX_RECIPE_KEYS[@]}"; do
    [[ "$k" == "$x" ]] && return 0
  done
  return 1
}

_recipe_parse_line() {
  local line="${1-}" key raw short
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -n "$line" ]] || return 1
  [[ "$line" == \#* ]] && return 1
  if [[ "$line" =~ ^export[[:space:]]+(.*)$ ]]; then
    line="${BASH_REMATCH[1]}"
    line="${line#"${line%%[![:space:]]*}"}"
  fi
  [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || return 1
  key="${BASH_REMATCH[1]}"
  raw="${BASH_REMATCH[2]}"
  short="$(_recipe_norm_key "$key")"
  _recipe_known "$short" || {
    i18n_err recipe.recipe_unknown_key key="$key"
    return 1
  }
  if [[ "$raw" == \'* ]]; then
    local out="" s="$raw"
    s="${s:1}"
    while true; do
      local i=0
      while (( i < ${#s} )) && [[ "${s:i:1}" != "'" ]]; do
        out+="${s:i:1}"
        ((++i))
      done
      (( i < ${#s} )) || return 1
      s="${s:i+1}"
      if [[ -z "$s" || "$s" =~ ^[[:space:]]*(#.*)?$ ]]; then
        _recipe_key="$short"
        _recipe_val="$out"
        return 0
      fi
      if [[ "$s" == \\\'* ]]; then
        out+="'"
        s="${s:2}"
        [[ "$s" == \'* ]] || return 1
        s="${s:1}"
        continue
      fi
      return 1
    done
  elif [[ "$raw" == \"* ]]; then
    if [[ "$raw" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
      local inner="${BASH_REMATCH[1]}"
      if [[ "$inner" =~ [\$\`\\] ]]; then
        i18n_warn recipe.recipe_rejected_double_quoted_value_containing_expansion key="$key"
        return 1
      fi
      _recipe_key="$short"
      _recipe_val="$inner"
      return 0
    fi
    return 1
  else
    if [[ "$raw" =~ ^(.*)[[:space:]]+#.*$ ]]; then
      raw="${BASH_REMATCH[1]}"
    fi
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [[ -n "$raw" && "$raw" =~ [\$\`\;\|\&\<\>\(\)\{\}] ]]; then
      i18n_warn recipe.recipe_rejected_unsafe_bare_value key="$key"
      return 1
    fi
    _recipe_key="$short"
    _recipe_val="$raw"
    return 0
  fi
}

_recipe_find_file() {
  local hint="${1:-}"
  if [[ -n "$hint" ]]; then
    [[ -f "$hint" ]] || i18n_die 2 recipe.recipe_file_does_not_exist hint="$hint"
    printf '%s' "$hint"
    return 0
  fi
  local cands=(
    "${CAPBOX_WORKSPACE:-}/capbox.recipe"
    "${CAPBOX_DIR:-}/recipe.env"
  )
  local f
  for f in "${cands[@]}"; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

_recipe_load_into() {
  local file="${1:-}"
  local -n _rl="$2"
  local line trimmed number=0 _recipe_key="" _recipe_val=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((++number))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$trimmed" && "$trimmed" != \#* ]] || continue
    _recipe_key=""; _recipe_val=""
    if ! _recipe_parse_line "$line"; then
      i18n_err recipe.recipe_line_invalid_only_key_value_known number="$number"
      return 2
    fi
    [[ -z "${_rl[$_recipe_key]+x}" ]] || {
      i18n_err recipe.recipe_duplicate_key_line _recipe_key="$_recipe_key" number="$number"; return 2;
    }
    _rl["$_recipe_key"]="$_recipe_val"
  done <"$file"
}

_recipe_validate() {
  local -n _rv="$1"
  local k raw
  local -a pkgs=()
  for k in "${!_rv[@]}"; do
    case "$k" in
      INIT)
        case "${_rv[$k],,}" in
          0|1|true|false|yes|no|on|off) ;;
          *) i18n_err recipe.recipe_init_must_boolean; return 2 ;;
        esac ;;
      PACKAGES)
        raw="${_rv[$k]//,/ }"
        read -r -a pkgs <<<"$raw"
        _pkg_names_ok "${pkgs[@]}" || return 2 ;;
      *) _cfg_validate "$k" "${_rv[$k]}" || return 2 ;;
    esac
  done
}

_cmd_recipe_dispatch() {
  local sub="${1:-apply}"
  case "$sub" in
    apply)
      shift || true
      _recipe_cmd_apply "$@"
      ;;
    check)
      shift || true
      _recipe_cmd_apply --check "$@"
      ;;
    export)
      shift || true; _recipe_cmd_export "$@" ;;
    show | cat)
      shift || true
      _recipe_cmd_show "$@"
      ;;
    -h | --help | help)
      i18n_print help.recipe
      return 0
      ;;
    *)
      # 无子命令时：若参数是文件则 apply，否则当 help
      if [[ -f "$sub" ]]; then
        _recipe_cmd_apply "$sub"
      else
        i18n_die 2 recipe.usage_capbox_recipe_check_apply_show_file
      fi
      ;;
  esac
}

cmd_recipe() {
  case "${1:-}" in
    -h | --help | help) ;;
    *)
      local t0 rc=0
      t0=$(date +%s%3N 2>/dev/null || date +%s)
      _cmd_recipe_dispatch "$@"
      rc=$?
      if declare -F audit_command >/dev/null 2>&1; then
        if (( rc == 0 )); then
          audit_command recipe "$rc" "$t0" "cmd=recipe $*"
        else
          audit_command recipe "$rc" "$t0" "cmd=recipe $*" "detail=recipe 失败，退出码 $rc"
        fi
      fi
      return "$rc"
      ;;
  esac
  _cmd_recipe_dispatch "$@"
}

_recipe_cmd_show() {
  local f
  f="$(_recipe_find_file "${1:-}")" || i18n_die 2 recipe.recipe_not_found_tried_capbox_recipe_capbox
  printf '# recipe: %s\n' "$f"
  cat -- "$f"
}

_recipe_cmd_apply() {
  local f do_init=1 hint="" locked="" check=0
  while (( $# )); do
    case "$1" in
      --check) check=1; shift ;;
      --locked)
        [[ $# -ge 2 ]] || i18n_die 2 recipe.locked_requires_lock_file
        locked="$2"; shift 2 ;;
      -*) i18n_die 2 recipe.recipe_unknown_option arg="$1" ;;
      *) [[ -z "$hint" ]] || i18n_die 2 recipe.recipe_accepts_only_one_file; hint="$1"; shift ;;
    esac
  done
  f="$(_recipe_find_file "$hint")" || i18n_die 2 recipe.recipe_not_found_tried_capbox_recipe_capbox
  i18n_info recipe.applying_recipe f="$f"

  declare -A R=()
  _recipe_load_into "$f" R || return $?
  _recipe_validate R || return $?
  if [[ -n "$locked" ]]; then
    _package_lock_validate "$locked" "${R[DISTRO]:-$CAPBOX_DISTRO}" "${R[PACKAGES]:-}" || return $?
  fi
  if (( check == 1 )); then
    printf 'OK %s\n' "$f"
    return 0
  fi

  local k
  local -a config_pairs=()
  for k in "${CAPBOX_RECIPE_KEYS[@]}"; do
    [[ "$k" == PACKAGES || "$k" == INIT ]] && continue
    [[ -n "${R[$k]+x}" ]] || continue
    config_pairs+=("$k" "${R[$k]}")
  done
  config_apply "${config_pairs[@]}" || return $?

  case "${R[INIT]:-1}" in
    0 | false | False | no | NO | off | OFF) do_init=0 ;;
    *) do_init=1 ;;
  esac

  if (( do_init == 1 )); then
    if ! rootfs_ready 2>/dev/null; then
      i18n_info recipe.recipe_rootfs_not_ready_running_init
      if declare -F cmd_init >/dev/null 2>&1; then
        local d="${R[DISTRO]:-$CAPBOX_DISTRO}"
        cmd_init --distro "$d" || return $?
      else
        i18n_die 1 recipe.cmd_init_unavailable
      fi
    else
      if [[ -n "${R[DISTRO]:-}" && "${R[DISTRO]}" != "$CAPBOX_DISTRO" ]]; then
        cmd_init --distro "${R[DISTRO]}" || return $?
      fi
      i18n_info recipe.recipe_rootfs_already_ready_skipping_download
    fi
  fi

  if [[ -n "$locked" ]]; then
    _package_lock_restore "$locked" || return $?
  elif [[ -n "${R[PACKAGES]:-}" ]]; then
    local pkgs=() raw
    raw="${R[PACKAGES]//,/ }"
    read -r -a pkgs <<<"$raw"
    if [[ ${#pkgs[@]} -gt 0 ]]; then
      i18n_info recipe.recipe_installing_packages pkgs="${pkgs[*]}"
      if declare -F cmd_pkg >/dev/null 2>&1; then
        cmd_pkg install -- "${pkgs[@]}" || return $?
      else
        i18n_die 1 recipe.cmd_pkg_unavailable
      fi
    fi
  fi

  i18n_info recipe.recipe_applied
  return 0
}


_recipe_cmd_export() {
  local f key
  f="$(_recipe_find_file "${1:-}")" || return 2
  declare -A R=()
  _recipe_load_into "$f" R && _recipe_validate R || return 2
  for key in "${CAPBOX_RECIPE_KEYS[@]}"; do
    [[ -n "${R[$key]+x}" ]] || continue
    printf '%s\0%s\0' "$key" "${R[$key]}"
  done | python3 -c 'import json,sys; p=sys.stdin.buffer.read().decode().split("\0")[:-1]; print(json.dumps({"schema":"capbox.recipe.v1","values":dict(zip(p[::2],p[1::2]))},ensure_ascii=True))'
}
