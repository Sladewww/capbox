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
# 支持键（短键，亦可写 CAPBOX_ 前缀）：
#   DISTRO MIRROR MIRROR_ALPINE MIRROR_UBUNTU PROXY NET NET_ALLOW
#   HOSTNAME EXEC_TIMEOUT MEMORY_MAX CPU_MAX PIDS_MAX
#   PACKAGES   —— 逗号/空白分隔，apply 时 pkg install
#   INIT       —— 1/yes 时若 rootfs 未就绪则执行 init（默认 1）
# =============================================================================

readonly CAPBOX_RECIPE_KEYS=(
  DISTRO MIRROR MIRROR_ALPINE MIRROR_UBUNTU PROXY NET NET_ALLOW
  HOSTNAME EXEC_TIMEOUT BWRAP
  MEMORY_MAX CPU_MAX PIDS_MAX
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
    log_warn "recipe 忽略未知键: $key"
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
        log_warn "recipe 拒绝含展开符的双引号值: $key"
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
      log_warn "recipe 拒绝不安全的裸值: $key"
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
    [[ -f "$hint" ]] || die 2 "recipe 文件不存在: $hint"
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
  local line _recipe_key _recipe_val
  while IFS= read -r line || [[ -n "$line" ]]; do
    _recipe_key=""; _recipe_val=""
    if _recipe_parse_line "$line"; then
      _rl["$_recipe_key"]="$_recipe_val"
    fi
  done <"$file"
}

cmd_recipe() {
  local sub="${1:-apply}"
  case "$sub" in
    apply)
      shift || true
      _recipe_cmd_apply "$@"
      ;;
    show | cat)
      shift || true
      _recipe_cmd_show "$@"
      ;;
    -h | --help | help)
      cat <<'HELP'
用法: capbox recipe apply [FILE]
      capbox recipe show  [FILE]

  声明式 KEY=value 配方（不会被 source）。默认读：
    ./capbox.recipe  或  .capbox/recipe.env

  常用键: DISTRO PACKAGES NET NET_ALLOW MEMORY_MAX CPU_MAX PIDS_MAX MIRROR INIT
  apply：写入 config.env → 按需 init → 安装 PACKAGES
HELP
      return 0
      ;;
    *)
      # 无子命令时：若参数是文件则 apply，否则当 help
      if [[ -f "$sub" ]]; then
        _recipe_cmd_apply "$sub"
      else
        die 2 "用法: capbox recipe <apply|show> [FILE]"
      fi
      ;;
  esac
}

_recipe_cmd_show() {
  local f
  f="$(_recipe_find_file "${1:-}")" || die 2 "未找到 recipe（试 capbox.recipe 或 .capbox/recipe.env）"
  printf '# recipe: %s\n' "$f"
  cat -- "$f"
}

_recipe_cmd_apply() {
  local f do_init=1
  f="$(_recipe_find_file "${1:-}")" || die 2 "未找到 recipe（试 capbox.recipe 或 .capbox/recipe.env）"
  log_info "应用配方: $f"

  declare -A R=()
  _recipe_load_into "$f" R

  local k v
  for k in DISTRO MIRROR MIRROR_ALPINE MIRROR_UBUNTU PROXY NET NET_ALLOW HOSTNAME EXEC_TIMEOUT BWRAP MEMORY_MAX CPU_MAX PIDS_MAX; do
    [[ -n "${R[$k]+x}" ]] || continue
    v="${R[$k]}"
    if declare -F config_set >/dev/null 2>&1; then
      config_set "$k" "$v" || die 2 "recipe 配置无效: $k=$v"
    else
      die 1 "config_set 不可用"
    fi
  done

  case "${R[INIT]:-1}" in
    0 | false | False | no | NO | off | OFF) do_init=0 ;;
    *) do_init=1 ;;
  esac

  if (( do_init == 1 )); then
    if ! rootfs_ready 2>/dev/null; then
      log_info "recipe: rootfs 未就绪，执行 init"
      if declare -F cmd_init >/dev/null 2>&1; then
        local d="${R[DISTRO]:-$CAPBOX_DISTRO}"
        cmd_init --distro "$d" || return $?
      else
        die 1 "cmd_init 不可用"
      fi
    else
      if [[ -n "${R[DISTRO]:-}" && "${R[DISTRO]}" != "$CAPBOX_DISTRO" ]]; then
        cmd_init --distro "${R[DISTRO]}" || return $?
      fi
      log_info "recipe: rootfs 已就绪，跳过下载"
    fi
  fi

  if [[ -n "${R[PACKAGES]:-}" ]]; then
    local pkgs=() raw
    raw="${R[PACKAGES]//,/ }"
    read -r -a pkgs <<<"$raw"
    if [[ ${#pkgs[@]} -gt 0 ]]; then
      log_info "recipe: 安装软件包: ${pkgs[*]}"
      if declare -F cmd_pkg >/dev/null 2>&1; then
        cmd_pkg install -- "${pkgs[@]}" || return $?
      else
        die 1 "cmd_pkg 不可用"
      fi
    fi
  fi

  log_info "配方应用完成"
  return 0
}
