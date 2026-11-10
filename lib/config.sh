# shellcheck shell=bash
# 配置解析、校验与持久化。绝不 source 项目数据。

# 配置项（不含 CAPBOX_ 前缀），config get/set/list 与文件读写都用这个顺序
readonly CAPBOX_CFG_KEYS=(
  DISTRO
  MIRROR
  MIRROR_ALPINE
  MIRROR_UBUNTU
  PROXY
  NET
  NET_ALLOW
  HOSTNAME
  EXEC_TIMEOUT
  MEMORY_MAX
  CPU_MAX
  PIDS_MAX
  DISK_MAX
  RESOURCES_MODE
  BWRAP
  IDMAP
  UID_MAP
  GID_MAP
  SETGROUPS
  EXEC_UID
  EXEC_GID
  SECURITY_PROFILE
  LANDLOCK
  ROOTFS_RO
  FS_HIDE
  FS_BINDS
  OVERLAY
  AUDIT
  AUDIT_CMD
  ALLOW_OLD_BWRAP
  LANG
)

# 哪些配置键来自“显式配置”（环境变量或 config.env），用于区分内置默认值与用户意图
declare -gA CAPBOX_CFG_EXPLICIT=()

# 把用户写的键名规范化成内部短键：capbox_distro / DISTRO / CAPBOX_DISTRO -> DISTRO
_cfg_norm_key() {
  local k="${1:-}"
  k="${k^^}"
  k="${k#CAPBOX_}"
  printf '%s' "$k"
}

_cfg_known() {
  local k="${1:-}" want
  for want in "${CAPBOX_CFG_KEYS[@]}"; do
    [[ "$k" == "$want" ]] && return 0
  done
  return 1
}

# 读取运行时生效值（供 status / doctor / 执行路径使用）
_cfg_value() {
  local k="${1:-}"
  local name="CAPBOX_$k"
  printf '%s' "${!name-}"
}

# 读取「应当写回 config.env 的值」。
# 绝大多数键运行时值就是配置值；唯独 BWRAP 的运行时值可能来自自动探测，
# 不能污染配置，所以单独取 CAPBOX_BWRAP_CFG。
_cfg_value_for_file() {
  local k="${1:-}"
  if [[ "$k" == "BWRAP" ]]; then
    printf '%s' "${CAPBOX_BWRAP_CFG:-${CAPBOX_BWRAP:-}}"
    return 0
  fi
  _cfg_value "$k"
}

