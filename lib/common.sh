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

# shellcheck source=lib/version.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/version.sh" || return 1

# 支持的发行版
readonly CAPBOX_SUPPORTED_DISTROS=(alpine ubuntu)

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

# 当次出网声明。只改本进程的 CAPBOX_NET，不写 config.env。
# $1 模式  $2 调用方（写进错误信息）
_capbox_declare_net() {
  local mode="${1:-}" who="${2:-net}"
  case "$mode" in
    none | restricted | open) CAPBOX_NET="$mode" ;;
    host) CAPBOX_NET=open ;;
    *)
      die 2 "${who}: --net 必须是 none|restricted|open（host 别名）；当前: ${mode}"
      ;;
  esac
  if [[ "${CAPBOX_NET}" == "restricted" && -z "${CAPBOX_NET_ALLOW:-}" ]]; then
    die 2 "${who}: --net restricted 需要非空 CAPBOX_NET_ALLOW（config set 或环境变量）"
  fi
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

# 从版本串取前三段数字。后缀（0.11.1-1ubuntu0.3）只作比较用的补丁号来源，不参与字符串比较。
_capbox_bwrap_parse_version_line() {
  local line="${1-}"
  [[ "$line" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
  CAPBOX_BWRAP_VERSION="$((10#${BASH_REMATCH[1]}))".$((10#${BASH_REMATCH[2]})).$((10#${BASH_REMATCH[3]}))
  return 0
}

_capbox_bwrap_version_meets() {
  local maj="${1:-0}" min="${2:-0}" pat="${3:-0}"
  (( maj > 0 || (maj == 0 && min > 12) || (maj == 0 && min == 12 && pat >= 0) ))
}

# 根据 CAPBOX_BWRAP_VERSION 填写 DETAIL 并返回 0/1。空版本视为无法解析。
_capbox_bwrap_apply_version_result() {
  local bin="${1:-bwrap}" maj min pat
  if [[ ! "${CAPBOX_BWRAP_VERSION:-}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    CAPBOX_BWRAP_VERSION=""
    CAPBOX_BWRAP_VERSION_DETAIL="无法解析 ${bin} --version（需要 >= 0.12.0）"
    return 1
  fi
  maj="${BASH_REMATCH[1]}"
  min="${BASH_REMATCH[2]}"
  pat="${BASH_REMATCH[3]}"
  if _capbox_bwrap_version_meets "$maj" "$min" "$pat"; then
    CAPBOX_BWRAP_VERSION_DETAIL="${CAPBOX_BWRAP_VERSION}"
    return 0
  fi
  CAPBOX_BWRAP_VERSION_DETAIL="bwrap ${CAPBOX_BWRAP_VERSION} 低于 0.12.0（发行版撤回的 0.11.x 补丁不算；需要 >= 0.12.0）"
  return 1
}

_capbox_bwrap_cache_file() {
  printf '%s\n' "${CAPBOX_STATE_DIR:-${CAPBOX_DIR:-}/state}/bwrap-version"
}

# 缓存命中返回 0，并设置 CAPBOX_BWRAP_VERSION（解析失败时为空）。
# 只比较 path + dev + inode + mtime + size。不信任文件里的 ok 位。
# 版本缓存文件对 guest 钉成只读（见 _capbox_append_ro_cli_binds），避免 guest 改一行就把旧二进制说成新的。
_capbox_bwrap_cache_hit() {
  local bin="${1:-}" f line key val path="" dev="" ino="" mtime="" size="" parse="" version="" st
  f="$(_capbox_bwrap_cache_file)"
  [[ -n "$bin" && -f "$f" && ! -L "$f" ]] || return 1
  st="$(stat -c '%d %i %Y %s' -- "$bin" 2>/dev/null)" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([a-z]+)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    case "$key" in
      path) path="$val" ;;
      dev) dev="$val" ;;
      ino) ino="$val" ;;
      mtime) mtime="$val" ;;
      size) size="$val" ;;
      parse) parse="$val" ;;
      version) version="$val" ;;
    esac
  done <"$f"
  [[ "$path" == "$bin" && "$st" == "$dev $ino $mtime $size" ]] || return 1
  if [[ "$parse" == "1" && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    CAPBOX_BWRAP_VERSION="$version"
  else
    CAPBOX_BWRAP_VERSION=""
  fi
  return 0
}

_capbox_bwrap_cache_store() {
  local bin="${1:-}" parse="${2:-0}" version="${3:-}" f dir tmp st dev ino mtime size
  [[ -n "$bin" && -n "${CAPBOX_DIR:-}" ]] || return 0
  f="$(_capbox_bwrap_cache_file)"
  [[ -L "$f" ]] && return 0
  st="$(stat -c '%d %i %Y %s' -- "$bin" 2>/dev/null)" || return 0
  read -r dev ino mtime size <<<"$st"
  dir="$(dirname -- "$f")"
  [[ -L "$dir" ]] && return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "$dir/.bwrap-version.XXXXXX")" || return 0
  {
    printf 'path=%s\n' "$bin"
    printf 'dev=%s\n' "$dev"
    printf 'ino=%s\n' "$ino"
    printf 'mtime=%s\n' "$mtime"
    printf 'size=%s\n' "$size"
    printf 'parse=%s\n' "$parse"
    printf 'version=%s\n' "$version"
  } >"$tmp" || { rm -f -- "$tmp"; return 0; }
  if [[ -f "$f" && ! -L "$f" ]]; then
    cat "$tmp" >"$f" 2>/dev/null || cp -f -- "$tmp" "$f" 2>/dev/null || true
    rm -f -- "$tmp"
  else
    mv -f -- "$tmp" "$f" 2>/dev/null || rm -f -- "$tmp"
  fi
  return 0
}

