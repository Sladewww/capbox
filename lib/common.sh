# shellcheck shell=bash
# =============================================================================
# CapBox - common.sh
# 通用基础库：路径派生、配置读写、日志、错误、锁、小工具、bwrap 参数构造、
# doctor/status 兜底实现。
#
# 约定：
#   * 本文件由 bin/capbox 在最前面 source，source 完成后以下变量即可用：
#       CAPBOX_DIR CAPBOX_WORKSPACE CAPBOX_ROOTFS CAPBOX_DISTRO CAPBOX_DAEMON_DIR
#   * 所有脚本 `set -u` 友好：可选变量一律用 ${VAR:-} 取值。
#   * 用户可见信息一律中文。
# =============================================================================

# ---------- 0. 自身定位 -------------------------------------------------------

if [[ -z "${CAPBOX_DIR:-}" ]]; then
  # 兜底：从本文件位置推导（正常情况下 bin/capbox 已经设置好）
  _capbox_self_file="${BASH_SOURCE[0]:-$0}"
  CAPBOX_DIR="$(cd "$(dirname "$_capbox_self_file")/.." && pwd)"
  unset _capbox_self_file
fi
export CAPBOX_DIR
# 工作区推导（不得把「仓库即 CAPBOX_DIR」误判成父目录 /workspace）：
#   * 若调用方（bin/capbox）已设 CAPBOX_WORKSPACE，一律保留
#   * CAPBOX_DIR 以 /.capbox 结尾 → 工作区=其父目录（标准项目布局）
#   * 否则 CAPBOX_DIR 本身就是工作区（仓库即状态 / 开发树），禁止 dirname 落到 /
#     或 /workspace 这类宽绑定
if [[ -z "${CAPBOX_WORKSPACE:-}" ]]; then
  if [[ "$(basename -- "$CAPBOX_DIR")" == ".capbox" ]]; then
    CAPBOX_WORKSPACE="$(cd -- "$(dirname -- "$CAPBOX_DIR")" && pwd)"
  else
    CAPBOX_WORKSPACE="$CAPBOX_DIR"
  fi
fi
export CAPBOX_WORKSPACE

readonly CAPBOX_VERSION="0.3.0"
readonly CAPBOX_SCHEMA_VERSION="0.3.0"

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
  ROOTFS_RO
  FS_HIDE
  FS_BINDS
  OVERLAY
  AUDIT
  AUDIT_CMD
)

# 支持的发行版
readonly CAPBOX_SUPPORTED_DISTROS=(alpine ubuntu)

# 哪些配置键来自“显式配置”（环境变量或 config.env），用于区分内置默认值与用户意图
declare -gA CAPBOX_CFG_EXPLICIT=()

# ---------- 1. 日志 -----------------------------------------------------------

if [[ -t 2 ]]; then
  _C_RST=$'\033[0m'
  _C_DIM=$'\033[2m'
  _C_RED=$'\033[31m'
  _C_YEL=$'\033[33m'
  _C_GRN=$'\033[32m'
else
  _C_RST=""
  _C_DIM=""
  _C_RED=""
  _C_YEL=""
  _C_GRN=""
fi

log_info() {
  printf '%s[capbox]%s %s\n' "$_C_DIM" "$_C_RST" "$*" >&2
}

log_warn() {
  printf '%s[capbox] 警告:%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2
}

log_err() {
  printf '%s[capbox] 错误:%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2
}

log_debug() {
  [[ "${CAPBOX_DEBUG:-0}" == "1" ]] || return 0
  printf '%s[capbox] debug:%s %s\n' "$_C_DIM" "$_C_RST" "$*" >&2
}

log_ok() {
  printf '%s%s%s\n' "$_C_GRN" "$*" "$_C_RST"
}