# 校验取值；返回 0=合法，2=非法（并打印中文原因）
_cfg_validate() {
  local k="${1:-}" v="${2:-}"
  case "$k" in
    DISTRO)
      [[ "$v" == "alpine" || "$v" == "ubuntu" ]] || {
        i18n_err config.capbox_distro_must_alpine_ubuntu_got v="$v"
        return 2
      }
      ;;
    MIRROR)
      [[ "$v" == "cn" || "$v" == "global" || "$v" == "none" ]] || {
        i18n_err config.capbox_mirror_must_cn_global_none_got v="$v"
        return 2
      }
      ;;
    NET)
      [[ "$v" == "host" || "$v" == "open" || "$v" == "none" || "$v" == "restricted" ]] || {
        i18n_err config.capbox_net_must_none_restricted_open_host v="$v"
        return 2
      }
      ;;
    NET_ALLOW)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[A-Za-z0-9._:,/*-]+$ ]] || {
          i18n_err config.capbox_net_allow_may_only_contain_domain v="$v"
          return 2
        }
      fi
      ;;
    MEMORY_MAX)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[0-9]+([KkMmGg]i?[Bb]?)?$ ]] || {
          i18n_err config.invalid_capbox_memory_max_format_e_g v="$v"
          return 2
        }
      fi
      ;;
    CPU_MAX)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[0-9]+%$ || "$v" =~ ^[0-9]+[[:space:]]+[0-9]+$ || "$v" == "max" ]] || {
          i18n_err config.invalid_capbox_cpu_max_format_e_g v="$v"
          return 2
        }
      fi
      ;;
    PIDS_MAX)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[0-9]+$ ]] || {
          i18n_err config.capbox_pids_max_must_positive_integer_got v="$v"
          return 2
        }
      fi
      ;;
    EXEC_TIMEOUT)
      [[ "$v" =~ ^[0-9]+$ ]] || {
        i18n_err config.capbox_exec_timeout_must_non_negative_integer v="$v"
        return 2
      }
      ;;
    PROXY)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^(https?|socks5h?)://[^[:space:]]+$ ]] || {
          i18n_err config.capbox_proxy_must_start_http_https_socks5 v="$v"
          return 2
        }
      fi
      ;;
    HOSTNAME)
      [[ "$v" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || {
        i18n_err config.capbox_hostname_may_only_contain_letters_digits v="$v"
        return 2
      }
      ;;
    MIRROR_ALPINE | MIRROR_UBUNTU)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^https?://[^[:space:]]+$ ]] || {
          i18n_err config.capbox_must_url_starting_http_s_got k="$k" v="$v"
          return 2
        }
      fi
      ;;
    BWRAP)
      [[ -n "$v" ]] || {
        i18n_err config.capbox_bwrap_must_not_empty_path_bubblewrap
        return 2
      }
      ;;
    IDMAP)
      [[ "$v" == "auto" || "$v" == "on" || "$v" == "off" ]] || {
        i18n_err config.capbox_idmap_must_auto_off_got v="$v"
        return 2
      }
      ;;
    UID_MAP | GID_MAP)
      if [[ -n "$v" && "$v" != "auto" ]]; then
        local part
        local IFS=','
        for part in $v; do
          part="${part#"${part%%[![:space:]]*}"}"
          part="${part%"${part##*[![:space:]]}"}"
          [[ -z "$part" ]] && continue
          [[ "$part" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || {
            i18n_err config.capbox_segments_must_guest_host_count_current k="$k" part="$part"
            return 2
          }
        done
      fi
      ;;
    SETGROUPS)
      if [[ -n "$v" ]]; then
        [[ "$v" == "allow" || "$v" == "deny" ]] || {
          i18n_err config.capbox_setgroups_must_allow_deny_got v="$v"
          return 2
        }
      fi
      ;;
    EXEC_UID | EXEC_GID)
      [[ "$v" =~ ^[0-9]+$ ]] || {
        i18n_err config.capbox_must_non_negative_integer_got k="$k" v="$v"
        return 2
      }
      ;;
    DISK_MAX)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[0-9]+([KkMmGg]i?[Bb]?)?$ ]] || {
          i18n_err config.invalid_capbox_disk_max_format_e_g v="$v"
          return 2
        }
      fi
      ;;
    RESOURCES_MODE)
      [[ "$v" == "warn" || "$v" == "require" || "$v" == "strict" || "$v" == "fail-closed" || "$v" == "fail_closed" || -z "$v" ]] || {
        i18n_err config.capbox_resources_mode_must_warn_require_got v="$v"
        return 2
      }
      ;;
    SECURITY_PROFILE)
      [[ "$v" == "compat" || "$v" == "untrusted" || "$v" == "strict" || "$v" == "default" || -z "$v" ]] || {
        i18n_err config.capbox_security_profile_must_compat_untrusted_strict v="$v"
        return 2
      }
      ;;
    LANDLOCK)
      [[ "$v" == "on" || "$v" == "off" || -z "$v" ]] || {
        i18n_err config.capbox_landlock_must_off_got_when_unset v="$v"
        return 2
      }
      ;;
    ROOTFS_RO)
      [[ "$v" == "0" || "$v" == "1" || "$v" == "true" || "$v" == "false" || "$v" == "yes" || "$v" == "no" || -z "$v" ]] || {
        i18n_err config.capbox_rootfs_ro_must_0_1_got v="$v"
        return 2
      }
      ;;
    FS_HIDE)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[A-Za-z0-9._@+=,/-]+$ ]] || {
          i18n_err config.capbox_fs_hide_contains_illegal_characters_got v="$v"
          return 2
        }
        [[ "$v" != *..* ]] || { i18n_err config.capbox_fs_hide_must_not_contain; return 2; }
      fi
      ;;
    FS_BINDS)
      if [[ -n "$v" ]]; then
        # 粗校验；细校验在 fsguard
        [[ "$v" =~ ^[A-Za-z0-9._@+=,:/-]+$ ]] || {
          i18n_err config.capbox_fs_binds_contains_illegal_characters_got v="$v"
          return 2
        }
        [[ "$v" != *..* ]] || { i18n_err config.capbox_fs_binds_must_not_contain; return 2; }
      fi
      ;;
    OVERLAY)
      [[ "$v" == "0" || "$v" == "1" || "$v" == "auto" || "$v" == "on" || "$v" == "off" || -z "$v" ]] || {
        i18n_err config.capbox_overlay_must_auto_0_1_got v="$v"
        return 2
      }
      ;;
    AUDIT)
      [[ "$v" == "off" || "$v" == "summary" || "$v" == "full" || "$v" == "0" || "$v" == "1" || -z "$v" ]] || {
        i18n_err config.capbox_audit_must_off_summary_full_got v="$v"
        return 2
      }
      ;;
    AUDIT_CMD)
      [[ "$v" == "off" || "$v" == "summary" || "$v" == "full" || -z "$v" ]] || {
        i18n_err config.capbox_audit_cmd_must_off_summary_full v="$v"
        return 2
      }
      ;;
    ALLOW_OLD_BWRAP)
      [[ "$v" == "0" || "$v" == "1" ]] || {
        i18n_err config.capbox_allow_old_bwrap_must_0_1 v="$v"
        return 2
      }
      ;;
    LANG)
      if [[ -n "$v" ]]; then
        if ! _capbox_parse_lang_value "$v" >/dev/null; then
          printf '%s\n%s\n' \
            'CAPBOX_LANG 取值无效（仅支持 zh / en 及其区域形式，例如 zh_CN、en_US）。' \
            'Invalid CAPBOX_LANG (accepted values: zh / en and regional forms such as zh_CN, en_US).' >&2
          return 2
        fi
      fi
      ;;
    *)
      i18n_err config.unknown_config_key_capbox k="${k}"
      return 2
      ;;
  esac
  return 0
}

# 写回整个配置文件（保持 §2 的顺序与注释）
config_save() {
  local f="$CAPBOX_DIR/config.env" private tmp k v
  [[ ! -L "$f" && ( ! -e "$f" || -f "$f" ) ]] || {
    i18n_err config.config_target_must_regular_file f="$f"; return 1;
  }
  mkdir -p -- "$CAPBOX_DIR" || return 1
  private="$(_capbox_host_state_dir)" || return 1
  tmp="$(mktemp "$private/config.XXXXXX")" || return 1
  {
    printf '# CapBox 配置（KEY=value；不作为 shell 执行；环境变量优先）\n'
    for k in "${CAPBOX_CFG_KEYS[@]}"; do
      # 隐式 compat 默认值不得把 strict 的 rootfs 钉成可写。
      if [[ "$k" == ROOTFS_RO && -z "${CAPBOX_CFG_EXPLICIT[$k]:-}" ]]; then
        continue
      fi
      v="$(_cfg_value_for_file "$k")"
      printf 'CAPBOX_%s=%s\n' "$k" "$(_shq "$v")"
    done
  } >"$tmp" || { rm -f -- "$tmp"; return 1; }
  # 保留现有 inode：长寿命 guest 对其有只读 bind。
  # 所有值在进入这次串行写入前已校验。
  if ! cat -- "$tmp" >"$f"; then
    rm -f -- "$tmp"
    i18n_err config.failed_write_config f="$f"
    return 1
  fi
  rm -f -- "$tmp"
}

# 在与 config set 同一把锁下提交整批已校验配置。
_config_apply_locked() {
  local line _cfg_line_key="" _cfg_line_val="" k v
  if [[ -f "$CAPBOX_DIR/config.env" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if _cfg_parse_assignment_line "$line"; then
        k="$_cfg_line_key"
        [[ "${CAPBOX_CFG_EXPLICIT[$k]:-}" == env ]] && continue
        printf -v "CAPBOX_$k" '%s' "$_cfg_line_val"
        CAPBOX_CFG_EXPLICIT["$k"]=file
        [[ "$k" != BWRAP ]] || CAPBOX_BWRAP_CFG="$_cfg_line_val"
      fi
    done <"$CAPBOX_DIR/config.env"
  fi
  while (( $# )); do
    k="$1"; v="$2"; shift 2
    printf -v "CAPBOX_$k" '%s' "$v"
    CAPBOX_CFG_EXPLICIT["$k"]=user
    [[ "$k" != BWRAP ]] || CAPBOX_BWRAP_CFG="$v"
  done
  config_save
}

config_apply() {
  (( $# % 2 == 0 )) || { i18n_err config.config_batch_must_key_value_pairs; return 2; }
  (( $# > 0 )) || return 0
  local -a pairs=("$@")
  local k v
  while (( $# )); do
    k="$1"; v="$2"; shift 2
    _cfg_known "$k" || { i18n_err config.unknown_config_key k="$k"; return 2; }
    _cfg_validate "$k" "$v" || return 2
  done
  need_cmd flock '配置提交需要进程间锁'
  with_lock config -- _config_apply_locked "${pairs[@]}" || return $?
  set -- "${pairs[@]}"
  while (( $# )); do
    k="$1"; v="$2"; shift 2
    printf -v "CAPBOX_$k" '%s' "$v"
    CAPBOX_CFG_EXPLICIT["$k"]=user
    if [[ "$k" == BWRAP ]]; then
      CAPBOX_BWRAP_CFG="$v"
      _capbox_resolve_bwrap
    fi
  done
  _capbox_derive_paths
}

# 从 config.env 中粗解析出被赋值的键名列表（用于判断“显式配置”）
_cfg_file_keys() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 0
  sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\{0,1\}CAPBOX_\([A-Za-z0-9_]*\)=.*/\2/p' "$f" 2>/dev/null || true
}