# bwrap 是否不低于 0.12.0。
# 可选参数是二进制路径，默认 CAPBOX_BWRAP。
# 成功时 CAPBOX_BWRAP_VERSION 与 CAPBOX_BWRAP_VERSION_DETAIL 均为 major.minor.patch。
# 返回 0 达标，1 版本不足、二进制缺失或无法解析。
# 结果缓存在 state/bwrap-version；二进制的 dev/inode/mtime/size 变了才重新执行 --version。
# 发行版把 CVE-2026-87766 补丁打进 0.11.x 再撤回后，版本串仍是 0.11.x，不算修复。
_capbox_bwrap_version_ok() {
  local bin="${1:-${CAPBOX_BWRAP:-}}"
  local line
  CAPBOX_BWRAP_VERSION=""
  CAPBOX_BWRAP_VERSION_DETAIL=""
  if [[ -z "$bin" || ! -x "$bin" ]]; then
    CAPBOX_BWRAP_VERSION_DETAIL="无法解析 ${bin:-bwrap} --version（需要 >= 0.12.0）"
    return 1
  fi
  if _capbox_bwrap_cache_hit "$bin"; then
    _capbox_bwrap_apply_version_result "$bin"
    return $?
  fi
  line="$("$bin" --version 2>/dev/null | head -n 1 || true)"
  if _capbox_bwrap_parse_version_line "$line"; then
    _capbox_bwrap_cache_store "$bin" 1 "$CAPBOX_BWRAP_VERSION"
  else
    CAPBOX_BWRAP_VERSION=""
    _capbox_bwrap_cache_store "$bin" 0 ""
  fi
  _capbox_bwrap_apply_version_result "$bin"
}

# 单次 flag 优先于持久配置。两者都没有则拒绝。不读环境变量。
_capbox_old_bwrap_scope() {
  if [[ "${CAPBOX_ALLOW_OLD_BWRAP_ONCE:-}" == "1" ]]; then
    printf 'once'
    return 0
  fi
  if [[ "${CAPBOX_ALLOW_OLD_BWRAP:-}" == "1" ]]; then
    printf 'persist'
    return 0
  fi
  return 1
}

# $1 可选，写入的文件描述符。默认 2（stderr）。doctor 报告走 stdout。
_capbox_print_old_bwrap_details() {
  local dest="${1:-2}"
  cat >&"$dest" <<'EOF'
      受影响: CVE-2026-87766 (/oldroot 符号链接逃逸), CVE-2026-41163 (setuid ptrace)
      这些漏洞在沙箱进程启动前触发，--clearenv / fsguard / seccomp 均无法防御
      本检查对 compat、untrusted、strict 同样生效
      升级: sudo apt install --only-upgrade bubblewrap
            若发行版未包含 0.12.0，需从源码或更新的仓库安装
      如确认接受风险，单次允许: capbox --allow-old-bwrap <command>
      持久允许: capbox config set --yes CAPBOX_ALLOW_OLD_BWRAP 1
            （会写入审计日志；doctor 仍为 FAIL）
EOF
}

