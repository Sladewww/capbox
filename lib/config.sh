# shellcheck shell=bash
# Configuration parsing, validation and persistence. Never source project data.

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
        log_err "CAPBOX_DISTRO 只能是 alpine 或 ubuntu（当前: '$v'）"
        return 2
      }
      ;;
    MIRROR)
      [[ "$v" == "cn" || "$v" == "global" || "$v" == "none" ]] || {
        log_err "CAPBOX_MIRROR 只能是 cn / global / none（当前: '$v'）"
        return 2
      }
      ;;
    NET)
      [[ "$v" == "host" || "$v" == "open" || "$v" == "none" || "$v" == "restricted" ]] || {
        log_err "CAPBOX_NET 只能是 none / restricted / open（host 为 open 的兼容别名；当前: '$v'）"
        return 2
      }
      ;;
    NET_ALLOW)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[A-Za-z0-9._:,/*-]+$ ]] || {
          log_err "CAPBOX_NET_ALLOW 只能包含域名/IP/逗号/冒号/斜线/星号（当前: '$v'）"
          return 2
        }
      fi
      ;;
    MEMORY_MAX)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[0-9]+([KkMmGg]i?[Bb]?)?$ ]] || {
          log_err "CAPBOX_MEMORY_MAX 格式无效（例 512M / 1G；当前: '$v'）"
          return 2
        }
      fi
      ;;
    CPU_MAX)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[0-9]+%$ || "$v" =~ ^[0-9]+[[:space:]]+[0-9]+$ || "$v" == "max" ]] || {
          log_err "CAPBOX_CPU_MAX 格式无效（例 50% 或 '50000 100000'；当前: '$v'）"
          return 2
        }
      fi
      ;;
    PIDS_MAX)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[0-9]+$ ]] || {
          log_err "CAPBOX_PIDS_MAX 必须是正整数（当前: '$v'）"
          return 2
        }
      fi
      ;;
    EXEC_TIMEOUT)
      [[ "$v" =~ ^[0-9]+$ ]] || {
        log_err "CAPBOX_EXEC_TIMEOUT 必须是非负整数秒（当前: '$v'）"
        return 2
      }
      ;;
    PROXY)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^(https?|socks5h?)://[^[:space:]]+$ ]] || {
          log_err "CAPBOX_PROXY 必须是 http:// https:// socks5:// socks5h:// 之一开头，或留空表示直连（当前: '$v'）"
          return 2
        }
      fi
      ;;
    HOSTNAME)
      [[ "$v" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || {
        log_err "CAPBOX_HOSTNAME 只能是字母数字与 . -（当前: '$v'）"
        return 2
      }
      ;;
    MIRROR_ALPINE | MIRROR_UBUNTU)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^https?://[^[:space:]]+$ ]] || {
          log_err "CAPBOX_$k 必须是 http(s):// 开头的 URL（当前: '$v'）"
          return 2
        }
      fi
      ;;
    BWRAP)
      [[ -n "$v" ]] || {
        log_err "CAPBOX_BWRAP 不能为空（bubblewrap 可执行文件路径）"
        return 2
      }
      ;;
    IDMAP)
      [[ "$v" == "auto" || "$v" == "on" || "$v" == "off" ]] || {
        log_err "CAPBOX_IDMAP 只能是 auto / on / off（当前: '$v'）"
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
            log_err "CAPBOX_$k 段须为 guest:host:count（当前段: '$part'）"
            return 2
          }
        done
      fi
      ;;
    SETGROUPS)
      if [[ -n "$v" ]]; then
        [[ "$v" == "allow" || "$v" == "deny" ]] || {
          log_err "CAPBOX_SETGROUPS 只能是 allow / deny（当前: '$v'）"
          return 2
        }
      fi
      ;;
    EXEC_UID | EXEC_GID)
      [[ "$v" =~ ^[0-9]+$ ]] || {
        log_err "CAPBOX_$k 必须是非负整数（当前: '$v'）"
        return 2
      }
      ;;
    DISK_MAX)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[0-9]+([KkMmGg]i?[Bb]?)?$ ]] || {
          log_err "CAPBOX_DISK_MAX 格式无效（例 1G；当前: '$v'）"
          return 2
        }
      fi
      ;;
    RESOURCES_MODE)
      [[ "$v" == "warn" || "$v" == "require" || "$v" == "strict" || "$v" == "fail-closed" || "$v" == "fail_closed" || -z "$v" ]] || {
        log_err "CAPBOX_RESOURCES_MODE 只能是 warn|require（当前: '$v'）"
        return 2
      }
      ;;
    SECURITY_PROFILE)
      [[ "$v" == "compat" || "$v" == "untrusted" || "$v" == "strict" || "$v" == "default" || -z "$v" ]] || {
        log_err "CAPBOX_SECURITY_PROFILE 只能是 compat|untrusted|strict（当前: '$v'）"
        return 2
      }
      ;;
    LANDLOCK)
      [[ "$v" == "on" || "$v" == "off" || -z "$v" ]] || {
        log_err "CAPBOX_LANDLOCK 只能是 on 或 off（当前: '$v'）。未设置时 strict 默认开启"
        return 2
      }
      ;;
    ROOTFS_RO)
      [[ "$v" == "0" || "$v" == "1" || "$v" == "true" || "$v" == "false" || "$v" == "yes" || "$v" == "no" || -z "$v" ]] || {
        log_err "CAPBOX_ROOTFS_RO 只能是 0/1（当前: '$v'）"
        return 2
      }
      ;;
    FS_HIDE)
      if [[ -n "$v" ]]; then
        [[ "$v" =~ ^[A-Za-z0-9._@+=,/-]+$ ]] || {
          log_err "CAPBOX_FS_HIDE 含非法字符（当前: '$v'）"
          return 2
        }
        [[ "$v" != *..* ]] || { log_err "CAPBOX_FS_HIDE 禁止 .."; return 2; }
      fi
      ;;
    FS_BINDS)
      if [[ -n "$v" ]]; then
        # 粗校验；细校验在 fsguard
        [[ "$v" =~ ^[A-Za-z0-9._@+=,:/-]+$ ]] || {
          log_err "CAPBOX_FS_BINDS 含非法字符（当前: '$v'）"
          return 2
        }
        [[ "$v" != *..* ]] || { log_err "CAPBOX_FS_BINDS 禁止 .."; return 2; }
      fi
      ;;
    OVERLAY)
      [[ "$v" == "0" || "$v" == "1" || "$v" == "auto" || "$v" == "on" || "$v" == "off" || -z "$v" ]] || {
        log_err "CAPBOX_OVERLAY 只能是 auto|0|1（当前: '$v'）"
        return 2
      }
      ;;
    AUDIT)
      [[ "$v" == "off" || "$v" == "summary" || "$v" == "full" || "$v" == "0" || "$v" == "1" || -z "$v" ]] || {
        log_err "CAPBOX_AUDIT 只能是 off|summary|full（当前: '$v'）"
        return 2
      }
      ;;
    AUDIT_CMD)
      [[ "$v" == "off" || "$v" == "summary" || "$v" == "full" || -z "$v" ]] || {
        log_err "CAPBOX_AUDIT_CMD 只能是 off|summary|full（当前: '$v'）"
        return 2
      }
      ;;
    ALLOW_OLD_BWRAP)
      [[ "$v" == "0" || "$v" == "1" ]] || {
        log_err "CAPBOX_ALLOW_OLD_BWRAP 只能是 0 或 1（当前: '$v'）。持久放行: capbox config set --yes CAPBOX_ALLOW_OLD_BWRAP 1"
        return 2
      }
      ;;
    *)
      log_err "未知配置项: CAPBOX_${k}"
      return 2
      ;;
  esac
  return 0
}

# 单引号安全转义，用于写 config.env
# 把任意字符串转成可安全嵌入 shell 命令的 POSIX 单引号形式。# 写回整个配置文件（保持 §2 的顺序与注释）
config_save() {
  local f="$CAPBOX_DIR/config.env" private tmp k v
  [[ ! -L "$f" && ( ! -e "$f" || -f "$f" ) ]] || {
    log_err "配置目标必须是普通文件: $f"; return 1;
  }
  mkdir -p -- "$CAPBOX_DIR" || return 1
  private="$(_capbox_host_state_dir)" || return 1
  tmp="$(mktemp "$private/config.XXXXXX")" || return 1
  {
    printf '# CapBox 配置（KEY=value；不作为 shell 执行；环境变量优先）\n'
    for k in "${CAPBOX_CFG_KEYS[@]}"; do
      v="$(_cfg_value_for_file "$k")"
      printf 'CAPBOX_%s=%s\n' "$k" "$(_shq "$v")"
    done
  } >"$tmp" || { rm -f -- "$tmp"; return 1; }
  # Keep the existing inode: long-lived guests have a read-only bind of it.
  # All values are validated before entering this single, serialized write.
  if ! cat -- "$tmp" >"$f"; then
    rm -f -- "$tmp"
    log_err "配置写入失败: $f"
    return 1
  fi
  rm -f -- "$tmp"
}

# Commit a complete, prevalidated batch under the same lock as config set.
_config_apply_locked() {
  local line _cfg_line_key="" _cfg_line_val="" k v
  if [[ -f "$CAPBOX_DIR/config.env" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if _cfg_parse_assignment_line "$line"; then
        k="$_cfg_line_key"
        [[ "${CAPBOX_CFG_EXPLICIT[$k]:-}" == env ]] && continue
        printf -v "CAPBOX_$k" '%s' "$_cfg_line_val"
        [[ "$k" != BWRAP ]] || CAPBOX_BWRAP_CFG="$_cfg_line_val"
      fi
    done <"$CAPBOX_DIR/config.env"
  fi
  while (( $# )); do
    k="$1"; v="$2"; shift 2
    printf -v "CAPBOX_$k" '%s' "$v"
    [[ "$k" != BWRAP ]] || CAPBOX_BWRAP_CFG="$v"
  done
  config_save
}

config_apply() {
  (( $# % 2 == 0 )) || { log_err '配置批次必须为键值对'; return 2; }
  (( $# > 0 )) || return 0
  local -a pairs=("$@")
  local k v
  while (( $# )); do
    k="$1"; v="$2"; shift 2
    _cfg_known "$k" || { log_err "未知配置项: $k"; return 2; }
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
        log_warn "config.env 拒绝含展开符的双引号值: $key"
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
      log_warn "config.env 拒绝不安全的裸值: $key"
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
    log_warn "忽略环境变量 CAPBOX_ALLOW_OLD_BWRAP=${CAPBOX_ALLOW_OLD_BWRAP}；持久放行只能写入 config.env，单次放行用 capbox --allow-old-bwrap"
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
  [[ -n "${CAPBOX_DISTRO:-}" ]] || { CAPBOX_DISTRO=alpine; log_warn "CAPBOX_DISTRO 为空，回退 alpine"; }
  [[ -n "${CAPBOX_MIRROR:-}" ]] || CAPBOX_MIRROR=cn
  [[ -n "${CAPBOX_NET:-}" ]] || CAPBOX_NET=open
  # host 为历史别名
  [[ "${CAPBOX_NET}" == "host" ]] && CAPBOX_NET=open
  case "${CAPBOX_NET}" in
    none | restricted | open) ;;
    *)
      die 2 "CAPBOX_NET 只能是 none / restricted / open（host 为 open 的别名；当前: '${CAPBOX_NET}'）。拒绝回退到 open"
      ;;
  esac

  [[ -n "${CAPBOX_HOSTNAME:-}" ]] || CAPBOX_HOSTNAME=capbox
  [[ "${CAPBOX_EXEC_TIMEOUT:-}" =~ ^[0-9]+$ ]] || CAPBOX_EXEC_TIMEOUT=600

  # 先固定「配置值」（来自 env / config.env / 内置默认），再解析运行时值
  : "${CAPBOX_BWRAP=/usr/bin/bwrap}"
  CAPBOX_BWRAP_CFG="$CAPBOX_BWRAP"

  _capbox_resolve_bwrap

  _capbox_derive_paths
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
    log_err "未知配置项: ${1:-}；可用: ${CAPBOX_CFG_KEYS[*]}"
    return 2
  }
  _cfg_validate "$k" "$v" || return 2
  if [[ "$k" == "ALLOW_OLD_BWRAP" && "$v" == "1" && "$confirm" != "1" ]]; then
    log_err "持久放行旧版 bwrap 需要 --yes（会写入审计日志；doctor 仍为 FAIL）"
    _capbox_print_old_bwrap_details
    return 2
  fi
  config_apply "$k" "$v" || return $?
  if [[ "$k" == "ALLOW_OLD_BWRAP" && "$v" == "1" ]]; then
    _capbox_bwrap_version_ok >/dev/null || true
    ver="${CAPBOX_BWRAP_VERSION:-未知}"
    [[ -n "$ver" ]] || ver="未知"
    if ! _capbox_audit_old_bwrap persist "$ver" "config set CAPBOX_ALLOW_OLD_BWRAP 1"; then
      log_err "无法写入旧版 bwrap 放行审计，已撤销 CAPBOX_ALLOW_OLD_BWRAP"
      CAPBOX_ALLOW_OLD_BWRAP=0
      CAPBOX_CFG_EXPLICIT["ALLOW_OLD_BWRAP"]="user"
      config_save
      _capbox_derive_paths
      return 1
    fi
  fi
  return 0
}