# 解析 config.env 中一行 KEY=value（仅白名单 CAPBOX_*；不 source）
# 成功时设置 _cfg_line_key（短键）与 _cfg_line_val；失败返回 1。
_cfg_parse_assignment_line() {
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
  [[ "$key" == CAPBOX_* ]] || return 1
  short="$(_cfg_norm_key "$key")"
  _cfg_known "$short" || return 1

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
        _cfg_line_key="$short"
        _cfg_line_val="$out"
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
        i18n_warn config.config_env_rejected_double_quoted_value_containing key="$key"
        return 1
      fi
      _cfg_line_key="$short"
      _cfg_line_val="$inner"
      return 0
    fi
    return 1
  else
    if [[ "$raw" =~ ^(.*)[[:space:]]+#.*$ ]]; then
      raw="${BASH_REMATCH[1]}"
    fi
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [[ -n "$raw" && "$raw" =~ [\$\`\;\|\&\<\>\(\)\{\}[:space:]] ]]; then
      i18n_warn config.config_env_rejected_unsafe_bare_value key="$key"
      return 1
    fi
    _cfg_line_key="$short"
    _cfg_line_val="$raw"
    return 0
  fi
}

# 加载配置：顺序 = 内置默认值 < config.env（KEY=value 白名单）< 环境变量
# 安全：不再 `.` / source config.env（任意 shell → 宿主 RCE）。
load_config() {
  local f="$CAPBOX_DIR/config.env"
  local k v fk line
  local -a prot_keys=()
  local -a prot_vals=()
  local -A file_seen=()

  # ALLOW_OLD_BWRAP 不接受环境变量。父进程 export 不能打开或关闭持久放行。
  if [[ -n "${CAPBOX_ALLOW_OLD_BWRAP+x}" ]]; then
    i18n_warn config.ignoring_environment_variable_capbox_allow_old_bwrap value="${CAPBOX_ALLOW_OLD_BWRAP}"
    unset CAPBOX_ALLOW_OLD_BWRAP
  fi

  # 1) 记录调用前就存在的环境变量（最高优先级）
  for k in "${CAPBOX_CFG_KEYS[@]}"; do
    [[ "$k" == "ALLOW_OLD_BWRAP" ]] && continue
    if declare -p "CAPBOX_$k" >/dev/null 2>&1; then
      prot_keys+=("$k")
      prot_vals+=("$(_cfg_value "$k")")
    fi
  done

  # 读者与写者共享锁，因此原地保留 inode 的提交
  # 不会被其他 CLI 进程误当成空/半截配置。
  local config_fd="" private=""
  if [[ -d "$CAPBOX_DIR" ]]; then
    need_cmd flock '读取配置需要共享锁'
    private="$(_capbox_host_state_dir)" || i18n_die 1 config.unable_create_safe_config_lock_directory
    exec {config_fd}>"$private/config.lock" || i18n_die 1 config.unable_open_config_lock
    flock -s -w 180 "$config_fd" || i18n_die 1 config.timed_out_waiting_config_read_lock
  fi
  if [[ -e "$f" || -L "$f" ]]; then
    [[ -f "$f" && ! -L "$f" && -r "$f" ]] || i18n_die 2 config.config_must_readable_regular_file_refusing_continue
  fi

  # 2) 白名单解析配置文件（不 source）
  if [[ -r "$f" ]]; then
    local _cfg_line_key="" _cfg_line_val=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      _cfg_line_key=""; _cfg_line_val=""
      if _cfg_parse_assignment_line "$line"; then
        printf -v "CAPBOX_${_cfg_line_key}" '%s' "$_cfg_line_val"
        file_seen["${_cfg_line_key}"]=1
      fi
    done <"$f"
  fi

  if [[ -n "$config_fd" ]]; then
    flock -u "$config_fd"
    exec {config_fd}>&-
  fi

  # 3) 环境变量覆盖文件
  local i
  for i in "${!prot_keys[@]}"; do
    printf -v "CAPBOX_${prot_keys[$i]}" '%s' "${prot_vals[$i]}"
    CAPBOX_CFG_EXPLICIT["${prot_keys[$i]}"]="env"
  done

  # 4) 文件里出现过的键算显式配置（环境变量已覆盖的不重复标记）
  for fk in "${!file_seen[@]}"; do
    [[ -n "${CAPBOX_CFG_EXPLICIT[$fk]:-}" ]] || CAPBOX_CFG_EXPLICIT["$fk"]="file"
  done

  # 5) 内置默认值（仅在未设置时生效；空字符串是合法值，所以用 = 而不是 :=）
  : "${CAPBOX_DISTRO=alpine}"
  : "${CAPBOX_MIRROR=cn}"
  : "${CAPBOX_MIRROR_ALPINE=https://mirrors.aliyun.com/alpine}"
  : "${CAPBOX_MIRROR_UBUNTU=https://mirrors.aliyun.com/ubuntu}"
  : "${CAPBOX_PROXY=}"
  : "${CAPBOX_NET=open}"
  : "${CAPBOX_NET_ALLOW=}"
  : "${CAPBOX_MEMORY_MAX=}"
  : "${CAPBOX_CPU_MAX=}"
  : "${CAPBOX_PIDS_MAX=}"
  : "${CAPBOX_HOSTNAME=capbox}"
  : "${CAPBOX_EXEC_TIMEOUT=600}"
  : "${CAPBOX_IDMAP=auto}"
  : "${CAPBOX_UID_MAP=}"
  : "${CAPBOX_GID_MAP=}"
  : "${CAPBOX_SETGROUPS=}"
  : "${CAPBOX_EXEC_UID=0}"
  : "${CAPBOX_EXEC_GID=0}"
  : "${CAPBOX_DISK_MAX=}"
  : "${CAPBOX_RESOURCES_MODE=warn}"
  : "${CAPBOX_SECURITY_PROFILE=compat}"
  : "${CAPBOX_LANDLOCK=}"
  : "${CAPBOX_ROOTFS_RO=0}"
  : "${CAPBOX_FS_HIDE=}"
  : "${CAPBOX_FS_BINDS=}"
  : "${CAPBOX_OVERLAY=auto}"
  : "${CAPBOX_AUDIT=summary}"
  : "${CAPBOX_AUDIT_CMD=}"
  : "${CAPBOX_ALLOW_OLD_BWRAP=0}"

  # 空值兜底（配置文件写坏了也不至于炸）
  [[ -n "${CAPBOX_DISTRO:-}" ]] || { CAPBOX_DISTRO=alpine; i18n_warn config.capbox_distro_empty_falling_back_alpine; }
  [[ -n "${CAPBOX_MIRROR:-}" ]] || CAPBOX_MIRROR=cn
  [[ -n "${CAPBOX_NET:-}" ]] || CAPBOX_NET=open
  # host 为历史别名
  [[ "${CAPBOX_NET}" == "host" ]] && CAPBOX_NET=open
  case "${CAPBOX_NET}" in
    none | restricted | open) ;;
    *)
      i18n_die 2 config.capbox_net_must_none_restricted_open_host_2 net="${CAPBOX_NET}"
      ;;
  esac

  [[ -n "${CAPBOX_HOSTNAME:-}" ]] || CAPBOX_HOSTNAME=capbox
  [[ "${CAPBOX_EXEC_TIMEOUT:-}" =~ ^[0-9]+$ ]] || CAPBOX_EXEC_TIMEOUT=600

  # 先固定「配置值」（来自 env / config.env / 内置默认），再解析运行时值
  : "${CAPBOX_BWRAP=/usr/bin/bwrap}"
  CAPBOX_BWRAP_CFG="$CAPBOX_BWRAP"

  _capbox_resolve_bwrap

  _capbox_derive_paths

  # 语言在配置加载之后解析：进程环境 CAPBOX_LANG > config.env > locale
  if declare -F _capbox_resolve_lang >/dev/null 2>&1; then
    _capbox_resolve_lang
  fi
}

config_get() {
  local k
  k="$(_cfg_norm_key "${1:-}")"
  _cfg_known "$k" || return 2
  _cfg_value "$k"
  printf '\n'
}

config_set() {
  local k v confirm ver
  confirm="${CAPBOX_ALLOW_OLD_BWRAP_CONFIRM:-}"
  unset CAPBOX_ALLOW_OLD_BWRAP_CONFIRM
  k="$(_cfg_norm_key "${1:-}")"
  v="${2-}"
  _cfg_known "$k" || {
    i18n_err common.unknown_config_key_available arg="${1:-}" keys="${CAPBOX_CFG_KEYS[*]}"
    return 2
  }
  _cfg_validate "$k" "$v" || return 2
  if [[ "$k" == "ALLOW_OLD_BWRAP" && "$v" == "1" && "$confirm" != "1" ]]; then
    i18n_err config.persistent_allow_old_bwrap_requires_yes_audit
    _capbox_print_old_bwrap_details
    return 2
  fi
  config_apply "$k" "$v" || return $?
  if [[ "$k" == "ALLOW_OLD_BWRAP" && "$v" == "1" ]]; then
    _capbox_bwrap_version_ok >/dev/null || true
    ver="${CAPBOX_BWRAP_VERSION:-未知}"
    [[ -n "$ver" ]] || ver="未知"
    if ! _capbox_audit_old_bwrap persist "$ver" "config set CAPBOX_ALLOW_OLD_BWRAP 1"; then
      i18n_err config.unable_write_old_bwrap_allow_audit_record
      config_apply ALLOW_OLD_BWRAP 0 || return 1
      return 1
    fi
  fi
  return 0
}