_capbox_print_old_bwrap_deny() {
  local ver="${CAPBOX_BWRAP_VERSION:-未知}"
  printf 'FAIL  bwrap %s 低于安全基线 0.12.0\n' "$ver" >&2
  _capbox_print_old_bwrap_details
}

# 版本达标返回 0。旧版在单次或持久放行时写审计并返回 0，否则打印说明并返回 6。
# compat 不豁免。CAPBOX_BWRAP_BASELINE_CMD 由调用方放入审计的 cmd 字段。
_capbox_enforce_bwrap_baseline() {
  local scope="" ver=""
  if _capbox_bwrap_version_ok; then
    return 0
  fi
  # 二进制根本不存在：留给「bwrap 不可用」的退出码 5，这里不伪装成基线 6。
  if [[ -z "${CAPBOX_BWRAP:-}" || ! -x "${CAPBOX_BWRAP:-}" ]]; then
    log_err "bwrap 不可用: ${CAPBOX_BWRAP:-未设置}"
    return 5
  fi
  ver="${CAPBOX_BWRAP_VERSION:-未知}"
  if scope="$(_capbox_old_bwrap_scope)"; then
    if [[ "$scope" == "persist" ]]; then
      log_warn "bwrap ${ver} 低于安全基线 0.12.0，已被 CAPBOX_ALLOW_OLD_BWRAP 放行（doctor 仍为 FAIL）"
    fi
    if ! _capbox_audit_old_bwrap "$scope" "$ver" "${CAPBOX_BWRAP_BASELINE_CMD:-}"; then
      log_err "无法写入旧版 bwrap 放行审计，拒绝启动"
      return 6
    fi
    return 0
  fi
  _capbox_print_old_bwrap_deny
  return 6
}