# die CODE MSG...
die() {
  local code="${1:-1}"
  shift || true
  [[ $# -gt 0 ]] && log_err "$*"
  exit "$code"
}

# ---------- 2. 外部命令探测 ---------------------------------------------------

have_cmd() {
  [[ $# -ge 1 && -n "${1:-}" ]] || return 1
  command -v "$1" >/dev/null 2>&1
}

need_cmd() {
  local cmd="${1:-}"
  have_cmd "$cmd" || die 5 "缺少依赖命令: $cmd${2:+（$2）}"
}

# ---------- 3. 配置 -----------------------------------------------------------

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
  eval "printf '%s' \"\${CAPBOX_${k}-}\""
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
        [[ "$v" =~ ^[A-Za-z0-9._:,/\-]+$ ]] || {
          log_err "CAPBOX_NET_ALLOW 只能包含域名/IP/逗号/冒号/斜线（当前: '$v'）"
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
    *)
      log_err "未知配置项: CAPBOX_${k}"
      return 2
      ;;
  esac
  return 0
}

# 单引号安全转义，用于写 config.env
# 把任意字符串转成可安全嵌入 shell 命令的 POSIX 单引号形式。
# 用纯 bash 字符串替换实现（不经 sed/命令替换），避免末尾换行被吞掉。
_shq() {
  local s="${1-}"
  s="${s//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

# 把宿主上一个位于工作区内的绝对路径，换算成它在容器内的路径。
# 容器里 CAPBOX_WORKSPACE 被 bind 到 /workspace，因此：
#   /proj/.capbox/lib/x  -> /workspace/.capbox/lib/x
#   /proj/lib/x          -> /workspace/lib/x        （仓库直接放进工作区）
# 目标在工作区之外时返回空串（调用方应跳过，因为容器里看不到它）。
_guest_workspace_path() {
  local host_path="${1-}" ws="${CAPBOX_WORKSPACE%/}"
  [[ -n "$host_path" && -n "$ws" ]] || return 0
  if [[ "$host_path" == "$ws" ]]; then
    printf '/workspace'
  elif [[ "$host_path" == "$ws"/* ]]; then
    printf '/workspace/%s' "${host_path#"$ws"/}"
  fi
  return 0
}

# 写回整个配置文件（保持 §2 的顺序与注释）
config_save() {
  local f="$CAPBOX_DIR/config.env"
  local tmp="$f.tmp.$$"
  local k v
  {
    printf '# CapBox 配置（KEY=value；可手工编辑；环境变量优先级高于本文件）\n'
    printf '# 仅允许 CAPBOX_* 白名单键的 KEY=value（不会被 source）。由 `capbox config set` 维护。\n'
    for k in "${CAPBOX_CFG_KEYS[@]}"; do
      v="$(_cfg_value_for_file "$k")"
      printf 'CAPBOX_%s=%s\n' "$k" "$(_shq "$v")"
    done
  } >"$tmp" || die 1 "无法写入配置文件: $f"
  # 若目标已是普通文件则就地覆盖，保留 inode。
  # daemon 长寿场景下 bwrap 对 config.env 的 /dev/null 挂载钉在该 inode/路径上；
  # 若用 mv 替换，宿主命名空间外的 rename 会让 guest 重新看到可写的新文件（RW 工作区 bind）。
  if [[ -f "$f" && ! -L "$f" ]]; then
    cat "$tmp" >"$f" || { rm -f "$tmp"; die 1 "无法写入配置文件: $f"; }
    rm -f "$tmp"
  else
    mv -f "$tmp" "$f" || die 1 "无法写入配置文件: $f"
  fi
  log_debug "配置已写回: $f"
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

  # 1) 记录调用前就存在的环境变量（最高优先级）
  for k in "${CAPBOX_CFG_KEYS[@]}"; do
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
        eval "CAPBOX_${_cfg_line_key}=\${_cfg_line_val}"
        file_seen["${_cfg_line_key}"]=1
      fi
    done <"$f"
  fi

  # 3) 环境变量覆盖文件
  local i
  for i in "${!prot_keys[@]}"; do
    eval "CAPBOX_${prot_keys[$i]}=\${prot_vals[$i]}"
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
  : "${CAPBOX_ROOTFS_RO=0}"
  : "${CAPBOX_FS_HIDE=}"
  : "${CAPBOX_FS_BINDS=}"
  : "${CAPBOX_OVERLAY=auto}"
  : "${CAPBOX_AUDIT=summary}"
  : "${CAPBOX_AUDIT_CMD=}"

  # 空值兜底（配置文件写坏了也不至于炸）
  [[ -n "${CAPBOX_DISTRO:-}" ]] || { CAPBOX_DISTRO=alpine; log_warn "CAPBOX_DISTRO 为空，回退 alpine"; }
  [[ -n "${CAPBOX_MIRROR:-}" ]] || CAPBOX_MIRROR=cn
  [[ -n "${CAPBOX_NET:-}" ]] || CAPBOX_NET=open
  # host 为历史别名
  [[ "${CAPBOX_NET}" == "host" ]] && CAPBOX_NET=open
  [[ -n "${CAPBOX_HOSTNAME:-}" ]] || CAPBOX_HOSTNAME=capbox
  [[ "${CAPBOX_EXEC_TIMEOUT:-}" =~ ^[0-9]+$ ]] || CAPBOX_EXEC_TIMEOUT=600

  # 先固定「配置值」（来自 env / config.env / 内置默认），再解析运行时值
  : "${CAPBOX_BWRAP=/usr/bin/bwrap}"
  CAPBOX_BWRAP_CFG="$CAPBOX_BWRAP"

  _capbox_resolve_bwrap

  _capbox_derive_paths
}

# 解析 bwrap 实际可执行文件路径。
# 背景：契约 §2 的内置默认值写作 /usr/bin/bwrap，但部分发行版只提供
# /usr/sbin/bwrap（PATH 里 sbin 在前，属同一份二进制）。为满足
# 「status 报告的就是实际执行的」，规则按优先级：
#   1) 环境变量显式指定              -> 原样使用（最高优先级）
#   2) config.env 写了自定义路径      -> 用它（不可执行则警告并降级）
#   3) PATH 自动发现 command -v bwrap
#   4) 都没有 -> 内置默认 /usr/bin/bwrap
# 其中「值等于内置默认」视为未自定义，以便自动发现更准确的路径。
# 解析 bwrap 实际可执行文件路径。
# 背景：契约 §2 的内置默认值写作 /usr/bin/bwrap，但部分发行版只提供
# /usr/sbin/bwrap（PATH 里 sbin 在前，属同一份二进制）。为满足
# 「status 报告的就是实际执行的」，规则按优先级：
#   1) 环境变量显式指定              -> 原样使用（最高优先级）
#   2) config.env 写了自定义路径      -> 用它（不可执行则警告并降级）
#   3) PATH 自动发现 command -v bwrap
#   4) 都没有 -> 内置默认 /usr/bin/bwrap
# 其中「值等于内置默认」视为未自定义，以便自动发现更准确的路径。
#
# 关键：解析结果写进 CAPBOX_BWRAP（运行时值，供所有 exec 使用），
# 而**配置值**必须单独留在 CAPBOX_BWRAP_CFG 里供 config_save 写回文件。
# 两者混用会导致任何一次 `config set` 都把自动探测结果持久化进 config.env，
# 让契约默认值被悄悄替换（曾经发生过）。
_capbox_resolve_bwrap() {
  local builtin="/usr/bin/bwrap"
  local cfg_val="${CAPBOX_BWRAP_CFG:-}"
  case "${CAPBOX_CFG_EXPLICIT[BWRAP]:-}" in
    env)
      CAPBOX_BWRAP_CFG="${CAPBOX_BWRAP_CFG:-$cfg_val}"
      ;;
  esac

  # 用户写了非默认值 -> 尊重之（不可执行时告警并降级到自动发现）
  if [[ -n "$cfg_val" && "$cfg_val" != "$builtin" ]]; then
    if [[ -x "$cfg_val" ]]; then
      CAPBOX_BWRAP="$cfg_val"
      return 0
    fi
    log_warn "配置的 CAPBOX_BWRAP=$cfg_val 不可执行，尝试自动发现"
  fi

  local found
  found="$(command -v bwrap 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    CAPBOX_BWRAP="$found"
    return 0
  fi

  CAPBOX_BWRAP="${cfg_val:-$builtin}"
}

# 由 CAPBOX_DISTRO 派生全部路径
_capbox_derive_paths() {
  CAPBOX_OS_DIR="$CAPBOX_DIR/os"
  CAPBOX_ROOTFS="$CAPBOX_OS_DIR/${CAPBOX_DISTRO:-alpine}"
  CAPBOX_BIN_DIR="$CAPBOX_DIR/bin"
  CAPBOX_LIB_DIR="$CAPBOX_DIR/lib"
  CAPBOX_GUEST_DIR="$CAPBOX_LIB_DIR/guest"
  CAPBOX_CACHE_DIR="$CAPBOX_DIR/cache"
  CAPBOX_LOG_DIR="$CAPBOX_DIR/logs"
  CAPBOX_STATE_DIR="$CAPBOX_DIR/state"
  CAPBOX_RUN_DIR="$CAPBOX_DIR/run"
  CAPBOX_DAEMON_DIR="$CAPBOX_RUN_DIR/daemon"
  CAPBOX_TMP_DIR="$CAPBOX_RUN_DIR/tmp"
  CAPBOX_TEST_DIR="$CAPBOX_DIR/test"
  export CAPBOX_ROOTFS CAPBOX_DAEMON_DIR
}

config_get() {
  local k
  k="$(_cfg_norm_key "${1:-}")"
  _cfg_known "$k" || return 2
  _cfg_value "$k"
  printf '\n'
}

config_set() {
  local k v
  k="$(_cfg_norm_key "${1:-}")"
  v="${2-}"
  _cfg_known "$k" || {
    log_err "未知配置项: ${1:-}；可用: ${CAPBOX_CFG_KEYS[*]}"
    return 2
  }
  _cfg_validate "$k" "$v" || return 2
  eval "CAPBOX_${k}=\${v}"
  CAPBOX_CFG_EXPLICIT["$k"]="user"
  if [[ "$k" == "BWRAP" ]]; then
    CAPBOX_BWRAP_CFG="$v"
    _capbox_resolve_bwrap
  fi
  config_save
  # 派生路径可能变化（例如切 distro）
  _capbox_derive_paths
  return 0
}

# ---------- 4. 目录与路径工具 -------------------------------------------------

ensure_dirs() {
  local d
  for d in bin lib lib/guest cache logs os run run/daemon run/tmp state test services; do
    mkdir -p "$CAPBOX_DIR/$d" 2>/dev/null || true
  done
}

# 把相对路径转成规范化绝对路径（不做存在性校验）
resolve_path() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1
  if have_cmd realpath; then
    realpath -m -- "$p" 2>/dev/null || printf '%s\n' "$p"
  else
    case "$p" in
      /*) printf '%s\n' "$p" ;;
      *) printf '%s/%s\n' "$PWD" "$p" ;;
    esac
  fi
}

# 工作区是否危险（等于 $HOME 或 /）——会把整棵家目录 RW bind 进容器
_capbox_workspace_is_dangerous() {
  local ws home
  ws="$(resolve_path "${CAPBOX_WORKSPACE:-}")"
  [[ -n "$ws" ]] || return 0
  [[ "$ws" == "/" ]] && return 0
  home="${HOME:-}"
  if [[ -n "$home" ]]; then
    home="$(resolve_path "$home")"
    [[ "$ws" == "$home" ]] && return 0
  fi
  return 1
}

_capbox_require_safe_workspace() {
  if _capbox_workspace_is_dangerous; then
    die 1 "拒绝：工作区解析为危险路径 (${CAPBOX_WORKSPACE:-})。请在项目下使用 .capbox/，或设置 CAPBOX_ROOT=/path/to/project（不要把 CapBox 装在 \$HOME 下作为全局 CLI，以免绑定整个家目录）。"
  fi
}

# 确保 guest 侧绝对路径落在 CAPBOX_ROOTFS 之内（防 .. 穿越与越界 symlink）
# 打印规范化后的宿主绝对路径；越界则返回 1。
_capbox_guest_path_in_rootfs() {
  local guest_path="${1:-}" root resolved
  [[ -n "$guest_path" ]] || return 1
  [[ -n "${CAPBOX_ROOTFS:-}" ]] || return 1
  root="$(resolve_path "$CAPBOX_ROOTFS")"
  case "$guest_path" in
    /*) resolved="$(resolve_path "$CAPBOX_ROOTFS$guest_path")" ;;
    *) resolved="$(resolve_path "$CAPBOX_ROOTFS/$guest_path")" ;;
  esac
  if [[ "$resolved" == "$root" || "$resolved" == "$root"/* ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  return 1
}

# 向 bwrap 参数数组追加：对工作区内的 bin/ lib/ config.env / services 做 --ro-bind，
# 防止 guest 改写 CLI 或注入宿主下次会读取的配置（含「启动时缺失」路径，见 CVE-2026-25725 同类）。
# 用法：_capbox_append_ro_cli_binds <array_name>
#
# 缺失路径策略（bwrap 只能通过挂载拒绝写入）：
#   * 文件：若受保护文件不存在，先在宿主创建空的普通文件作为挂载点，再 --ro-bind；
#     对「本函数刚创建的空挂载点」优先 --ro-bind /dev/null，避免 guest 读到/改到宿主内容。
#   * 目录：若 services/ 不存在则 mkdir，再整目录 --ro-bind（只读），阻止创建 *.env。
# 不持久化攻击者内容；空挂载点由 CapBox 自己创建。符号链接无法作为挂载目标（doctor 会警告）。

_capbox_note_fs_placeholder() {
  local p="${1:-}" kind="${2:-file}"
  local dir marker
  [[ -n "$p" && -n "${CAPBOX_RUN_DIR:-}" ]] || return 0
  dir="$CAPBOX_RUN_DIR/fs-placeholders"
  mkdir -p "$dir" 2>/dev/null || return 0
  marker="$dir/$(printf '%s' "$p" | sha256sum | awk '{print $1}')"
  printf '%s\t%s\n' "$kind" "$p" >"$marker" 2>/dev/null || true
}

# 清理本进程创建的空挂载点（oneshot 结束后调用；不删非空/已有真实配置）
_capbox_cleanup_fs_placeholders() {
  local dir marker kind path
  dir="${CAPBOX_RUN_DIR:-}/fs-placeholders"
  [[ -d "$dir" ]] || return 0
  for marker in "$dir"/*; do
    [[ -f "$marker" ]] || continue
    kind="$(cut -f1 "$marker" 2>/dev/null || true)"
    path="$(cut -f2- "$marker" 2>/dev/null || true)"
    rm -f -- "$marker" 2>/dev/null || true
    [[ -n "$path" ]] || continue
    case "$kind" in
      file)
        if [[ -f "$path" && ! -L "$path" && ! -s "$path" ]]; then
          rm -f -- "$path" 2>/dev/null || true
        fi
        ;;
      dir)
        if [[ -d "$path" && ! -L "$path" ]]; then
          rmdir -- "$path" 2>/dev/null || true
        fi
        ;;
    esac
  done
  rmdir -- "$dir" 2>/dev/null || true
}

# 保护单个宿主文件：已存在则 RO；缺失则预占挂载点（空文件）再 RO /dev/null
_capbox_ro_protect_host_file() {
  local host_file="${1:-}"
  local -n _pf_arr="$2"
  local guest_path parent created=0

  [[ -n "$host_file" ]] || return 0
  guest_path="$(_guest_workspace_path "$host_file")"
  [[ -n "$guest_path" && "$guest_path" == /workspace/* ]] || return 0

  parent="$(dirname -- "$host_file")"
  if [[ ! -d "$parent" ]]; then
    case "$parent" in
      "${CAPBOX_DIR}" | "${CAPBOX_DIR}"/*)
        mkdir -p "$parent" 2>/dev/null || return 0
        ;;
      *) return 0 ;;
    esac
  fi

  if [[ -L "$host_file" ]]; then
    log_warn "受保护配置路径是符号链接，无法预占只读挂载: $host_file"
    return 0
  fi
  if [[ -d "$host_file" ]]; then
    log_warn "受保护配置路径是目录，跳过文件预占: $host_file"
    return 0
  fi

  if [[ ! -e "$host_file" ]]; then
    if ! ( umask 077; : >"$host_file" ) 2>/dev/null; then
      log_warn "无法为缺失配置创建挂载点: $host_file"
      return 0
    fi
    created=1
    _capbox_note_fs_placeholder "$host_file" file
  fi

  # 始终用 /dev/null 覆盖目标路径，而不是 --ro-bind 真实文件：
  # 宿主 config_save 会用 mv 替换 inode；若 bind 的是旧 inode，daemon 长寿挂载下
  # 新文件会重新暴露在 RW 的 /workspace 视图里（可被 guest 写入）。
  # /dev/null 挂载钉在路径上，不受宿主侧替换影响；guest 也不需要读 config.env。
  _pf_arr+=(--ro-bind /dev/null "$guest_path")
}

# 保护宿主目录（整树只读）：缺失则创建空目录再 RO bind
_capbox_ro_protect_host_dir() {
  local host_dir="${1:-}"
  local -n _pd_arr="$2"
  local guest_path parent

  [[ -n "$host_dir" ]] || return 0
  guest_path="$(_guest_workspace_path "$host_dir")"
  [[ -n "$guest_path" && "$guest_path" == /workspace/* ]] || return 0

  if [[ -L "$host_dir" ]]; then
    log_warn "受保护目录是符号链接，无法只读挂载: $host_dir"
    return 0
  fi
  if [[ -f "$host_dir" ]]; then
    log_warn "受保护目录路径上存在普通文件，跳过: $host_dir"
    return 0
  fi

  if [[ ! -d "$host_dir" ]]; then
    parent="$(dirname -- "$host_dir")"
    if [[ ! -d "$parent" ]]; then
      case "$parent" in
        "${CAPBOX_DIR}" | "${CAPBOX_DIR}"/*)
          mkdir -p "$parent" 2>/dev/null || return 0
          ;;
        *) return 0 ;;
      esac
    fi
    mkdir -p "$host_dir" 2>/dev/null || return 0
    _capbox_note_fs_placeholder "$host_dir" dir
  fi

  _pd_arr+=(--ro-bind "$host_dir" "$guest_path")
}

_capbox_append_ro_cli_binds() {
  local -n _ro_arr="$1"
  local host_path guest_path cap_guest sub sub_host sub_guest

  # 标准布局（…/.capbox）：整树只读，再把运行时目录 RW 挂回。
  # 这样即使宿主在 daemon 生命周期内 rm+重建 config.env，guest 也无法在只读树上创建。
  # CI/开发「仓库即 CAPBOX_DIR」布局不能整树只读（那会锁死整个 /workspace）。
  if [[ -n "${CAPBOX_DIR:-}" && -d "$CAPBOX_DIR" && "$(basename -- "$CAPBOX_DIR")" == ".capbox" ]]; then
    cap_guest="$(_guest_workspace_path "$CAPBOX_DIR")"
    if [[ -n "$cap_guest" && "$cap_guest" == /workspace/* ]]; then
      _ro_arr+=(--ro-bind "$CAPBOX_DIR" "$cap_guest")
      for sub in run cache; do
        sub_host="$CAPBOX_DIR/$sub"
        mkdir -p "$sub_host" 2>/dev/null || true
        [[ -d "$sub_host" ]] || continue
        sub_guest="$(_guest_workspace_path "$sub_host")"
        [[ -n "$sub_guest" && "$sub_guest" == /workspace/* ]] || continue
        _ro_arr+=(--bind "$sub_host" "$sub_guest")
      done
      # 仍对 config.env 钉 /dev/null，避免通过已存在挂载点做内容注入的歧义
      _capbox_ro_protect_host_file "$CAPBOX_DIR/config.env" _ro_arr
      return 0
    fi
  fi

  # 回退：逐项保护 bin/ lib/ config.env / services
  for host_path in "${CAPBOX_BIN_DIR:-}" "${CAPBOX_LIB_DIR:-}"; do
    [[ -n "$host_path" && -d "$host_path" ]] || continue
    guest_path="$(_guest_workspace_path "$host_path")"
    [[ -n "$guest_path" ]] || continue
    _ro_arr+=(--ro-bind "$host_path" "$guest_path")
  done
  _capbox_ro_protect_host_file "${CAPBOX_DIR:-}/config.env" _ro_arr
  _capbox_ro_protect_host_dir "${CAPBOX_DIR:-}/services" _ro_arr
}

json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

human_bytes() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  local units=(B KB MB GB TB PB)
  local i=0
  while (( b >= 1024 && i < 5 )); do
    b=$(( b / 1024 ))
    i=$(( i + 1 ))
  done
  printf '%d%s' "$b" "${units[$i]}"
}

# 目录字节数（不存在输出 0）
dir_bytes() {
  local d="${1:-}"
  if [[ -n "$d" && -d "$d" ]]; then
    du -sb -- "$d" 2>/dev/null | cut -f1
  else
    printf '0'
  fi
}

# 只删自己作用域内的目录内容，防止变量为空导致误删
_safe_rm_dir_contents() {
  local d="${1:-}"
  [[ -n "$d" && -d "$d" ]] || return 0
  case "$d" in
    "$CAPBOX_DIR"/*) ;;
    *)
      log_warn "拒绝清理工作区之外的路径: $d"
      return 1
      ;;
  esac
  find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
}

# 删除 rootfs（严格限定在 os/ 下）
_safe_rm_rootfs() {
  local d="${1:-}"
  [[ -n "$d" && -d "$d" ]] || return 0
  case "$d" in
    "$CAPBOX_DIR"/os/*) ;;
    *)
      log_err "拒绝删除: $d 不在 $CAPBOX_DIR/os/ 之下"
      return 1
      ;;
  esac
  log_info "删除 rootfs: $d"
  rm -rf -- "$d"
}

# ---------- 5. 锁 -------------------------------------------------------------

# with_lock NAME -- CMD...   用 flock 串行化 init / daemon 等有副作用的操作
with_lock() {
  local name="${1:-}"
  [[ $# -gt 0 ]] && shift
  [[ "${1:-}" == "--" ]] && shift
  [[ $# -gt 0 ]] || die 2 "with_lock: 缺少要执行的命令"
  local lockfile="$CAPBOX_DIR/run/${name:-default}.lock"
  mkdir -p "$CAPBOX_DIR/run" 2>/dev/null || true
  if have_cmd flock; then
    (
      flock -w 180 9 || {
        log_err "等待锁超时: $lockfile"
        exit 1
      }
      "$@"
    ) 9>"$lockfile"
  else
    log_debug "宿主无 flock，跳过加锁: $name"
    "$@"
  fi
}

# ---------- 6. resolv.conf ----------------------------------------------------

# 把宿主 resolv.conf 拷成普通文件放到 state/（宿主上它常是符号链接，不能直接 bind）
refresh_resolv() {
  local dst="$CAPBOX_STATE_DIR/resolv.conf"
  local src="/etc/resolv.conf"
  local tmp="$dst.tmp.$$"
  local ns bad=1

  mkdir -p "$CAPBOX_STATE_DIR" 2>/dev/null || true

  if [[ -r "$src" ]]; then
    {
      printf '# 由 capbox 从宿主 /etc/resolv.conf 复制（%s）\n' "$(date '+%Y-%m-%d %H:%M:%S')"
      cat "$src" 2>/dev/null || true
    } >"$tmp" 2>/dev/null || true
  else
    printf '# 宿主 /etc/resolv.conf 不可读，使用公共 DNS 兜底\n' >"$tmp" 2>/dev/null || true
  fi

  if [[ ! -s "$tmp" ]]; then
    printf '# 宿主无可用 resolv.conf，使用公共 DNS 兜底\n' >"$tmp"
  fi

  # 只有回环地址的 nameserver 时补一个公共 DNS（容器内 127.* 不一定可达）
  while IFS= read -r ns; do
    [[ -n "$ns" ]] || continue
    case "$ns" in
      127.* | ::1) ;;
      *) bad=0 ;;
    esac
  done < <(awk '/^[[:space:]]*nameserver/ { print $2 }' "$tmp" 2>/dev/null)

  if (( bad == 1 )); then
    printf 'nameserver 223.5.5.5\nnameserver 1.1.1.1\n' >>"$tmp"
  fi

  chmod 0644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dst" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    log_warn "无法生成 $dst"
    return 1
  }
  log_debug "已刷新 $dst"
  return 0
}

# ---------- 7. 镜像源 URL -----------------------------------------------------

# 全局镜像站（CAPBOX_MIRROR=global 且用户未显式指定具体 URL 时使用）
_mirror_global_url() {
  case "${1:-}" in
    alpine) printf '%s' "https://dl-cdn.alpinelinux.org/alpine" ;;
    ubuntu) printf '%s' "http://archive.ubuntu.com/ubuntu" ;;
    *) printf '%s' "" ;;
  esac
}

# 解析某发行版应使用的镜像根 URL；CAPBOX_MIRROR=none 时输出空
mirror_url_for() {
  local distro="${1:-$CAPBOX_DISTRO}"
  [[ "${CAPBOX_MIRROR:-}" == "none" ]] && {
    printf '%s' ""
    return 0
  }
  local key url
  case "$distro" in
    alpine)
      key="MIRROR_ALPINE"
      url="$CAPBOX_MIRROR_ALPINE"
      ;;
    ubuntu)
      key="MIRROR_UBUNTU"
      url="$CAPBOX_MIRROR_UBUNTU"
      ;;
    *)
      printf '%s' ""
      return 0
      ;;
  esac
  if [[ "${CAPBOX_MIRROR:-}" == "global" && -z "${CAPBOX_CFG_EXPLICIT[$key]:-}" ]]; then
    url="$(_mirror_global_url "$distro")"
  fi
  printf '%s' "${url%/}"
}

# 判断 rootfs 内是否缺少可用 CA 证书
_rootfs_lacks_ca() {
  local d="${1:-$CAPBOX_ROOTFS}/etc/ssl/certs"
  [[ -d "$d" ]] || return 0
  [[ -e "$d/ca-certificates.crt" ]] && return 1
  local f
  for f in "$d"/*.pem; do
    [[ -e "$f" ]] && return 1
  done
  return 0
}

# 精简 rootfs 常常没有 CA；https 源会因此失败，降级成 http（契约 §6 的做法）
_http_safe_url() {
  local distro="${1:-$CAPBOX_DISTRO}" url="${2:-}"
  local rootfs="$CAPBOX_DIR/os/$distro"
  [[ -n "$url" ]] || {
    printf '%s' ""
    return 0
  }
  if [[ "$url" == https://* ]] && _rootfs_lacks_ca "$rootfs"; then
    log_debug "$distro rootfs 内无 CA 证书，镜像源降级为 http: $url"
    printf 'http://%s' "${url#https://}"
    return 0
  fi
  printf '%s' "$url"
}

# ---------- 8. bwrap 参数构造 -------------------------------------------------

# 容器内目录是否存在（/workspace 是 bind 进来的，单独判断）
_container_dir_exists() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1
  case "$p" in
    /workspace | /workspace/*) return 0 ;;
  esac
  [[ -d "$CAPBOX_ROOTFS$p" ]]
}

# 保证容器内后续要被挂载/使用的目录存在
ensure_rootfs_dirs() {
  local r="${1:-$CAPBOX_ROOTFS}"
  [[ -n "$r" ]] || return 0
  local d
  for d in proc sys dev tmp run root etc workspace var var/log var/lib/capbox-data home mnt; do
    mkdir -p "$r/$d" 2>/dev/null || true
  done
  mkdir -p "$r/etc/apk" "$r/etc/profile.d" "$r/etc/apt/apt.conf.d" "$r/etc/ssl/certs" 2>/dev/null || true
  mkdir -p "$CAPBOX_TMP_DIR" 2>/dev/null || true
}

# build_bwrap_args MODE [CWD]
#   MODE = oneshot | daemon
# 打印 bwrap 参数，一行一个（数组语义），不含最终的 `-- 命令` 部分。
build_bwrap_args() {
  local mode="${1:-oneshot}"
  local cwd="${2:-/workspace}"
  local -a a=()

  [[ -n "${CAPBOX_ROOTFS:-}" && -d "$CAPBOX_ROOTFS" ]] || return 4

  # ---- 文件系统 ----
  if declare -F _fsguard_apply_rootfs_mount >/dev/null 2>&1; then
    _fsguard_apply_rootfs_mount a
  else
    a+=(--bind "$CAPBOX_ROOTFS" /)
  fi
  a+=(--proc /proc)
  a+=(--dev /dev)
  if [[ "$mode" == "daemon" ]]; then
    # daemon 模式下 /tmp 持久化到工作区
    mkdir -p "$CAPBOX_TMP_DIR" 2>/dev/null || true
    a+=(--bind "$CAPBOX_TMP_DIR" /tmp)
  else
    a+=(--tmpfs /tmp)
  fi
  a+=(--tmpfs /run)
  a+=(--bind "$CAPBOX_WORKSPACE" /workspace)
  # 覆盖式只读挂载：防止 guest 改写宿主侧 CLI / 配置（下次执行 = RCE）
  _capbox_append_ro_cli_binds a
  # FS hide / 额外 binds（拒绝工作区外任意 bind）
  if declare -F _fsguard_append_bwrap_args >/dev/null 2>&1; then
    _fsguard_append_bwrap_args a || return $?
  fi

  # resolv.conf：必须是普通文件（宿主上是符号链接）
  refresh_resolv >/dev/null 2>&1 || true
  if [[ -f "$CAPBOX_STATE_DIR/resolv.conf" ]]; then
    a+=(--ro-bind "$CAPBOX_STATE_DIR/resolv.conf" /etc/resolv.conf)
  fi

  # CA 证书：rootfs 内没有就借用宿主的（坑 7）
  if _rootfs_lacks_ca && [[ -d /etc/ssl/certs ]]; then
    mkdir -p "$CAPBOX_ROOTFS/etc/ssl/certs" 2>/dev/null || true
    a+=(--ro-bind /etc/ssl/certs /etc/ssl/certs)
  fi

  # ---- 环境：先无条件清空宿主继承，再白名单重建 ----
  # 必须在任何 --setenv（含 net.sh / security.sh 注入）之前。
  # 否则容器会继承 AWS_*/GITHUB_TOKEN/SSH_AUTH_SOCK 等宿主密钥（见 SECURITY.md / CVE-2026-108592 同类根因）。
  a+=(--clearenv)

  # ---- 命名空间 / 网络三档 ----
  if declare -F _net_append_bwrap_args >/dev/null 2>&1; then
    _net_append_bwrap_args a
  else
    case "${CAPBOX_NET:-open}" in
      none | restricted) a+=(--unshare-net) ;;
    esac
  fi
  a+=(--unshare-user --unshare-uts --unshare-ipc)
  # 交互式/调试时可关掉 pid ns（pid 1 收不到某些信号）
  [[ "${CAPBOX_BWRAP_NO_PIDNS:-0}" == "1" ]] || a+=(--unshare-pid)

  # ---- 权限：容器内初始身份 + 全量 capability ----
  # EXEC_UID/GID 可被 CAPBOX_EXEC_UID_OVERRIDE（exec --uid / service）覆盖
  local _eu _eg
  _eu="${CAPBOX_EXEC_UID_OVERRIDE:-${CAPBOX_EXEC_UID:-0}}"
  _eg="${CAPBOX_EXEC_GID_OVERRIDE:-${CAPBOX_EXEC_GID:-0}}"
  [[ "$_eu" =~ ^[0-9]+$ ]] || _eu=0
  [[ "$_eg" =~ ^[0-9]+$ ]] || _eg=0
  a+=(--uid "$_eu" --gid "$_eg" --cap-add ALL)
  a+=(--hostname "${CAPBOX_HOSTNAME:-capbox}")
  a+=(--chdir "$cwd")
  if [[ "${CAPBOX_BWRAP_NO_DIE_WITH_PARENT:-0}" != "1" ]]; then
    a+=(--die-with-parent)
  fi
  # 安全档（compat 为 no-op；untrusted/strict 追加 drop/seccomp 标记/hide）
  if declare -F _security_append_bwrap_args >/dev/null 2>&1; then
    _security_append_bwrap_args a || return $?
  fi

  # ---- 环境白名单（clearenv 之后显式重建；勿透传宿主 *TOKEN/*_KEY/SSH/GPG）----
  a+=(--setenv HOME /root)
  a+=(--setenv PATH /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
  a+=(--setenv TERM "${TERM:-xterm-256color}")
  a+=(--setenv LANG "${LANG:-C.UTF-8}")

  # restricted 模式由 net.sh 注入桥接代理；此处仅处理用户显式 CAPBOX_PROXY（open 模式）
  if [[ -n "${CAPBOX_PROXY:-}" ]]; then
    local _mode="${CAPBOX_NET:-open}"
    if declare -F _net_mode >/dev/null 2>&1; then
      _mode="$(_net_mode)"
    fi
    if [[ "$_mode" != "restricted" ]]; then
      local np="localhost,127.0.0.1,::1,*.local"
      a+=(--setenv http_proxy "$CAPBOX_PROXY")
      a+=(--setenv https_proxy "$CAPBOX_PROXY")
      a+=(--setenv all_proxy "$CAPBOX_PROXY")
      a+=(--setenv no_proxy "$np")
      a+=(--setenv HTTP_PROXY "$CAPBOX_PROXY")
      a+=(--setenv HTTPS_PROXY "$CAPBOX_PROXY")
      a+=(--setenv ALL_PROXY "$CAPBOX_PROXY")
      a+=(--setenv NO_PROXY "$np")
    fi
  fi

  # 逃生口：daemon 或特殊场景附加额外 bwrap 参数
  if [[ -n "${CAPBOX_BWRAP_EXTRA:-}" ]]; then
    local -a extra=()
    read -r -a extra <<<"$CAPBOX_BWRAP_EXTRA"
    a+=("${extra[@]}")
  fi

  printf '%s\n' "${a[@]}"
}

# ---------- 9. 容器内执行公共封装 ---------------------------------------------

# run_bwrap_oneshot CWD TIMEOUT ARGS...
# 用一次性容器执行 ARGS（argv 语义，不经 shell），返回容器内退出码。
run_bwrap_oneshot() {
  local cwd="${1:-/workspace}"
  local to="${2:-0}"
  shift 2 || true
  [[ $# -gt 0 ]] || die 2 "run_bwrap_oneshot: 缺少容器内命令"

  local -a args=()
  local -a full=()
  local _bbrc=0
  mapfile -t args < <(build_bwrap_args oneshot "$cwd"; printf 'CAPBOX_BWRAP_ARGS_RC=%s\n' "$?")
  # 从末尾取构造结果码，避免 mapfile 吞掉 build_bwrap_args 的退出码
  if [[ ${#args[@]} -gt 0 && "${args[-1]}" == CAPBOX_BWRAP_ARGS_RC=* ]]; then
    _bbrc="${args[-1]#CAPBOX_BWRAP_ARGS_RC=}"
    unset 'args[-1]'
  fi
  if (( _bbrc != 0 )); then
    die "$_bbrc" "无法构造 bwrap 参数（rc=$_bbrc；常见原因：FS_BINDS 越界、安全档/seccomp 失败）"
  fi
  if [[ ${#args[@]} -eq 0 ]]; then
    die 4 "rootfs 不存在: $CAPBOX_ROOTFS（请先运行 capbox init）"
  fi

  [[ -x "${CAPBOX_BWRAP:-}" ]] || die 5 "bwrap 不可用: ${CAPBOX_BWRAP:-未设置}（apt install bubblewrap）"

  # restricted：走 net.sh 的 unshare-net + allowlist 代理桥
  if declare -F _net_mode >/dev/null 2>&1 && [[ "$(_net_mode)" == "restricted" ]]; then
    if declare -F _net_run_bwrap_oneshot >/dev/null 2>&1; then
      _net_run_bwrap_oneshot "$cwd" "$to" "$@"
      return $?
    fi
    die 5 "CAPBOX_NET=restricted 但 net.sh 未加载"
  fi

  full=("$CAPBOX_BWRAP" "${args[@]}" -- "$@")
  if declare -F _resources_wrap_argv >/dev/null 2>&1; then
    _resources_wrap_argv full || return $?
  fi
  if declare -F _security_wrap_argv >/dev/null 2>&1; then
    _security_wrap_argv full || return $?
  fi

  local rc=0 use_idmap=0
  if declare -F _idmap_enabled >/dev/null 2>&1; then
    if _idmap_enabled; then
      use_idmap=1
    else
      local _irc=$?
      # _idmap_enabled 返回 2 = 强制 on 但不可用
      if (( _irc == 2 )) || [[ "${CAPBOX_IDMAP:-auto}" == "on" && "${CAPBOX_IDMAP_STATUS}" == "blocked" ]]; then
        die 1 "CAPBOX_IDMAP=on 但多 UID 映射不可用：${CAPBOX_IDMAP_DETAIL:-见 doctor}"
      fi
    fi
  fi

  if (( use_idmap == 1 )); then
    if (( to > 0 )); then
      _idmap_run_bwrap_argv "${full[@]}" &
      local bp=$!
      local waited=0
      while kill -0 "$bp" 2>/dev/null; do
        if (( waited >= to )); then
          kill -TERM -$bp 2>/dev/null || kill -TERM "$bp" 2>/dev/null || true
          sleep 1
          kill -KILL -$bp 2>/dev/null || kill -KILL "$bp" 2>/dev/null || true
          wait "$bp" 2>/dev/null || true
          return 124
        fi
        sleep 1
        waited=$((waited + 1))
      done
      wait "$bp"
      rc=$?
    else
      _idmap_run_bwrap_argv "${full[@]}"
      rc=$?
    fi
    return "$rc"
  fi

  if (( to > 0 )) && have_cmd timeout; then
    timeout --kill-after=5 "$to" "${full[@]}"
    rc=$?
  else
    "${full[@]}"
    rc=$?
  fi
  return "$rc"
}

# exec_in_guest CMD [CWD] [TIMEOUT]   —— 经 /bin/sh -c 执行字符串命令
exec_in_guest() {
  local cmd="${1:-}"
  local cwd="${2:-/workspace}"
  local to="${3:-${CAPBOX_EXEC_TIMEOUT:-600}}"
  [[ -n "$cmd" ]] || die 2 "exec_in_guest: 命令为空"
  run_bwrap_oneshot "$cwd" "$to" /bin/sh -c "$cmd"
}

# guest_output CMD [CWD] [TIMEOUT]
# 捕获容器内输出到 state/ec-<id>.rc（按契约 §1 的约定，用完自动清理）
guest_output() {
  local cmd="${1:-}"
  local cwd="${2:-/workspace}"
  local to="${3:-${CAPBOX_EXEC_TIMEOUT:-600}}"
  local id="$$-${RANDOM}"
  local f="$CAPBOX_STATE_DIR/ec-$id.rc"
  mkdir -p "$CAPBOX_STATE_DIR" 2>/dev/null || true
  local rc=0
  exec_in_guest "$cmd" "$cwd" "$to" >"$f" 2>&1
  rc=$?
  cat -- "$f" 2>/dev/null || true
  rm -f -- "$f" 2>/dev/null || true
  return "$rc"
}

# 把多条 argv 拼成一条 sh -c 字符串（单条时原样保留，让用户能直接写 shell 语法）
# 把 argv 数组拼成一条可交给容器内 /bin/sh -c 的命令字符串。
# 单参数且不含需要转义的情形：原样保留，让用户能直接写 shell 语法
#   （capbox exec 'echo $((6*7))'）。
# 多参数：每个参数用 POSIX 单引号转义后拼接，保证参数边界与内容不被 shell 破坏。
# 注意不能用 printf '%q'：bash 会产出 $'...' 等 busybox ash 不一定支持的写法。
join_cmd_str() {
  if [[ $# -eq 1 ]]; then
    printf '%s' "$1"
    return 0
  fi
  local i out=""
  for (( i = 1; i <= $#; i++ )); do
    (( i > 1 )) && out+=" "
    out+="$(_shq "${!i}")"
  done
  printf '%s' "$out"
}

# ---------- 10. rootfs 就绪检查 -----------------------------------------------

# 判断 rootfs 内某绝对路径是否存在。
# 关键：rootfs 内大量符号链接指向容器内的绝对路径（如 /bin/sh -> /bin/busybox），
# 直接用 [[ -e "$rootfs/bin/sh" ]] 会跟随到**宿主**的 /bin/busybox 而误判为不存在。
_rootfs_path_exists() {
  local r="${1:-$CAPBOX_ROOTFS}"
  local p="${2:-}"
  [[ -n "$r" && -n "$p" ]] || return 1
  local full="$r$p"
  [[ -e "$full" ]] && return 0
  [[ -L "$full" ]] || return 1

  # 符号链接：按容器语义解析目标
  local target
  target="$(readlink -- "$full" 2>/dev/null)" || return 1
  [[ -n "$target" ]] || return 1
  case "$target" in
    /*) _rootfs_path_exists "$r" "$target" ;;
    *) _rootfs_path_exists "$r" "$(dirname "$p")/$target" ;;
  esac
}

# rootfs_ready_at DIR —— 指定目录是否是一个可用的 rootfs（含可执行的 /bin/sh）
rootfs_ready_at() {
  local r="${1:-}"
  [[ -n "$r" && -d "$r" ]] || return 1
  [[ -e "$r/bin/sh" || -L "$r/bin/sh" ]] || return 1
  if [[ -L "$r/bin/sh" ]]; then
    _rootfs_path_exists "$r" /bin/sh || return 1
  elif [[ ! -x "$r/bin/sh" ]]; then
    return 1
  fi
  return 0
}

rootfs_ready() {
  rootfs_ready_at "${CAPBOX_ROOTFS:-}"
}

require_rootfs() {
  # 缺脚手架时先从模板填充（不下载）；缺 rootfs 时仅 CAPBOX_AUTO_INIT=1 才自动 init
  if capbox_needs_scaffold; then
    if declare -F capbox_scaffold_project >/dev/null 2>&1; then
      capbox_scaffold_project || die 1 "无法在当前工作区创建 .capbox"
    fi
  fi
  if rootfs_ready; then
    return 0
  fi
  if _capbox_maybe_auto_init; then
    return 0
  fi
  die 4 "rootfs 不存在或不可用: ${CAPBOX_ROOTFS:-未设置}；请先运行: capbox init --distro ${CAPBOX_DISTRO:-alpine}（会自动脚手架当前目录的 .capbox）"
}

# ---------- 11. daemon 状态探测（无 daemon.sh 时的降级实现） ------------------

# 若 daemon 模块提供了 daemon_info 就用它，否则直接读 daemon.json
_daemon_json_path() {
  printf '%s/daemon.json' "$CAPBOX_DAEMON_DIR"
}

_daemon_json_field() {
  local field="${1:-}"
  local f
  f="$(_daemon_json_path)"
  [[ -f "$f" ]] || return 1
  sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\([0-9]\+\)[^0-9].*/\1/p" "$f" 2>/dev/null | head -1
}

# 输出 0=运行中；1=未运行。绝不因为 daemon 模块缺失而报错。
#
# 优先级：daemon 模块提供 daemon_running 时一律委托给它（它有心跳 hb 判据）。
# 下面的兜底路径只在「lib/daemon.sh 不存在」时使用，必须自己避免两个陷阱：
#   1) daemon.json 里的 pid 是**容器内 pid**（常为 2），宿主上可能存在同名 pid，
#      所以 `kill -0 $pid` 会假阳性。不能用它当活性判据。
#   2) daemon.json 存在只说明「曾经启动过」，进程可能已死 → stale json。
# 因此兜底用「daemon.json 存在 + out/ 可写 + 心跳 hb 新鲜」综合判断；
# 没有 hb 的实现（更早的版本）则退化为「json + out 可写」，并明确标注为弱判据。
_probe_daemon() {
  if declare -F daemon_running >/dev/null 2>&1; then
    daemon_running >/dev/null 2>&1
    return $?
  fi

  local f
  f="$(_daemon_json_path)"
  [[ -f "$f" ]] || return 1
  [[ -w "$CAPBOX_DAEMON_DIR/out" || -w "$CAPBOX_DAEMON_DIR" ]] || return 1

  # 心跳新鲜度：有 hb 时它是强证据（daemon 模块 每 ~1s 刷新，阈值 hb_ttl）
  local hb="$CAPBOX_DAEMON_DIR/hb"
  if [[ -f "$hb" ]]; then
    local ttl now mt age
    ttl="$(_daemon_json_field hb_ttl)"
    [[ -n "$ttl" ]] || ttl=6
    now="$(date +%s)"
    mt="$(stat -c %Y "$hb" 2>/dev/null || echo 0)"
    age=$(( now - mt ))
    (( age <= ttl )) && return 0
    log_debug "守护容器心跳过期（${age}s > ${ttl}s），判为未运行"
    return 1
  fi

  # 无心跳文件：只能弱判据（json + out 可写）。不用 kill -0 以免容器内 pid 假阳性。
  return 0
}

# ---------- 12. status 兜底实现 -----------------------------------------------

# status_oneshot [--json]
# 只报静态信息；daemon 部分如实反映（无 daemon.sh 时 running 恒 false）
status_oneshot() {
  local json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      -h | --help)
        printf '用法: capbox status [--json]\n'
        return 0
        ;;
      *) die 2 "status: 未知选项 $1" ;;
    esac
  done

  local running=false pid=0 uptime=0
  if _probe_daemon; then
    running=true
    pid="$(_daemon_json_field pid)"
    [[ -n "$pid" ]] || pid=0
    local started now
    started="$(_daemon_json_field started_at)"
    now="$(date +%s)"
    if [[ -n "$started" ]] && (( now >= started )); then
      uptime=$(( now - started ))
    fi
  fi

  local bytes
  bytes="$(dir_bytes "$CAPBOX_ROOTFS")"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0

  local mirror_url
  mirror_url="$(mirror_url_for "$CAPBOX_DISTRO")"

  if (( json == 1 )); then
    printf '{"distro":"%s","rootfs":"%s","rootfs_bytes":%s,"daemon":{"running":%s,"pid":%s,"uptime":%s},"net":"%s","mirror":"%s","proxy":"%s","bwrap":"%s","version":"%s"}\n' \
      "$(json_escape "$CAPBOX_DISTRO")" \
      "$(json_escape "$CAPBOX_ROOTFS")" \
      "$bytes" \
      "$running" "$pid" "$uptime" \
      "$(json_escape "${CAPBOX_NET:-open}")" \
      "$(json_escape "${CAPBOX_MIRROR:-cn}")" \
      "$(json_escape "${CAPBOX_PROXY:-}")" \
      "$(json_escape "${CAPBOX_BWRAP:-}")" \
      "$(json_escape "$CAPBOX_VERSION")"
    return 0
  fi

  local rootfs_state="缺失"
  if rootfs_ready; then
    rootfs_state="就绪"
  fi

  printf '发行版     : %s\n' "$CAPBOX_DISTRO"
  printf 'rootfs     : %s（%s，%s）\n' "$CAPBOX_ROOTFS" "$rootfs_state" "$(human_bytes "$bytes")"
  if [[ "$running" == true ]]; then
    printf '守护进程   : 运行中（pid %s，已运行 %ss）\n' "$pid" "$uptime"
  else
    printf '守护进程   : 未运行\n'
  fi
  printf '网络模式   : %s\n' "${CAPBOX_NET:-open}"
  if [[ "${CAPBOX_MIRROR:-cn}" == "none" ]]; then
    printf '镜像源     : none（未注入）\n'
  else
    printf '镜像源     : %s（%s）\n' "${CAPBOX_MIRROR:-cn}" "$mirror_url"
  fi
  if [[ -n "${CAPBOX_PROXY:-}" ]]; then
    printf '代理       : %s\n' "$CAPBOX_PROXY"
  else
    printf '代理       : 无（直连）\n'
  fi
  printf '宿主名     : %s\n' "${CAPBOX_HOSTNAME:-capbox}"
  printf 'bwrap      : %s\n' "${CAPBOX_BWRAP:-未设置}"
  printf '工作区     : %s\n' "$CAPBOX_WORKSPACE"
  printf '版本       : %s\n' "$CAPBOX_VERSION"
  return 0
}

# ---------- 13. version / config / distros 命令 --------------------------------

cmd_version() {
  printf 'CapBox %s\n' "$CAPBOX_VERSION"
  return 0
}

_config_list() {
  local k v
  local width=0
  for k in "${CAPBOX_CFG_KEYS[@]}"; do
    (( ${#k} > width )) && width=${#k}
  done
  for k in "${CAPBOX_CFG_KEYS[@]}"; do
    v="$(_cfg_value_for_file "$k")"
    [[ -n "$v" ]] || v="''"
    printf 'CAPBOX_%-*s = %s\n' "$width" "$k" "$v"
  done
  printf '# 配置文件: %s\n' "$CAPBOX_DIR/config.env"
}

cmd_config() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    get)
      [[ $# -eq 1 ]] || die 2 "用法: capbox config get KEY"
      local k
      k="$(_cfg_norm_key "$1")"
      _cfg_known "$k" || die 2 "未知配置项: $1；可用: ${CAPBOX_CFG_KEYS[*]}"
      _cfg_value "$k"
      printf '\n'
      ;;
    set)
      [[ $# -eq 2 ]] || die 2 "用法: capbox config set KEY VALUE"
      config_set "$1" "$2" || exit 2
      log_info "已设置 ${1} = ${2}"
      ;;
    list | "")
      _config_list
      ;;
    *)
      die 2 "用法: capbox config <get|set|list> [KEY] [VALUE]"
      ;;
  esac
  return 0
}

cmd_distros() {
  local d name url cached state buf="" _chunk=""
  printf '可用发行版：\n'
  for d in "${CAPBOX_SUPPORTED_DISTROS[@]}"; do
    name="$(_distro_tarball_name "$d" 2>/dev/null || true)"
    url="$(_distro_tarball_url "$d" 2>/dev/null || true)"
    [[ -n "$name" ]] || name="(未知)"
    cached="否"
    [[ -s "$CAPBOX_CACHE_DIR/$name" ]] && cached="是"
    state="未初始化"
    rootfs_ready_at "$CAPBOX_DIR/os/$d" && state="已初始化"
    printf -v _chunk '\n  %s  （%s）\n    镜像包 : %s\n    下载   : %s\n    已缓存 : %s\n' \
      "$d" "$state" "$name" "${url:-（无）}" "$cached"
    buf+="$_chunk"
  done
  printf -v _chunk '\n当前默认发行版: %s（capbox init --distro <名字> 切换）\n' "$CAPBOX_DISTRO"
  buf+="$_chunk"
  # 一次性写出：避免多次小写入在管道提前关闭时刷出 EPIPE 噪音
  printf '%s' "$buf"
  return 0
}

# ---------- 14. doctor --------------------------------------------------------

_doctor_pass() { printf 'PASS  %s\n' "$*"; }
_doctor_fail() {
  printf 'FAIL  %s\n' "$*"
  DOCTOR_FAILS=$(( DOCTOR_FAILS + 1 ))
}
_doctor_warn() {
  printf 'WARN  %s\n' "$*"
  DOCTOR_WARNS=$(( DOCTOR_WARNS + 1 ))
}

# 探测 userns 内是否拿到全量 capability；成功时打印 CapEff 十六进制值
_doctor_probe_userns() {
  local bwrap="${CAPBOX_BWRAP:-}"
  [[ -x "$bwrap" ]] || return 5
  local out uid capeff
  out="$("$bwrap" --unshare-user --unshare-uts --unshare-ipc \
    --uid 0 --gid 0 --cap-add ALL \
    --ro-bind / / --proc /proc --dev /dev \
    -- /bin/sh -c 'id -u; sed -n "s/^CapEff:[[:space:]]*//p" /proc/self/status' 2>/dev/null)" || return 1
  uid="$(printf '%s\n' "$out" | sed -n '1p')"
  capeff="$(printf '%s\n' "$out" | sed -n '2p')"
  [[ "$uid" == "0" ]] || return 1
  [[ -n "$capeff" ]] || return 1
  local val want
  val=$(( 16#${capeff} ))
  want=$(( (1 << 41) - 1 ))
  (( (val & want) == want )) || return 1
  printf '%s' "$capeff"
}

cmd_doctor() {
  DOCTOR_FAILS=0
  DOCTOR_WARNS=0
  local bwrap="${CAPBOX_BWRAP:-}"

  # 0) 工作区安全（禁止 $HOME 或 / 作为 RW workspace）
  if _capbox_workspace_is_dangerous; then
    _doctor_fail "工作区为 $HOME 或 / ($CAPBOX_WORKSPACE)；会把整棵目录 RW bind 进容器。请用项目内 .capbox/ 或 CAPBOX_ROOT=/path/to/project"
  else
    _doctor_pass "工作区安全 ($CAPBOX_WORKSPACE)"
  fi

  # 1) bwrap
  if [[ -n "$bwrap" && -x "$bwrap" ]]; then
    _doctor_pass "bwrap 已安装 ($bwrap)"
  else
    _doctor_fail "bwrap 不可用 (${bwrap:-未设置})；请安装 bubblewrap 或设置 CAPBOX_BWRAP"
  fi

  # 2) userns 全权限
  if [[ -n "$bwrap" && -x "$bwrap" ]]; then
    local caphex
    if caphex="$(_doctor_probe_userns)"; then
      _doctor_pass "userns 全权限 (uid=0, CapEff=$caphex)"
    else
      _doctor_fail "userns 全权限探测失败：容器内无法获得 uid0 + 全量 capability（检查内核 unprivileged_userns_clone 与 bwrap 版本）"
    fi
  else
    _doctor_fail "userns 全权限未探测（bwrap 不可用）"
  fi

  if declare -F _idmap_doctor_report >/dev/null 2>&1; then
    _idmap_doctor_report
  else
    _doctor_warn "UID 映射模块未加载（lib/idmap.sh）"
  fi

  # 3) 依赖命令
  local miss=() c
  for c in tar curl flock timeout; do
    have_cmd "$c" || miss+=("$c")
  done
  if [[ ${#miss[@]} -eq 0 ]]; then
    _doctor_pass "依赖命令齐全 (tar/curl/flock/timeout)"
  elif [[ ${#miss[@]} -eq 1 && "${miss[0]}" == "timeout" ]]; then
    _doctor_warn "缺少 timeout（exec --timeout 将失效），其余依赖齐全"
  else
    _doctor_fail "缺少依赖命令: ${miss[*]}"
  fi

  # 4) rootfs
  if rootfs_ready; then
    _doctor_pass "rootfs 就绪 ($CAPBOX_ROOTFS, $(human_bytes "$(dir_bytes "$CAPBOX_ROOTFS")"))"
  else
    _doctor_fail "rootfs 缺失或不可用 ($CAPBOX_ROOTFS)；请运行: capbox init --distro $CAPBOX_DISTRO"
  fi

  # 5) resolv.conf
  if [[ -f "$CAPBOX_STATE_DIR/resolv.conf" ]]; then
    _doctor_pass "resolv.conf 已就绪 ($CAPBOX_STATE_DIR/resolv.conf)"
  else
    _doctor_warn "resolv.conf 尚未生成（首次 exec 时会自动生成）"
  fi

  # 6) 网络 + 镜像源连通
  local url mirror_root
  mirror_root="$(mirror_url_for "$CAPBOX_DISTRO")"
  if [[ "${CAPBOX_MIRROR:-cn}" == "none" ]]; then
    _doctor_warn "CAPBOX_MIRROR=none，跳过镜像源连通性检查"
  elif [[ -z "$mirror_root" ]]; then
    _doctor_fail "镜像源 URL 为空（检查 CAPBOX_MIRROR_${CAPBOX_DISTRO^^}）"
  else
    case "$CAPBOX_DISTRO" in
      alpine) url="$mirror_root/v3.20/main/x86_64/APKINDEX.tar.gz" ;;
      ubuntu) url="$mirror_root/dists/noble/Release" ;;
      *) url="$mirror_root" ;;
    esac
    if have_cmd curl; then
      if curl -fsSI -m 8 -o /dev/null "$url" 2>/dev/null; then
        _doctor_pass "镜像源连通 ($url)"
      else
        _doctor_fail "镜像源不可达 ($url)；检查网络或 CAPBOX_MIRROR 配置"
      fi
      case "${CAPBOX_NET:-open}" in
        open | host)
          if curl -fsSI -m 8 -o /dev/null "${CAPBOX_MIRROR_ALPINE%/}/" 2>/dev/null; then
            _doctor_pass "宿主网络可用"
          else
            _doctor_warn "宿主到公网镜像的探测失败（可能是离线环境）"
          fi
          ;;
        none)
          _doctor_warn "CAPBOX_NET=none，容器内无网络（--unshare-net）"
          ;;
        restricted)
          _doctor_warn "CAPBOX_NET=restricted：镜像连通性取决于 allowlist 代理（见下方网络模式项）"
          ;;
      esac
    else
      _doctor_warn "缺少 curl，跳过网络连通性检查"
    fi
  fi

  # 7) 代理
  if [[ -n "${CAPBOX_PROXY:-}" ]]; then
    case "$CAPBOX_PROXY" in
      socks5*)
        if [[ "$CAPBOX_DISTRO" == "ubuntu" ]]; then
          _doctor_warn "socks5 代理下 apt 不原生支持：建议改用 http 代理，或在容器内配置 proxychains"
        fi
        _doctor_pass "代理已配置 ($CAPBOX_PROXY)"
        ;;
      *) _doctor_pass "代理已配置 ($CAPBOX_PROXY)" ;;
    esac
  else
    _doctor_pass "代理未配置（直连）"
  fi

  # 8) 镜像源文件是否已注入
  if [[ "${CAPBOX_MIRROR:-cn}" != "none" ]] && rootfs_ready; then
    case "$CAPBOX_DISTRO" in
      alpine)
        if [[ -f "$CAPBOX_ROOTFS/etc/apk/repositories" ]]; then
          _doctor_pass "apk 镜像源已注入"
        else
          _doctor_fail "缺少 $CAPBOX_ROOTFS/etc/apk/repositories（重新运行 capbox init）"
        fi
        ;;
      ubuntu)
        local sl="$CAPBOX_ROOTFS/etc/apt/sources.list"
        local d822="$CAPBOX_ROOTFS/etc/apt/sources.list.d/ubuntu.sources"
        if [[ -f "$sl" || -f "$d822" ]]; then
          local which="sources.list"
          [[ -f "$d822" ]] && which="sources.list.d/ubuntu.sources"
          _doctor_pass "apt 镜像源已注入 ($which)"
        else
          _doctor_fail "缺少 apt 源文件（$sl 或 $d822）；重新运行 capbox init"
        fi
        ;;
    esac
  fi

  # 8b) 网络三档 + 资源限额
  if declare -F _net_doctor_report >/dev/null 2>&1; then
    _net_doctor_report
  fi
  if declare -F _resources_doctor_report >/dev/null 2>&1; then
    _resources_doctor_report
  fi
  if declare -F _security_doctor_report >/dev/null 2>&1; then
    _security_doctor_report
  fi
  if declare -F _fsguard_doctor_report >/dev/null 2>&1; then
    _fsguard_doctor_report
  fi
  if declare -F _image_doctor_report >/dev/null 2>&1; then
    _image_doctor_report
  fi

  # 9) 环境变量清空（--clearenv 白名单）
  if rootfs_ready && [[ -x "${CAPBOX_BWRAP:-}" ]]; then
    local env_probe="" env_rc=0
    # 用真实 oneshot 路径探测；哨兵与常见密钥名都不得出现，HOME/PATH 仍须可用。
    env_probe="$(
      CAPBOX_TEST_SENTINEL=leak-me-doctor       AWS_ACCESS_KEY_ID=AKIA_DOCTOR_PROBE       GITHUB_TOKEN=ghp_doctor_probe       SSH_AUTH_SOCK=/tmp/capbox-doctor-ssh.sock       GPG_AGENT_INFO=/tmp/capbox-doctor-gpg       OPENAI_API_KEY=sk-doctor-probe       run_bwrap_oneshot /workspace 30 /bin/sh -c         'if test -n "${CAPBOX_TEST_SENTINEL:-}" || test -n "${AWS_ACCESS_KEY_ID:-}" || test -n "${GITHUB_TOKEN:-}" || test -n "${SSH_AUTH_SOCK:-}" || test -n "${GPG_AGENT_INFO:-}" || test -n "${OPENAI_API_KEY:-}"; then
           echo LEAK
           exit 1
         fi
         if test -z "${HOME:-}" || test -z "${PATH:-}"; then
           echo NO_WHITELIST
           exit 1
         fi
         echo OK'
    )" || env_rc=$?
    if [[ "$env_rc" -eq 0 && "$env_probe" == *OK* ]]; then
      _doctor_pass "环境变量已清空（宿主敏感变量不继承；白名单 HOME/PATH 可用）"
    else
      _doctor_fail "环境变量未清空或白名单缺失（probe rc=$env_rc out=${env_probe:-<empty>}）；应无条件 bwrap --clearenv 后再 --setenv"
    fi
  else
    _doctor_warn "跳过环境清空探测（rootfs 或 bwrap 不可用）"
  fi

  # 10) 缺失配置路径预占（CVE-2026-25725 同类：guest 不得创建宿主会读的 config/services）
  if rootfs_ready && [[ -x "${CAPBOX_BWRAP:-}" ]]; then
    local _cfg_g _svc_g _probe_out _probe_rc=0 _host_cfg _host_svc_probe
    _cfg_g="$(_guest_workspace_path "$CAPBOX_DIR/config.env")"
    _svc_g="$(_guest_workspace_path "$CAPBOX_DIR/services")"
    _host_cfg="$CAPBOX_DIR/config.env"
    _host_svc_probe="$CAPBOX_DIR/services/_doctor_probe.env"
    if [[ -n "$_cfg_g" && "$_cfg_g" == /workspace/* && -n "$_svc_g" && "$_svc_g" == /workspace/* ]]; then
      rm -f -- "${_host_svc_probe}.attempt" 2>/dev/null || true
      _probe_out="$(
        run_bwrap_oneshot /workspace 30 /bin/sh -c "
          echo DOCTOR_INJECT > \"$_cfg_g\" 2>/tmp/cfg.err || true
          mkdir -p \"$_svc_g\" 2>/dev/null || true
          echo CMD=true > \"$_svc_g/_doctor_probe.env\" 2>/tmp/svc.err || true
          if [ -f /tmp/cfg.err ]; then cat /tmp/cfg.err; fi
          if [ -f /tmp/svc.err ]; then cat /tmp/svc.err; fi
          # 能写通则打印 VULN
          if [ -w \"$_cfg_g\" ] 2>/dev/null; then echo CFG_WRITABLE; fi
          if echo x > \"$_cfg_g\" 2>/dev/null; then echo CFG_WRITE_OK; fi
          if echo CMD=true > \"$_svc_g/_doctor_probe.env\" 2>/dev/null; then echo SVC_WRITE_OK; fi
          echo PROBE_DONE
        "
      )" || _probe_rc=$?
      if [[ -f "$_host_cfg" ]] && grep -q 'DOCTOR_INJECT' "$_host_cfg" 2>/dev/null; then
        _doctor_fail "guest 写入了宿主 config.env（缺失/已存在路径未只读保护）"
      elif [[ -f "$_host_svc_probe" ]]; then
        _doctor_fail "guest 创建了宿主 services/_doctor_probe.env（services 目录未只读保护）"
        rm -f -- "$_host_svc_probe" 2>/dev/null || true
      elif [[ "$_probe_out" == *CFG_WRITE_OK* || "$_probe_out" == *SVC_WRITE_OK* ]]; then
        _doctor_fail "guest 可写受保护配置路径（probe out=${_probe_out:-<empty>}）"
      else
        _doctor_pass "配置路径预占生效（缺失/已存在的 config.env 与 services/ 均不可被 guest 写入）"
      fi
    else
      _doctor_warn "跳过配置预占探测（CAPBOX_DIR 不在工作区视图内）"
    fi
  else
    _doctor_warn "跳过配置预占探测（rootfs 或 bwrap 不可用）"
  fi

  # 11) daemon
  if _probe_daemon; then
    _doctor_pass "守护容器运行中 (pid $(_daemon_json_field pid))"
  else
    _doctor_pass "守护容器未运行（按需用后台任务运行 capbox up）"
  fi

  printf '\n'
  if (( DOCTOR_FAILS > 0 )); then
    printf '自检结果: %d 项 FAIL，%d 项 WARN\n' "$DOCTOR_FAILS" "$DOCTOR_WARNS"
    return 1
  fi
  if (( DOCTOR_WARNS > 0 )); then
    printf '自检结果: 全部通过（%d 项 WARN）\n' "$DOCTOR_WARNS"
    return 0
  fi
  printf '自检结果: 全部通过\n'
  return 0
}

# ---------- 15. clean ---------------------------------------------------------

cmd_clean() {
  local all=0
  local cache=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        all=1
        cache=1
        shift
        ;;
      --cache) cache=1; shift ;;
      -y | --yes) shift ;;
      -h | --help)
        cat <<'EOF'
用法: capbox clean [--cache] [--all]

  （无参数）  清理日志、临时文件、一次性 exec 残留；**保留缓存与 rootfs**
  --cache     额外清理 cache/ 下已下载的镜像 tarball
  --all       清理缓存并删除当前 distro 的 rootfs（最彻底，需重新 init）

注意：clean 会先停止正在运行的守护容器（等价于 capbox down，优雅退出），
      然后清理 run/tmp —— 容器内 /tmp 的后端。目录本身保留，daemon 可正常重启。
EOF
        return 0
        ;;
      *) die 2 "clean: 未知选项 $1" ;;
    esac
  done

  # 停守护容器（如果 daemon 模块提供了 cmd_down）。
  # 这是 clean 的副作用里最容易被忽略的一条：clean 会顺带把常驻容器停掉。
  # 因此只在确实运行时才提示，避免无谓的噪音；并且提示语要明确说「将停止」。
  if declare -F cmd_down >/dev/null 2>&1 && _probe_daemon; then
    log_info "检测到守护容器正在运行，clean 会先停止它（优雅退出，等待在跑任务完成）"
    local drc=0
    cmd_down >/dev/null 2>&1
    drc=$?
    # 契约 §3.2：3=未运行。这与「停止失败」是两回事——
    # 从 _probe_daemon 到 cmd_down 之间 daemon 可能已经自己退出（竞态），
    # 此时返回 3 属正常，不该报「失败」误导用户。
    if (( drc == 3 )); then
      log_debug "守护容器在停止前已自行退出（rc=3），继续清理"
    elif (( drc != 0 )); then
      log_warn "停止守护容器失败（rc=$drc，继续清理临时文件）"
    fi
  fi

  log_info "清理日志 ($CAPBOX_LOG_DIR)"
  _safe_rm_dir_contents "$CAPBOX_LOG_DIR"
  log_info "清理临时状态 ($CAPBOX_STATE_DIR/ec-*, $CAPBOX_TMP_DIR)"
  find "$CAPBOX_STATE_DIR" -maxdepth 1 -name 'ec-*.rc' -delete 2>/dev/null || true
  _safe_rm_dir_contents "$CAPBOX_TMP_DIR"
  find "$CAPBOX_RUN_DIR" -maxdepth 1 -name '*.lock' -delete 2>/dev/null || true

  # 缓存单独处理：默认**保留**。缓存是可再生的下载产物，但重新下载成本高
  # （ubuntu 30MB），而 clean 的语义主要是「清临时垃圾」，不该顺手把缓存也清了。
  # 要清缓存请显式用 --cache / --all。
  if (( all == 1 )) || (( cache == 1 )); then
    log_info "清理缓存 ($CAPBOX_CACHE_DIR)"
    _safe_rm_dir_contents "$CAPBOX_CACHE_DIR"
  else
    local n_cache=0
    [[ -d "$CAPBOX_CACHE_DIR" ]] && n_cache=$(find "$CAPBOX_CACHE_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    if (( n_cache > 0 )); then
      log_info "缓存保留（$n_cache 个文件，约 $(human_bytes "$(dir_bytes "$CAPBOX_CACHE_DIR")")）；加 --cache 或 --all 才会清理"
    fi
  fi

  if (( all == 1 )); then
    _safe_rm_rootfs "$CAPBOX_ROOTFS" || true
    log_info "已删除 rootfs 与缓存；下次使用前需重新 capbox init"
  else
    log_info "已清理日志/临时文件（rootfs 与缓存保留）"
  fi
  return 0
}

# ---------- 15b. 项目脚手架（从 CLI 模板复制到当前 .capbox） -----------------

# CLI 模板目录：优先入口记下的 _CAPBOX_TEMPLATE_DIR，否则 CAPBOX_DIR 自身（已是完整树）
capbox_template_dir() {
  local t=""
  if [[ -n "${_CAPBOX_TEMPLATE_DIR:-}" && -f "${_CAPBOX_TEMPLATE_DIR}/lib/common.sh" ]]; then
    printf '%s\n' "$_CAPBOX_TEMPLATE_DIR"
    return 0
  fi
  if [[ -n "${_CAPBOX_CLI_BIN_DIR:-}" ]]; then
    t="$(cd -- "$_CAPBOX_CLI_BIN_DIR/.." 2>/dev/null && pwd || true)"
    if [[ -n "$t" && -f "$t/lib/common.sh" ]]; then
      printf '%s\n' "$t"
      return 0
    fi
  fi
  if [[ -f "${CAPBOX_DIR:-}/lib/common.sh" ]]; then
    printf '%s\n' "$CAPBOX_DIR"
    return 0
  fi
  return 1
}

# 当前 CAPBOX_DIR 是否缺入口/库（需要从模板填充）
capbox_needs_scaffold() {
  [[ ! -f "${CAPBOX_DIR:-}/lib/common.sh" || ! -e "${CAPBOX_DIR:-}/bin/capbox" ]]
}

# 只把缺失的文件从 src 树填进 dst（不覆盖已有文件，不删多余）
_capbox_fill_tree() {
  local src="${1:-}" dst="${2:-}" rel f
  [[ -d "$src" ]] || return 1
  mkdir -p "$dst" || return 1
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    [[ -n "$rel" ]] || continue
    if [[ ! -e "$dst/$rel" && ! -L "$dst/$rel" ]]; then
      mkdir -p "$dst/$(dirname -- "$rel")" || return 1
      cp -a -- "$f" "$dst/$rel" || return 1
    fi
  done < <(find "$src" \( -type f -o -type l \) -print0 2>/dev/null)
  return 0
}

# 把模板的 bin/ lib/ skill/（及 LICENSE）脚手架到 CAPBOX_DIR
# 不复制 cache/ os/ run/ state/ logs/ config.env
capbox_scaffold_project() {
  local template srcd
  _capbox_require_safe_workspace || return 1
  template="$(capbox_template_dir)" || {
    die 1 "找不到 CapBox 模板树（需要带 lib/common.sh 的安装）。请先安装 CapBox Skill/CLI。"
  }
  template="$(resolve_path "$template")"
  local dest
  dest="$(resolve_path "$CAPBOX_DIR")"

  if [[ "$template" == "$dest" ]]; then
    ensure_dirs
    return 0
  fi

  if ! capbox_needs_scaffold && [[ -d "$CAPBOX_DIR/lib" && -e "$CAPBOX_DIR/bin/capbox" ]]; then
    ensure_dirs
    return 0
  fi

  log_info "正在当前工作区创建 .capbox …（模板: $template → $CAPBOX_DIR）"
  mkdir -p "$CAPBOX_DIR" || die 1 "无法创建 $CAPBOX_DIR"

  for srcd in bin lib skill; do
    if [[ -d "$template/$srcd" ]]; then
      _capbox_fill_tree "$template/$srcd" "$CAPBOX_DIR/$srcd" \
        || die 1 "脚手架复制失败: $srcd"
    fi
  done
  if [[ -f "$template/LICENSE" && ! -e "$CAPBOX_DIR/LICENSE" ]]; then
    cp -a -- "$template/LICENSE" "$CAPBOX_DIR/LICENSE" 2>/dev/null || true
  fi

  if [[ -e "$CAPBOX_DIR/bin/capbox" ]]; then
    chmod +x "$CAPBOX_DIR/bin/capbox" 2>/dev/null || true
  fi
  [[ -f "$CAPBOX_DIR/lib/common.sh" ]] || die 1 "脚手架后仍缺少 lib/common.sh"
  [[ -e "$CAPBOX_DIR/bin/capbox" ]] || die 1 "脚手架后仍缺少 bin/capbox"

  ensure_dirs
  log_info "已在工作区就绪: $CAPBOX_DIR"
  return 0
}

# 可选：缺 rootfs 时自动 init（默认关，避免惊喜下载）
_capbox_maybe_auto_init() {
  if rootfs_ready; then
    return 0
  fi
  case "${CAPBOX_AUTO_INIT:-0}" in
    1 | true | TRUE | yes | YES | on | ON) ;;
    *) return 1 ;;
  esac
  log_info "CAPBOX_AUTO_INIT=1：自动执行 capbox init"
  if declare -F cmd_init >/dev/null 2>&1; then
    cmd_init || return $?
  else
    return 1
  fi
  rootfs_ready
}

# ---------- 16. 初始化 --------------------------------------------------------

load_config
# 尚未脚手架出的 $PWD/.capbox 不在这里 mkdir，避免 help/version 误建空树
if [[ -d "${CAPBOX_DIR:-}" ]]; then
  ensure_dirs >/dev/null 2>&1 || true
fi