# 旧版放行必须留痕。CAPBOX_AUDIT=off 也写。日志或目录是符号链接则失败。
# scope: once | persist。cmd 经 _audit_redact 脱敏（函数在时）。
_capbox_audit_old_bwrap() {
  local scope="${1:-}" version="${2:-}" cmd="${3:-}"
  local dir f ts esc_ts esc_ver esc_scope esc_cmd
  [[ "$scope" == "once" || "$scope" == "persist" ]] || return 1
  [[ -n "${CAPBOX_DIR:-}" ]] || return 1
  dir="${CAPBOX_LOG_DIR:-$CAPBOX_DIR/logs}"
  f="$dir/audit.jsonl"
  if [[ -L "$dir" || -L "$f" ]]; then
    log_err "审计日志路径是符号链接，拒绝记录旧版 bwrap 放行: $f"
    return 1
  fi
  if [[ -e "$dir" && ! -d "$dir" ]]; then
    log_err "审计日志目录不是普通目录，拒绝记录旧版 bwrap 放行: $dir"
    return 1
  fi
  mkdir -p "$dir" 2>/dev/null || return 1
  if [[ -L "$dir" || -L "$f" || ! -d "$dir" ]]; then
    log_err "审计日志路径不可用，拒绝记录旧版 bwrap 放行: $f"
    return 1
  fi
  if declare -F _audit_redact >/dev/null 2>&1; then
    cmd="$(_audit_redact "$cmd")" || return 1
  fi
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
  esc_ts="$(json_escape "$ts")"
  esc_ver="$(json_escape "$version")"
  esc_scope="$(json_escape "$scope")"
  esc_cmd="$(json_escape "$cmd")"
  printf '{"ts":"%s","event":"old_bwrap_bypass","version":"%s","scope":"%s","cmd":"%s"}\n' \
    "$esc_ts" "$esc_ver" "$esc_scope" "$esc_cmd" >>"$f" || return 1
  return 0
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

# 宿主可执行文件、argv 与进程身份绝不能放进 guest 可写的 run/。
# sticky 系统目录下由用户持有的 0700 父目录对其他用户是安全的；
# guest 进程到不了这里，因为它在所有工作区 bind 之外。
_capbox_host_state_dir() {
  local uid ws project key base real parent dir candidate mode owner
  uid="$(id -u)" || return 1
  ws="$(readlink -f -- "$CAPBOX_WORKSPACE")" || return 1
  project="$(resolve_path "$CAPBOX_DIR")" || return 1
  key="$(printf '%s' "$project" | sha256sum)" || return 1
  key="${key%% *}"
  key="${key:0:32}"
  for base in "${XDG_RUNTIME_DIR:-}" "/run/user/$uid" /tmp; do
    [[ -n "$base" && -d "$base" && -w "$base" ]] || continue
    real="$(readlink -f -- "$base")" || continue
    case "$real" in "$ws"|"$ws"/*) continue ;; esac
    # 可写且非 sticky 的父目录会允许别人替换我们的私有树。
    mode="$(stat -c %a -- "$real")" || continue
    owner="$(stat -c %u -- "$real")" || continue
    if (( (8#$mode & 0022) != 0 )); then
      (( (8#$mode & 01000) != 0 )) &&
        [[ "$real" == /tmp || "$owner" == 0 || "$owner" == "$uid" ]] || continue
    else
      [[ "$owner" == "$uid" || "$owner" == 0 ]] || continue
    fi
    parent="$real/capbox-$uid"
    dir="$parent/$key"
    # 即使 XDG_RUNTIME_DIR 很长，也要给 AF_UNIX socket 名留出空间。
    (( ${#dir} <= 60 )) || continue
    for candidate in "$parent" "$dir"; do
      if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
        (umask 077; mkdir -- "$candidate") 2>/dev/null || true
      fi
      if [[ -L "$candidate" || ! -d "$candidate" ||
            "$(stat -c %u -- "$candidate")" != "$uid" ||
            "$(stat -c %a -- "$candidate")" != 700 ]]; then
        log_err "宿主私有目录必须由当前用户拥有、权限 0700 且不是符号链接: $candidate"
        return 1
      fi
    done
    printf '%s' "$dir"
    return 0
  done
  log_err "找不到工作区之外的安全宿主运行目录（需要私有 runtime 或 sticky /tmp）"
  return 1
}

# 过期的数字 PID 在复用后或另一个 PID ns 里可能指向无关进程。
_capbox_process_identity() {
  local pid="${1:-}" line ns
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
  IFS= read -r line <"/proc/$pid/stat" 2>/dev/null || return 1
  line="${line##*) }"
  local -a fields=()
  read -r -a fields <<<"$line"
  [[ ${#fields[@]} -ge 20 ]] || return 1
  ns="$(readlink "/proc/$pid/ns/pid")" || return 1
  printf '%s %s' "$ns" "${fields[19]}"
}

# 配置的解析、校验与持久化归 config；下方只做显式加载。
# shellcheck source=lib/config.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/config.sh" || return 1

# ---------- 4. 目录与路径工具 -------------------------------------------------

ensure_dirs() {
  local d
  for d in bin lib lib/guest cache cache/secrets secrets logs os run run/daemon run/tmp state test services; do
    mkdir -p "$CAPBOX_DIR/$d" 2>/dev/null || true
  done
}

# 把相对路径转成规范化绝对路径（不做存在性校验）
resolve_path() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1
  local out=""
  if have_cmd realpath; then
    out="$(realpath -m -- "$p" 2>/dev/null)" || out=""
  fi
  if [[ -z "$out" ]]; then
    log_err "无法规范化路径（需要可用的 realpath -m）: $p"
    return 1
  fi
  printf '%s\n' "$out"
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
  root="$(resolve_path "$CAPBOX_ROOTFS")" || return 1
  case "$guest_path" in
    *..*)
      log_err "guest 路径禁止 ..: $guest_path"
      return 1
      ;;
  esac
  case "$guest_path" in
    /*) resolved="$(resolve_path "$CAPBOX_ROOTFS$guest_path")" || return 1 ;;
    *) resolved="$(resolve_path "$CAPBOX_ROOTFS/$guest_path")" || return 1 ;;
  esac
  if [[ "$resolved" == "$root" || "$resolved" == "$root"/* ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  return 1
}

# 向 bwrap 参数数组追加：对工作区内的 bin/ lib/ config.env / services / logs 做 --ro-bind，
# 防止 guest 改写 CLI、注入宿主下次会读取的配置，或改写 logs/audit.jsonl
# （含「启动时缺失」路径，见 CVE-2026-25725 同类）。
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
  dir="$(_capbox_host_state_dir)/fs-placeholders" || return 1
  mkdir -p "$dir" 2>/dev/null || return 0
  marker="$dir/$(printf '%s' "$p" | sha256sum | awk '{print $1}')"
  printf '%s\t%s\n' "$kind" "$p" >"$marker" 2>/dev/null || true
}

# 清理本进程创建的空挂载点（oneshot 结束后调用；不删非空/已有真实配置）
_capbox_cleanup_fs_placeholders() {
  local dir marker kind path
  dir="$(_capbox_host_state_dir)/fs-placeholders" || return 1
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
    log_err "受保护配置路径是符号链接，拒绝启动: $host_file"
    return 1
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
    log_err "受保护目录是符号链接，拒绝启动: $host_dir"
    return 1
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

# logs/（含 audit.jsonl）必须整目录只读。符号链接或普通文件拒绝启动。
# 挂载没加进数组也拒绝，避免「目录建失败就静默跳过」变成可写。
_capbox_ro_protect_logs() {
  local arr_name="${1:-}"
  local -n _pl_arr="$arr_name"
  local host_dir="${CAPBOX_DIR:-}/logs"
  local before=${#_pl_arr[@]}

  if [[ -L "$host_dir" ]]; then
    log_err "logs 是符号链接，拒绝启动: $host_dir"
    return 1
  fi
  if [[ -e "$host_dir" && ! -d "$host_dir" ]]; then
    log_err "logs 必须是普通目录，拒绝启动: $host_dir"
    return 1
  fi
  _capbox_ro_protect_host_dir "$host_dir" "$arr_name" || return $?
  if [[ -L "$host_dir/audit.jsonl" ]]; then
    log_err "logs/audit.jsonl 是符号链接，拒绝启动: $host_dir/audit.jsonl"
    return 1
  fi
  if [[ -d "$host_dir/audit.jsonl" ]]; then
    log_err "logs/audit.jsonl 必须是普通文件，拒绝启动: $host_dir/audit.jsonl"
    return 1
  fi
  if (( ${#_pl_arr[@]} == before )); then
    log_err "无法把 logs 只读挂进 guest: $host_dir"
    return 1
  fi
  return 0
}

# guest 挂载点是否正好盖住 logs/ 或其内部路径。
_capbox_guest_covers_logs() {
  local guest="${1:-}" logs
  [[ -n "$guest" && "$guest" == /* ]] || return 1
  logs="$(_guest_workspace_path "${CAPBOX_DIR:-}/logs")"
  [[ -n "$logs" && "$logs" == /workspace/* ]] || return 1
  guest="${guest%/}"
  logs="${logs%/}"
  [[ "$guest" == "$logs" || "$guest" == "$logs"/* ]]
}

_capbox_append_ro_cli_binds() {
  local -n _ro_arr="$1"
  local host_path guest_path cap_guest sub sub_host sub_guest

  # 标准布局（…/.capbox）：整树只读，再把运行时目录 RW 挂回。
  # 这样即使宿主在 daemon 生命周期内 rm+重建 config.env，guest 也无法在只读树上创建。
  # CI/开发「仓库即 CAPBOX_DIR」布局不能整树只读（那会锁死整个 /workspace）。
  if [[ -L "${CAPBOX_DIR:-}" ]]; then
    log_err "CAPBOX_DIR 是符号链接，拒绝启动: $CAPBOX_DIR"
    return 1
  fi
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
      # logs 放在 run/cache 的可写挂回之后，显式只读覆盖父级挂载。
      _capbox_ro_protect_logs _ro_arr || return $?
      # 仍对 config.env 钉 /dev/null，避免通过已存在挂载点做内容注入的歧义
      _capbox_ro_protect_host_file "$CAPBOX_DIR/config.env" _ro_arr || return $?
      # 版本缓存不能被 guest 改成「已达标」。/dev/null 钉在路径上，宿主仍可就地写。
      _capbox_ro_protect_host_file "${CAPBOX_STATE_DIR:-$CAPBOX_DIR/state}/bwrap-version" _ro_arr || return $?
      return 0
    fi
  fi

  # 回退：逐项保护 bin/ lib/ config.env / services / logs
  for host_path in "${CAPBOX_BIN_DIR:-}" "${CAPBOX_LIB_DIR:-}"; do
    [[ -n "$host_path" ]] || continue
    if [[ -L "$host_path" ]]; then
      log_err "受保护目录是符号链接，拒绝启动: $host_path"
      return 1
    fi
    [[ -d "$host_path" ]] || continue
    guest_path="$(_guest_workspace_path "$host_path")"
    [[ -n "$guest_path" ]] || continue
    _ro_arr+=(--ro-bind "$host_path" "$guest_path")
  done
  _capbox_ro_protect_host_file "${CAPBOX_DIR:-}/config.env" _ro_arr || return $?
  _capbox_ro_protect_host_dir "${CAPBOX_DIR:-}/services" _ro_arr || return $?
  _capbox_ro_protect_logs _ro_arr || return $?
  _capbox_ro_protect_host_file "${CAPBOX_STATE_DIR:-$CAPBOX_DIR/state}/bwrap-version" _ro_arr || return $?
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
  local private lockfile
  private="$(_capbox_host_state_dir)" || return 1
  lockfile="$private/${name:-default}.lock"
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

# exec / shell / 服务 / daemon 共用同一套参数构造。
# shellcheck source=lib/launch.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/launch.sh" || return 1

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
  CAPBOX_BWRAP_BASELINE_CMD="$*"
  mapfile -t args < <(build_bwrap_args oneshot "$cwd"; printf 'CAPBOX_BWRAP_ARGS_RC=%s\n' "$?")
  # 从末尾取构造结果码，避免 mapfile 吞掉 build_bwrap_args 的退出码
  if [[ ${#args[@]} -gt 0 && "${args[-1]}" == CAPBOX_BWRAP_ARGS_RC=* ]]; then
    _bbrc="${args[-1]#CAPBOX_BWRAP_ARGS_RC=}"
    unset 'args[-1]'
  fi
  if (( _bbrc == 6 )); then
    die 6
  fi
  if (( _bbrc != 0 )); then
    die "$_bbrc" "无法构造 bwrap 参数（rc=$_bbrc；常见原因：bwrap 版本不足、FS_BINDS 越界、安全档/seccomp 失败）"
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
  if declare -F _landlock_apply_argv >/dev/null 2>&1; then
    _landlock_apply_argv full || return $?
  fi

  local rc=0 use_idmap=0 idmap_rc=1
  if declare -F _capbox_idmap_decision >/dev/null 2>&1; then
    idmap_rc=0
    _capbox_idmap_decision || idmap_rc=$?
  elif declare -F _idmap_enabled >/dev/null 2>&1; then
    idmap_rc=0
    _idmap_enabled || idmap_rc=$?
  fi
  if (( idmap_rc == 2 )); then
    die 1 "CAPBOX_IDMAP=on 但多 UID 映射不可用：${CAPBOX_IDMAP_DETAIL:-见 doctor}"
  fi
  if (( idmap_rc == 0 )); then
    use_idmap=1
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
      local yes=0 key="" val="" have_key=0 have_val=0 set_rc=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes)
            yes=1
            shift
            ;;
          *)
            if (( have_key == 0 )); then
              key="$1"
              have_key=1
            elif (( have_val == 0 )); then
              val="$1"
              have_val=1
            else
              die 2 "用法: capbox config set [--yes] KEY VALUE"
            fi
            shift
            ;;
        esac
      done
      (( have_key == 1 && have_val == 1 )) || die 2 "用法: capbox config set [--yes] KEY VALUE"
      if (( yes == 1 )); then
        CAPBOX_ALLOW_OLD_BWRAP_CONFIRM=1
      else
        unset CAPBOX_ALLOW_OLD_BWRAP_CONFIRM
      fi
      config_set "$key" "$val" || set_rc=$?
      unset CAPBOX_ALLOW_OLD_BWRAP_CONFIRM
      if (( set_rc != 0 )); then
        exit "$set_rc"
      fi
      log_info "已设置 ${key} = ${val}"
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

# 去掉审计探针留下的标记行，保留文件其余内容和 inode。
_doctor_strip_marker() {
  local f="${1:-}" mark="${2:-}" tmp
  [[ -n "$f" && -n "$mark" && -f "$f" && ! -L "$f" ]] || return 0
  grep -q -F -- "$mark" "$f" 2>/dev/null || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/capbox-audit-strip.XXXXXX")" || return 0
  if grep -v -F -- "$mark" "$f" >"$tmp"; then
    cat "$tmp" >"$f" 2>/dev/null || cp -f -- "$tmp" "$f" 2>/dev/null || true
  fi
  rm -f -- "$tmp"
}

# 探测 userns 内是否拿到全量 capability；成功时打印 CapEff 十六进制值
_doctor_probe_userns() {
  local bwrap="${CAPBOX_BWRAP:-}"
  [[ -x "$bwrap" ]] || return 5
  local out uid capeff
  out="$("$bwrap" --clearenv --unshare-net --unshare-user --unshare-uts --unshare-ipc \
    --uid 0 --gid 0 --cap-add ALL \
    --setenv PATH /usr/bin:/bin \
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

# 报告 bwrap 是否达到 0.12.0。放行不把这一项改成 PASS。
# 设置 CAPBOX_DOCTOR_BWRAP_VER_OK / _LAUNCH_OK / _BASELINE_FAIL 为 0 或 1。
_capbox_doctor_check_bwrap() {
  local bwrap="${1:-${CAPBOX_BWRAP:-}}"
  local _bv="" _scope=""
  CAPBOX_DOCTOR_BWRAP_VER_OK=0
  CAPBOX_DOCTOR_BWRAP_LAUNCH_OK=0
  CAPBOX_DOCTOR_BWRAP_BASELINE_FAIL=0
  if [[ -n "$bwrap" && -x "$bwrap" ]]; then
    _doctor_pass "bwrap 已安装 ($bwrap)"
    if _capbox_bwrap_version_ok "$bwrap"; then
      CAPBOX_DOCTOR_BWRAP_VER_OK=1
      CAPBOX_DOCTOR_BWRAP_LAUNCH_OK=1
      _doctor_pass "bwrap 版本 ${CAPBOX_BWRAP_VERSION_DETAIL}（>= 0.12.0）"
    else
      CAPBOX_DOCTOR_BWRAP_BASELINE_FAIL=1
      _bv="${CAPBOX_BWRAP_VERSION:-未知}"
      _doctor_fail "bwrap ${_bv} 低于安全基线 0.12.0"
      _capbox_print_old_bwrap_details 1
      if _scope="$(_capbox_old_bwrap_scope)"; then
        if [[ "$_scope" == "once" ]]; then
          _doctor_warn "bwrap ${_bv} 低于基线，本次 --allow-old-bwrap 放行（doctor 仍为 FAIL）"
        else
          _doctor_warn "bwrap ${_bv} 低于基线，已被 CAPBOX_ALLOW_OLD_BWRAP 放行（doctor 仍为 FAIL）"
        fi
        CAPBOX_DOCTOR_BWRAP_LAUNCH_OK=1
      fi
    fi
  else
    _doctor_fail "bwrap 不可用 (${bwrap:-未设置})；请安装 bubblewrap >= 0.12.0 或设置 CAPBOX_BWRAP"
  fi
}

cmd_doctor() {
  DOCTOR_FAILS=0
  DOCTOR_WARNS=0
  local bwrap="${CAPBOX_BWRAP:-}"
  local _bwrap_ver_ok=0
  local _bwrap_launch_ok=0
  local _bwrap_baseline_fail=0

  # 0) 工作区安全（禁止 $HOME 或 / 作为 RW workspace）
  if _capbox_workspace_is_dangerous; then
    _doctor_fail "工作区为 $HOME 或 / ($CAPBOX_WORKSPACE)；会把整棵目录 RW bind 进容器。请用项目内 .capbox/ 或 CAPBOX_ROOT=/path/to/project"
    return 1
  else
    _doctor_pass "工作区安全 ($CAPBOX_WORKSPACE)"
  fi

  # 1) bwrap。版本不够时退出码在函数末尾给 6；二进制缺失仍走一般 FAIL。
  _capbox_doctor_check_bwrap "$bwrap"
  _bwrap_ver_ok="${CAPBOX_DOCTOR_BWRAP_VER_OK:-0}"
  _bwrap_launch_ok="${CAPBOX_DOCTOR_BWRAP_LAUNCH_OK:-0}"
  _bwrap_baseline_fail="${CAPBOX_DOCTOR_BWRAP_BASELINE_FAIL:-0}"

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
      alpine)
        local _apk_arch="x86_64"
        if declare -F _capbox_arch >/dev/null 2>&1; then
          _apk_arch="$(_capbox_arch 2>/dev/null || echo x86_64)"
        fi
        url="$mirror_root/v3.24/main/${_apk_arch}/APKINDEX.tar.gz"
        ;;
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
  if declare -F _landlock_doctor_report >/dev/null 2>&1; then
    _landlock_doctor_report
  fi
  if declare -F _fsguard_doctor_report >/dev/null 2>&1; then
    _fsguard_doctor_report
  fi
  if declare -F _image_doctor_report >/dev/null 2>&1; then
    _image_doctor_report
  fi

  # 9) 环境变量清空（--clearenv 白名单）
  # 版本不够时不跑 oneshot：build_bwrap_args 会拒绝，探针会误报成「环境变量未清空」。
  if (( _bwrap_launch_ok == 1 )) && rootfs_ready && [[ -x "${CAPBOX_BWRAP:-}" ]]; then
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
  elif (( _bwrap_launch_ok != 1 && _bwrap_baseline_fail == 1 )); then
    _doctor_warn "跳过环境清空探测（bwrap 版本低于安全基线）"
  elif (( _bwrap_launch_ok != 1 && _bwrap_ver_ok != 1 )); then
    _doctor_warn "跳过环境清空探测（bwrap 不可用）"
  else
    _doctor_warn "跳过环境清空探测（rootfs 或 bwrap 不可用）"
  fi

  # 10) 缺失配置路径预占（CVE-2026-25725 同类：guest 不得创建宿主会读的 config/services）
  #     同时确认 logs/audit.jsonl 对 guest 只读。
  if (( _bwrap_launch_ok == 1 )) && rootfs_ready && [[ -x "${CAPBOX_BWRAP:-}" ]]; then
    local _cfg_g _svc_g _log_g _probe_out _probe_rc=0 _host_cfg _host_svc_probe _host_log _log_tampered=0
    _cfg_g="$(_guest_workspace_path "$CAPBOX_DIR/config.env")"
    _svc_g="$(_guest_workspace_path "$CAPBOX_DIR/services")"
    _log_g="$(_guest_workspace_path "$CAPBOX_DIR/logs/audit.jsonl")"
    _host_cfg="$CAPBOX_DIR/config.env"
    _host_svc_probe="$CAPBOX_DIR/services/_doctor_probe.env"
    _host_log="$CAPBOX_DIR/logs/audit.jsonl"
    if [[ -n "$_cfg_g" && "$_cfg_g" == /workspace/* && -n "$_svc_g" && "$_svc_g" == /workspace/* ]]; then
      if [[ -z "$_log_g" || "$_log_g" != /workspace/* ]]; then
        _doctor_fail "无法定位 guest 侧 logs/audit.jsonl，不能确认只读"
      else
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
          if echo CAPBOX_DOCTOR_AUDIT_TAMPER >> \"$_log_g\" 2>/dev/null; then echo LOG_WRITE_OK; fi
          echo PROBE_DONE
        "
      )" || _probe_rc=$?
      if [[ -f "$_host_log" && ! -L "$_host_log" ]] && grep -q -F -- 'CAPBOX_DOCTOR_AUDIT_TAMPER' "$_host_log" 2>/dev/null; then
        _log_tampered=1
        _doctor_strip_marker "$_host_log" 'CAPBOX_DOCTOR_AUDIT_TAMPER'
      fi
      if [[ "$_probe_out" == *LOG_WRITE_OK* ]]; then
        _log_tampered=1
      fi
      if [[ -f "$_host_cfg" ]] && grep -q 'DOCTOR_INJECT' "$_host_cfg" 2>/dev/null; then
        _doctor_fail "guest 写入了宿主 config.env（缺失/已存在路径未只读保护）"
      elif [[ -f "$_host_svc_probe" ]]; then
        _doctor_fail "guest 创建了宿主 services/_doctor_probe.env（services 目录未只读保护）"
        rm -f -- "$_host_svc_probe" 2>/dev/null || true
      elif [[ "$_probe_out" == *CFG_WRITE_OK* || "$_probe_out" == *SVC_WRITE_OK* ]]; then
        _doctor_fail "guest 可写受保护配置路径（probe out=${_probe_out:-<empty>}）"
      elif (( _log_tampered == 1 )); then
        _doctor_fail "guest 写入了宿主 logs/audit.jsonl（logs 未只读保护）"
      else
        _doctor_pass "配置路径预占生效（缺失/已存在的 config.env、services/ 与 logs/audit.jsonl 均不可被 guest 写入）"
      fi
      fi
    else
      _doctor_warn "跳过配置预占探测（CAPBOX_DIR 不在工作区视图内）"
    fi
  elif (( _bwrap_launch_ok != 1 && _bwrap_baseline_fail == 1 )); then
    _doctor_warn "跳过配置预占探测（bwrap 版本低于安全基线）"
  elif (( _bwrap_launch_ok != 1 && _bwrap_ver_ok != 1 )); then
    _doctor_warn "跳过配置预占探测（bwrap 不可用）"
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
  if (( _bwrap_baseline_fail == 1 )); then
    printf '自检结果: 安全基线不满足（退出码 6）；%d 项 FAIL，%d 项 WARN\n' "$DOCTOR_FAILS" "$DOCTOR_WARNS"
    return 6
  fi
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
