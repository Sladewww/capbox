# shellcheck shell=bash
# =============================================================================
# CapBox - resources.sh
# CPU / 内存 / PIDs /（诚实声明的）磁盘限额。
#
# CAPBOX_MEMORY_MAX  例: 512M 512Mi 1G 268435456
# CAPBOX_PIDS_MAX    例: 256
# CAPBOX_CPU_MAX     例: 50%  或 cgroup 原样 "50000 100000"
# CAPBOX_DISK_MAX    例: 64M / 1G — 仅当能 losetup+mkfs.ext4+mount 时兑现：
#   稀疏镜像放在 state/disk（不放 guest 可写的 run/）；loop → ext4，挂到
#   $base/mnt（nosuid,nodev），再在 bwrap 的第一个 -- 之前 --bind 到
#   CAPBOX_DISK_GUEST_PATH（默认 /var/lib/capbox-data）。不改 rootfs 的
#   --ro-bind，也不把整棵 rootfs bind 进配额目录。
#   不把宿主块设备节点当作配额盘交给 guest；--dev 使用 bwrap 私有 /dev。
#   需要宿主授权：root，或 sudo -n（不能伪装成无特权/rootless）。
#   限额仅覆盖该 guest 路径，不含整个 rootfs 或 /workspace；宿主 /tmp 不作配额后端。
#   卸载失败则保留目录，禁止 rm 仍挂着的树；sudo 清理失败不回落到无特权 rm。
# CAPBOX_CGROUP_ROOT 可选：显式 cgroup v2 父目录（须已委派且可建子目录并出现
#   memory.max/cpu.max/pids.max）。指定后严格使用，不回退其它候选；不可用则明确失败。
#   注意：CAPBOX_RUN_DIR 会被 common.sh 覆盖，不能用来指定 cgroup 父目录。
# CAPBOX_RESOURCES_MODE=warn|require
#   warn    （默认）cgroup 不可用时 WARN；MEMORY 可降级 prlimit RLIMIT_AS（近似，非 memory.max）
#           但若设置了 CAPBOX_CGROUP_ROOT 却不可用，不悄悄降级 prlimit
#   require （fail-closed）任一已配置限额无法按 cgroup（或声明的精确机制）兑现则硬失败
#
# 注意：
#   * RLIMIT_NPROC 按 UID 全局计数，绝不冒充 PIDs。
#   * 绝不把 prlimit 宣传成精确 cgroup memory.max。
#   * 仅能 mkdir 子目录但子 cgroup 无控制器接口 ≠ ready（常见于进程所在 scope 的 EBUSY）。
#   * setup 经 CAPBOX_RESOURCES_CGROUP_LEAF / APPLIED_* 全局回传；调用方禁止 $() 包一层。
#   * 本环境若无法写宿主 cgroup，doctor/status 会给出证据路径与权限错误。
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

_resources_mode() {
  case "${CAPBOX_RESOURCES_MODE:-warn}" in
    require|strict|fail-closed|fail_closed) printf 'require' ;;
    *) printf 'warn' ;;
  esac
}

_resources_any_configured() {
  [[ -n "${CAPBOX_MEMORY_MAX:-}" || -n "${CAPBOX_PIDS_MAX:-}" || -n "${CAPBOX_CPU_MAX:-}" || -n "${CAPBOX_DISK_MAX:-}" ]]
}

_resources_probe_cgroup() {
  CAPBOX_CGROUP_STATUS=missing
  CAPBOX_CGROUP_DETAIL=""
  CAPBOX_CGROUP_ACTIVE=""
  CAPBOX_CGROUP_FIND_WHY=""
  # 不清理 CAPBOX_CGROUP_ROOT：它是用户可选覆盖，不得被 probe/其它路径覆写

  if [[ ! -d /sys/fs/cgroup ]]; then
    CAPBOX_CGROUP_DETAIL="$(i18n_get res.detail_no_sys_fs_cgroup)"
    return 1
  fi
  if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
    CAPBOX_CGROUP_DETAIL="$(i18n_get res.detail_not_cgroup_v2)"
    return 1
  fi

  local find_out=""
  if find_out="$(_resources_find_cgroup_root)"; then
    if ! _resources_self_cgroup_writable; then
      CAPBOX_CGROUP_ACTIVE=""
      CAPBOX_CGROUP_STATUS=denied
      CAPBOX_CGROUP_DETAIL="$(i18n_fmt res.detail_root_ok_self_not_writable root="$find_out" hint="$(_resources_cgroup_dual_hint)")"
      return 1
    fi
    CAPBOX_CGROUP_ACTIVE="$find_out"
    CAPBOX_CGROUP_STATUS=ready
    if [[ -n "${CAPBOX_CGROUP_ROOT:-}" ]]; then
      CAPBOX_CGROUP_DETAIL="$(i18n_fmt res.detail_cgroup_root_writable root="$find_out")"
    else
      CAPBOX_CGROUP_DETAIL="$(i18n_fmt res.detail_writable_cgroup_root root="$find_out")"
    fi
    return 0
  fi
  CAPBOX_CGROUP_FIND_WHY="$find_out"

  if [[ -n "${CAPBOX_CGROUP_ROOT:-}" ]]; then
    CAPBOX_CGROUP_STATUS=denied
    CAPBOX_CGROUP_DETAIL="$(i18n_fmt res.detail_cgroup_root_unusable root="${CAPBOX_CGROUP_ROOT}" reason="$(i18n_or "${find_out:-}" res.detail_cgroup_root_unwritable_fallback)")"
    return 1
  fi

  local self cgpath err
  self="$(awk -F: '{print $NF; exit}' /proc/self/cgroup 2>/dev/null || true)"
  cgpath="/sys/fs/cgroup${self}"
  err="$(mkdir "${cgpath}/.capbox-probe-$$" 2>&1 || true)"
  rmdir "${cgpath}/.capbox-probe-$$" 2>/dev/null || true
  CAPBOX_CGROUP_STATUS=denied
  local _hint _ctrls _reason
  _hint="$(_resources_cgroup_dual_hint)"
  _ctrls="$(tr ' ' ',' </sys/fs/cgroup/cgroup.controllers 2>/dev/null || echo '?')"
  if [[ -n "$_hint" && "${find_out}" == *"$_hint"* ]]; then
    CAPBOX_CGROUP_DETAIL="$(i18n_fmt res.detail_no_usable_cgroup_parent self="${self:-/}" reason="${find_out}" controllers="$_ctrls")"
  else
    _reason="${find_out:-}"
    [[ -n "$_reason" ]] || _reason="$(i18n_fmt res.detail_mkdir_evidence err="${err:-permission denied}")"
    CAPBOX_CGROUP_DETAIL="$(i18n_fmt res.detail_no_usable_cgroup_parent_no_delegate self="${self:-/}" reason="$_reason" controllers="$_ctrls" hint="$_hint")"
  fi
  return 1
}

_resources_cgroup_try_enable() {
  local root="$1"
  [[ -e "$root/cgroup.subtree_control" ]] || return 0
  local ctrl
  # 不强制 io：WSL 用户层级常无 io 委派
  for ctrl in memory pids cpu; do
    echo "+$ctrl" >"$root/cgroup.subtree_control" 2>/dev/null || true
  done
  if [[ -n "${CAPBOX_IO_MAX:-}" ]]; then
    echo "+io" >"$root/cgroup.subtree_control" 2>/dev/null || true
  fi
}

# 真实探针：mkdir 子 cgroup → 写 subtree_control(+memory) → 写 memory.max → rmdir。
# 任一步失败都不算可用。失败原因写入 CAPBOX_CGROUP_FIND_WHY；_resources_find_cgroup_root 亦经 stdout 回传。
_resources_cgroup_dual_hint() {
  i18n_get res.cgroup_dual_hint
}

# 迁移进子 cgroup 时，源 cgroup 的 cgroup.procs 也必须可写。
_resources_self_cgroup_writable() {
  local self cgpath
  self="$(awk -F: '($1=="0" || $1==""){print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
  [[ "$self" == *:* ]] && self="${self##*:}"
  [[ -n "$self" ]] || return 1
  cgpath="/sys/fs/cgroup${self}"
  [[ -d "$cgpath" && -w "${cgpath}/cgroup.procs" ]]
}

_resources_cgroup_root_usable() {
  local root="$1"
  local probe err=""
  if [[ ! -d "$root" ]]; then
    CAPBOX_CGROUP_FIND_WHY="$(i18n_get res.find_why_not_dir)"
    return 1
  fi
  probe="$root/.capbox-ctrl-probe-$$-$RANDOM"
  if ! mkdir "$probe" 2>/dev/null; then
    err="$(mkdir "$probe" 2>&1 || true)"
    CAPBOX_CGROUP_FIND_WHY="$(i18n_fmt res.find_why_mkdir_failed err="${err:-permission denied}")"
    return 1
  fi

  if [[ -e "$root/cgroup.subtree_control" ]]; then
    # 真实 cgroupfs：必须能向父级写入 +memory；失败通常是父级仍有进程（EBUSY）
    if ! echo '+memory' >"$root/cgroup.subtree_control" 2>/dev/null; then
      err="$(echo '+memory' >"$root/cgroup.subtree_control" 2>&1 || true)"
      rmdir "$probe" 2>/dev/null || true
      CAPBOX_CGROUP_FIND_WHY="$(i18n_fmt res.find_why_subtree_control err="${err:-EBUSY/denied}" hint="$(_resources_cgroup_dual_hint)")"
      return 1
    fi
    echo '+pids' >"$root/cgroup.subtree_control" 2>/dev/null || true
    echo '+cpu' >"$root/cgroup.subtree_control" 2>/dev/null || true
    if [[ -n "${CAPBOX_IO_MAX:-}" ]]; then
      echo '+io' >"$root/cgroup.subtree_control" 2>/dev/null || true
    fi
  else
    # 非 cgroupfs / 单元测试桩：保留 hook 注入控制器文件
    _resources_cgroup_try_enable "$root"
  fi

  if [[ ! -e "$probe/memory.max" ]]; then
    rmdir "$probe" 2>/dev/null || true
    CAPBOX_CGROUP_FIND_WHY="$(i18n_fmt res.find_why_no_memory_max hint="$(_resources_cgroup_dual_hint)")"
    return 1
  fi

  # 仅有控制器文件不够：必须能写入 memory.max（与 exec 路径一致）。
  # 使用 >|：cgroup 文件已存在，且部分环境开了 noclobber（set -C）。
  if ! { echo max >|"$probe/memory.max"; } 2>/dev/null; then
    err="$( { echo max >|"$probe/memory.max"; } 2>&1 || true)"
    rmdir "$probe" 2>/dev/null || true
    CAPBOX_CGROUP_FIND_WHY="$(i18n_fmt res.find_why_memory_max_unwritable err="${err:-permission denied}" hint="$(_resources_cgroup_dual_hint)")"
    return 1
  fi

  rmdir "$probe" 2>/dev/null || true
  CAPBOX_CGROUP_FIND_WHY=""
  return 0
}

# 成功：stdout=路径，rc=0。失败：stdout=原因，rc=1（兼容 $() 调用方）。
_resources_find_cgroup_root() {
  CAPBOX_CGROUP_FIND_WHY=""
  if [[ -n "${CAPBOX_CGROUP_ROOT:-}" ]]; then
    if _resources_cgroup_root_usable "$CAPBOX_CGROUP_ROOT"; then
      printf '%s' "$CAPBOX_CGROUP_ROOT"
      return 0
    fi
    printf '%s' "$(i18n_or "${CAPBOX_CGROUP_FIND_WHY:-}" val.unavailable)"
    return 1
  fi

  local candidates=() cur
  cur="$(awk -F: '($1=="0" || $1==""){print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
  [[ "$cur" == *:* ]] && cur="${cur##*:}"
  [[ -n "$cur" ]] && candidates+=("/sys/fs/cgroup$cur" "/sys/fs/cgroup/$cur")
  candidates+=(
    "/sys/fs/cgroup"
    "${XDG_RUNTIME_DIR:-}/cgroup"
  )

  local c last_why=""
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -d "$c" ]] || continue
    if _resources_cgroup_root_usable "$c"; then
      printf '%s' "$c"
      return 0
    fi
    last_why="${CAPBOX_CGROUP_FIND_WHY:-}"
  done
  CAPBOX_CGROUP_FIND_WHY="${last_why}"
  printf '%s' "$(i18n_or "${last_why:-}" res.find_why_no_usable_parent)"
  return 1
}

_resources_setup_cgroup() {
  local root leaf find_out=""
  if ! find_out="$(_resources_find_cgroup_root)"; then
    if [[ -n "${CAPBOX_CGROUP_ROOT:-}" ]]; then
      i18n_warn res.capbox_cgroup_root_unavailable path="${CAPBOX_CGROUP_ROOT}" find_out="${find_out:-unknown}"
    fi
    CAPBOX_CGROUP_FIND_WHY="${find_out}"
    return 1
  fi
  root="$find_out"
  leaf="$root/capbox-$$-$RANDOM"
  mkdir -p "$leaf" 2>/dev/null || return 1
  _resources_cgroup_try_enable "$root"

  local applied=0
  CAPBOX_RESOURCES_APPLIED_MEMORY=""
  CAPBOX_RESOURCES_APPLIED_PIDS=""
  CAPBOX_RESOURCES_APPLIED_CPU=""
  CAPBOX_RESOURCES_APPLIED_IO=""

  if [[ -n "${CAPBOX_MEMORY_MAX:-}" ]]; then
    local bytes
    if bytes="$(_resources_parse_bytes "$CAPBOX_MEMORY_MAX")"; then
      if [[ -e "$leaf/memory.max" && -w "$leaf/memory.max" ]] && echo "$bytes" >"$leaf/memory.max" 2>/dev/null; then
        applied=1
        CAPBOX_RESOURCES_APPLIED_MEMORY="cgroup:$bytes"
      else
        i18n_warn res.memory_max_could_not_written_cgroup_memory value="$CAPBOX_MEMORY_MAX"
      fi
    else
      i18n_warn res.unable_parse_memory_max value="$CAPBOX_MEMORY_MAX"
    fi
  fi
  if [[ -n "${CAPBOX_PIDS_MAX:-}" ]]; then
    if [[ "$CAPBOX_PIDS_MAX" =~ ^[0-9]+$ ]]; then
      if [[ -e "$leaf/pids.max" && -w "$leaf/pids.max" ]] && echo "$CAPBOX_PIDS_MAX" >"$leaf/pids.max" 2>/dev/null; then
        applied=1
        CAPBOX_RESOURCES_APPLIED_PIDS="cgroup:$CAPBOX_PIDS_MAX"
      else
        i18n_warn res.pids_max_could_not_written_cgroup_pids value="$CAPBOX_PIDS_MAX"
      fi
    else
      i18n_warn res.pids_max_must_positive_integer_got value="$CAPBOX_PIDS_MAX"
    fi
  fi
  if [[ -n "${CAPBOX_CPU_MAX:-}" ]]; then
    local cpuv
    if cpuv="$(_resources_parse_cpu_max "$CAPBOX_CPU_MAX")"; then
      if [[ -e "$leaf/cpu.max" && -w "$leaf/cpu.max" ]] && echo "$cpuv" >"$leaf/cpu.max" 2>/dev/null; then
        applied=1
        CAPBOX_RESOURCES_APPLIED_CPU="cgroup:$cpuv"
      else
        i18n_warn res.cpu_max_could_not_written_cgroup_cpu value="$CAPBOX_CPU_MAX"
      fi
    else
      i18n_warn res.unable_parse_cpu_max_supports_50_quota value="$CAPBOX_CPU_MAX"
    fi
  fi
  if [[ -n "${CAPBOX_IO_MAX:-}" && -e "$leaf/io.max" && -w "$leaf/io.max" ]]; then
    if echo "$CAPBOX_IO_MAX" >"$leaf/io.max" 2>/dev/null; then
      applied=1
      CAPBOX_RESOURCES_APPLIED_IO="cgroup:$CAPBOX_IO_MAX"
    fi
  fi

  (( applied == 1 )) || {
    rmdir "$leaf" 2>/dev/null || true
    CAPBOX_RESOURCES_CGROUP_LEAF=""
    return 1
  }
  # 经全局回传 leaf，避免 wrap 用 $() 导致 APPLIED_* 落在子 shell
  CAPBOX_RESOURCES_CGROUP_LEAF="$leaf"
  CAPBOX_CGROUP_ACTIVE="$root"
  return 0
}

_resources_disk_guest_path() {
  # 配额盘在 guest 里的挂载点。必须是绝对路径，且不能借 .. 或 /. 逃出。
  local p="${CAPBOX_DISK_GUEST_PATH:-/var/lib/capbox-data}" c
  [[ "$p" == /* ]] || return 1
  [[ "$p" != *[[:space:]\\]* ]] || return 1
  p="${p%/}"
  [[ -n "$p" && "$p" == /* ]] || return 1
  [[ "$p" != *".."* && "$p" != *"/."* ]] || return 1
  local IFS=/
  local -a parts=()
  read -r -a parts <<< "${p#/}"
  (( ${#parts[@]} > 0 )) || return 1
  for c in "${parts[@]}"; do
    [[ -n "$c" && "$c" != "." && "$c" != ".." ]] || return 1
  done
  printf '%s' "$p"
}

_resources_disk_priv_mode() {
  CAPBOX_DISK_PRIV_MODE=none
  if [[ ! -e /dev/loop-control ]]; then
    printf '%s' "none"
    return 1
  fi
  if ! PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}" command -v losetup >/dev/null 2>&1 || ! PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}" command -v mkfs.ext4 >/dev/null 2>&1 || ! command -v mount >/dev/null 2>&1; then
    printf '%s' "none"
    return 1
  fi
  if [[ "$(id -u)" -eq 0 || -w /dev/loop-control ]]; then
    # 即便可写 loop-control，mount --bind 仍常需 CAP_SYS_ADMIN；root 则 direct
    if [[ "$(id -u)" -eq 0 ]]; then
      CAPBOX_DISK_PRIV_MODE=direct
      printf '%s' "direct"
      return 0
    fi
  fi
  if have_cmd sudo && sudo -n true 2>/dev/null; then
    CAPBOX_DISK_PRIV_MODE=sudo
    printf '%s' "sudo"
    return 0
  fi
  if [[ -w /dev/loop-control ]]; then
    # 尝试 direct（部分环境 disk 组 + 已有能力可 mount）
    CAPBOX_DISK_PRIV_MODE=direct
    printf '%s' "direct"
    return 0
  fi
  printf '%s' "none"
  return 1
}

_resources_disk_priv() {
  if [[ "${CAPBOX_DISK_PRIV_MODE:-}" == "sudo" ]]; then
    sudo -n "$@"
  else
    "$@"
  fi
}

_resources_probe_disk() {
  CAPBOX_DISK_STATUS=unavailable
  CAPBOX_DISK_DETAIL=""
  CAPBOX_DISK_PRIV_MODE="${CAPBOX_DISK_PRIV_MODE:-none}"
  if [[ -z "${CAPBOX_DISK_MAX:-}" ]]; then
    CAPBOX_DISK_STATUS=unset
    CAPBOX_DISK_DETAIL="$(i18n_get res.disk_detail_unset)"
    return 1
  fi
  local guest=""
  if ! guest="$(_resources_disk_guest_path)"; then
    CAPBOX_DISK_DETAIL="$(i18n_get res.disk_detail_guest_path_invalid)"
    return 1
  fi
  if ! PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}" command -v losetup >/dev/null 2>&1 || ! PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}" command -v mkfs.ext4 >/dev/null 2>&1 || ! command -v mount >/dev/null 2>&1; then
    CAPBOX_DISK_DETAIL="$(i18n_get res.disk_detail_missing_tools)"
    return 1
  fi
  if [[ ! -e /dev/loop-control ]]; then
    CAPBOX_DISK_DETAIL="$(i18n_get res.disk_detail_no_loop_control)"
    return 1
  fi
  local mode
  # 勿 $()：_resources_disk_priv_mode 需把 CAPBOX_DISK_PRIV_MODE 留在当前 shell
  if _resources_disk_priv_mode >/dev/null; then
    mode="${CAPBOX_DISK_PRIV_MODE}"
  else
    mode=none
    CAPBOX_DISK_PRIV_MODE=none
  fi
  case "$mode" in
    direct)
      CAPBOX_DISK_STATUS=capable
      CAPBOX_DISK_DETAIL="$(i18n_fmt res.disk_detail_priv_direct guest="$guest")"
      return 0
      ;;
    sudo)
      CAPBOX_DISK_STATUS=capable
      CAPBOX_DISK_DETAIL="$(i18n_fmt res.disk_detail_priv_sudo guest="$guest")"
      return 0
      ;;
    *)
      local lsout
      lsout="$(ls -l /dev/loop-control 2>&1 || true)"
      CAPBOX_DISK_DETAIL="$(i18n_fmt res.disk_detail_no_priv lsout="$lsout")"
      return 1
      ;;
  esac
}

# 在 bwrap argv 的第一个 -- 之前插入 --bind host_mnt guest。不改 rootfs 挂载。
_resources_disk_bind_into() {
  local -n _bi="$1"
  local host_mnt="$2" guest="$3"
  local i
  for (( i = 0; i < ${#_bi[@]}; i++ )); do
    if [[ "${_bi[$i]}" == "--" ]]; then
      _bi=("${_bi[@]:0:$i}" --bind "$host_mnt" "$guest" "${_bi[@]:$i}")
      return 0
    fi
  done
  return 1
}

# direct 与 sudo -n 共用这一份。脚本不接收 rootfs 路径，也不会把 rootfs bind 进来。
_resources_disk_write_ops() {
  local dest="${1:-}"
  [[ -n "$dest" ]] || return 1
  cat >"$dest" <<'EOS'
#!/bin/bash
set -euo pipefail
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}"
cmd="${1:-}"
base="${2:-}"
img="${3:-}"
bytes="${4:-}"

reject_symlink() {
  local p
  for p in "$@"; do
    if [[ -L "$p" ]]; then
      printf 'capbox: refuse symlink: %s\n' "$p" >&2
      exit 1
    fi
  done
}

mounted() {
  local mnt="$1" line mp
  [[ -r /proc/self/mountinfo ]] || return 1
  while IFS= read -r line; do
    mp="${line#* * * * }"
    mp="${mp%% *}"
    mp="${mp//\\040/ }"
    [[ "$mp" == "$mnt" ]] && return 0
  done < /proc/self/mountinfo
  return 1
}

valid_loop() {
  [[ "${1:-}" =~ ^/dev/loop[0-9]+$ ]]
}

case "$cmd" in
  setup)
    [[ -n "$base" && -n "$img" && "$bytes" =~ ^[0-9]+$ ]] || exit 2
    reject_symlink "$base" "$(dirname -- "$img")"
    [[ -d "$base" && ! -L "$base" ]] || exit 1
    if [[ -d "$base/mnt" || -L "$base/mnt" ]]; then
      reject_symlink "$base/mnt"
    else
      mkdir -- "$base/mnt"
    fi
    reject_symlink "$base/mnt"
    if [[ -e "$img" || -L "$img" ]]; then
      printf 'capbox: image already exists: %s\n' "$img" >&2
      exit 1
    fi
    ( set -o noclobber; : >"$img" )
    reject_symlink "$img"
    [[ -f "$img" ]] || exit 1
    truncate -s "$bytes" "$img"
    loop="$(losetup -f --show "$img")" || exit 1
    loop="${loop//[[:space:]]/}"
    if ! valid_loop "$loop"; then
      losetup -d "$loop" 2>/dev/null || true
      printf 'capbox: unexpected loop device: %s\n' "$loop" >&2
      exit 1
    fi
    printf '%s\n' "$loop" >"$base/loop.dev"
    mkfs.ext4 -F -q "$loop"
    mount -o nosuid,nodev "$loop" "$base/mnt"
    chmod 0777 "$base/mnt" 2>/dev/null || true
    ;;
  cleanup)
    [[ -n "$base" ]] || exit 0
    if [[ -L "$base" ]]; then
      printf 'capbox: refuse symlink disk dir: %s\n' "$base" >&2
      exit 1
    fi
    [[ -d "$base" ]] || exit 0
    mnt="$base/mnt"
    if mounted "$mnt"; then
      umount "$mnt"
      if mounted "$mnt"; then
        printf 'capbox: still mounted: %s\n' "$mnt" >&2
        exit 1
      fi
    fi
    if [[ -f "$base/loop.dev" && ! -L "$base/loop.dev" ]]; then
      loop="$(tr -d '[:space:]' <"$base/loop.dev" || true)"
      if valid_loop "$loop"; then
        losetup -d "$loop" 2>/dev/null || true
      fi
    fi
    rm -rf --one-file-system -- "$base"
    ;;
  *)
    exit 2
    ;;
esac
EOS
  chmod 0700 "$dest" 2>/dev/null || true
}

_resources_disk_run_ops() {
  local mode="$1" ops="$2"
  shift 2
  if [[ "$mode" == "sudo" ]]; then
    sudo -n bash "$ops" "$@"
  else
    bash "$ops" "$@"
  fi
}

_resources_disk_fail_cleanup() {
  local mode="$1" ops="$2" base="$3" detail="$4"
  if ! _resources_disk_run_ops "$mode" "$ops" cleanup "$base"; then
    i18n_err res.disk_max_cleanup_failed_leaving_will_not base="${base}"
  else
    rm -f -- "$ops" 2>/dev/null || true
  fi
  CAPBOX_DISK_DETAIL="$detail"
  return 1
}

_resources_apply_disk_wrap() {
  local -n _dw_cmd="$1"
  local bytes mode base img guest ops diskroot
  CAPBOX_RESOURCES_APPLIED_DISK=""

  bytes="$(_resources_parse_bytes "${CAPBOX_DISK_MAX:-}")" || {
    i18n_warn res.unable_parse_disk_max value="${CAPBOX_DISK_MAX:-}"
    return 1
  }
  guest="$(_resources_disk_guest_path)" || {
    CAPBOX_DISK_DETAIL="$(i18n_get res.disk_detail_guest_path_invalid)"
    return 1
  }
  _resources_probe_disk || return 1
  mode="${CAPBOX_DISK_PRIV_MODE:-none}"
  [[ "$mode" != "none" ]] || return 1
  [[ -d "${CAPBOX_ROOTFS:-}" && ! -L "${CAPBOX_ROOTFS}" ]] || return 1

  diskroot="${CAPBOX_STATE_DIR:?}/disk"
  mkdir -p -- "$diskroot" || return 1
  if [[ -L "$diskroot" || -L "${CAPBOX_STATE_DIR}" ]]; then
    CAPBOX_DISK_DETAIL="$(i18n_get res.disk_detail_state_symlink)"
    return 1
  fi
  base="$(mktemp -d "$diskroot/d.XXXXXX")" || return 1
  if [[ -L "$base" || ! -d "$base" ]]; then
    CAPBOX_DISK_DETAIL="$(i18n_get res.disk_detail_quota_dir_not_real)"
    return 1
  fi
  img="$base/disk.img"
  local private
  private="$(_capbox_host_state_dir)" || return 1
  ops="$(mktemp "$private/capbox-disk-ops.XXXXXX")" || {
    rmdir -- "$base" 2>/dev/null || true
    return 1
  }
  if ! _resources_disk_write_ops "$ops"; then
    rm -f -- "$ops"
    rmdir -- "$base" 2>/dev/null || true
    return 1
  fi

  if ! _resources_disk_run_ops "$mode" "$ops" setup "$base" "$img" "$bytes"; then
    _resources_disk_fail_cleanup "$mode" "$ops" "$base" "$(i18n_fmt res.disk_detail_loop_setup_failed mode="$mode")"
    return 1
  fi

  local -a inner=("${_dw_cmd[@]}")
  if ! _resources_disk_bind_into inner "$base/mnt" "$guest"; then
    _resources_disk_fail_cleanup "$mode" "$ops" "$base" "$(i18n_get res.disk_detail_no_dashdash)"
    return 1
  fi

  # 命令结束后用同一份脚本卸载。sudo 失败不回落到无特权 rm。
  # 在宿主上译好文案再嵌入 bash -c；子脚本内不得调用 i18n_*。
  local unload_fail
  unload_fail="$(i18n_get res.disk_max_unload_failed_leaving)"
  _dw_cmd=(
    /bin/bash -c
    'set -u
     base=$1; mode=$2; ops=$3; shift 3
     priv_cleanup() {
       local rc=0
       if [[ "$mode" == "sudo" ]]; then
         sudo -n bash "$ops" cleanup "$base" || rc=1
       else
         bash "$ops" cleanup "$base" || rc=1
       fi
       if [[ "$rc" -eq 0 ]]; then
         rm -f -- "$ops"
       else
         _um='"$(printf '%q' "$unload_fail")"'
         printf "%s\n" "${_um//\{base\}/$base}" >&2
       fi
       return "$rc"
     }
     trap "priv_cleanup || exit 1" EXIT
     "$@"
     rc=$?
     trap - EXIT
     priv_cleanup || exit 1
     exit "$rc"'
    bash
    "$base"
    "$mode"
    "$ops"
    "${inner[@]}"
  )

  CAPBOX_DISK_BASE="$base"
  CAPBOX_RESOURCES_APPLIED_DISK="loop:${bytes}:${guest}"
  log_debug "DISK_MAX applied: $bytes -> guest:$guest via state loop (priv=$mode)"
  return 0
}

_resources_fail_closed_check() {
  [[ "$(_resources_mode)" == "require" ]] || return 0
  local missing=()
  if [[ -n "${CAPBOX_MEMORY_MAX:-}" && "${CAPBOX_RESOURCES_APPLIED_MEMORY:-}" != cgroup:* ]]; then
    missing+=("$(i18n_get res.fail_closed_memory_max)")
  fi
  if [[ -n "${CAPBOX_PIDS_MAX:-}" && "${CAPBOX_RESOURCES_APPLIED_PIDS:-}" != cgroup:* ]]; then
    missing+=("$(i18n_get res.fail_closed_pids_max)")
  fi
  if [[ -n "${CAPBOX_CPU_MAX:-}" && "${CAPBOX_RESOURCES_APPLIED_CPU:-}" != cgroup:* ]]; then
    missing+=("$(i18n_get res.fail_closed_cpu_max)")
  fi
  if [[ -n "${CAPBOX_DISK_MAX:-}" && "${CAPBOX_RESOURCES_APPLIED_DISK:-}" != loop:* ]]; then
    _resources_probe_disk || true
    missing+=("DISK_MAX($(i18n_or "${CAPBOX_DISK_DETAIL:-}" res.fail_closed_disk_not_honored))")
  fi
  if (( ${#missing[@]} > 0 )); then
    i18n_err res.capbox_resources_mode_require_following_limits_cannot missing="${missing[*]}"
    return 1
  fi
  return 0
}

_resources_wrap_argv() {
  local -n _rw_cmd="$1"
  CAPBOX_RESOURCES_APPLIED_MEMORY="${CAPBOX_RESOURCES_APPLIED_MEMORY:-}"
  CAPBOX_RESOURCES_APPLIED_PIDS="${CAPBOX_RESOURCES_APPLIED_PIDS:-}"
  CAPBOX_RESOURCES_APPLIED_CPU="${CAPBOX_RESOURCES_APPLIED_CPU:-}"
  CAPBOX_RESOURCES_APPLIED_DISK="${CAPBOX_RESOURCES_APPLIED_DISK:-}"

  _resources_any_configured || return 0

  CAPBOX_RESOURCES_CGROUP_LEAF=""
  local cgroup_ok=0
  if _resources_setup_cgroup; then
    cgroup_ok=1
    local leaf_missing
    leaf_missing="$(i18n_get res.cgroup_leaf_missing_after_setup)"
    local cg="${CAPBOX_RESOURCES_CGROUP_LEAF:?$leaf_missing}"
    local -a inner=("${_rw_cmd[@]}")
    # 在宿主上译好文案再嵌入 bash -c；子脚本内不得调用 i18n_*。
    local procs_fail
    procs_fail="$(i18n_get res.cgroup_procs_write_failed)"
    local -a confirmed=()
    if [[ -n "${_audit_task_id:-}" ]] && _audit_enabled; then
      confirmed=(python3 "$CAPBOX_LIB_DIR/audit_store.py" "$_audit_task_path"
        "$_audit_task_id" "cgroup_joined memory=$CAPBOX_RESOURCES_APPLIED_MEMORY cpu=$CAPBOX_RESOURCES_APPLIED_CPU pids=$CAPBOX_RESOURCES_APPLIED_PIDS")
    fi
    _rw_cmd=(
      /bin/bash -c
      'if ! echo $$ >"$1/cgroup.procs"; then printf "%s\n" '"$(printf '%q' "$procs_fail")"' >&2; exit 1; fi
       shift
       count=$1; shift
       if (( count )); then "${@:1:count}" 2>/dev/null || true; shift "$count"; fi
       exec "$@"'
      bash
      "$cg"
      "${#confirmed[@]}" "${confirmed[@]}"
      "${inner[@]}"
    )
    log_debug "resource limits applied via cgroup: $cg (mem=${CAPBOX_RESOURCES_APPLIED_MEMORY:-} cpu=${CAPBOX_RESOURCES_APPLIED_CPU:-} pids=${CAPBOX_RESOURCES_APPLIED_PIDS:-})"
  else
    _resources_probe_cgroup || true

    if [[ -n "${CAPBOX_CPU_MAX:-}" ]]; then
      i18n_warn res.cpu_max_not_applied value="$CAPBOX_CPU_MAX" detail="$(i18n_or "${CAPBOX_CGROUP_DETAIL:-}" val.no_cgroup_delegate)"
    fi
    if [[ -n "${CAPBOX_PIDS_MAX:-}" ]]; then
      i18n_warn res.pids_max_not_applied_cgroup_pids_required value="$CAPBOX_PIDS_MAX"
    fi

    if [[ -n "${CAPBOX_CGROUP_ROOT:-}" ]]; then
      i18n_err res.capbox_cgroup_root_cannot_honor_cgroup_limits path="${CAPBOX_CGROUP_ROOT}" detail="$(i18n_or "${CAPBOX_CGROUP_DETAIL:-}" val.unavailable)"
      if [[ "$(_resources_mode)" == "require" ]]; then
        # 仍尝试 DISK，再统一 fail-closed
        :
      fi
    elif [[ -n "${CAPBOX_MEMORY_MAX:-}" ]]; then
      local bytes
      if [[ "$(_resources_mode)" == "require" ]]; then
        i18n_err res.memory_max_require_mode_refuses_prlimit_fallback value="$CAPBOX_MEMORY_MAX"
      elif bytes="$(_resources_parse_bytes "$CAPBOX_MEMORY_MAX")" && have_cmd prlimit; then
        i18n_warn res.memory_max_fell_back_prlimit_rlimit_virtual value="$CAPBOX_MEMORY_MAX" bytes="${bytes}"
        local -a inner2=("${_rw_cmd[@]}")
        _rw_cmd=(prlimit "--as=$bytes" -- "${inner2[@]}")
        CAPBOX_RESOURCES_APPLIED_MEMORY="prlimit-as:$bytes"
      else
        i18n_warn res.memory_max_not_applied_no_cgroup_no value="$CAPBOX_MEMORY_MAX"
      fi
    fi
  fi

  if [[ -n "${CAPBOX_DISK_MAX:-}" ]]; then
    if ! _resources_apply_disk_wrap _rw_cmd; then
      _resources_probe_disk || true
      i18n_warn res.disk_max_not_applied value="$CAPBOX_DISK_MAX" detail="${CAPBOX_DISK_DETAIL:-setup failed}"
    fi
  fi

  if [[ "$(_resources_mode)" == "require" ]]; then
    _resources_fail_closed_check || return 1
  fi

  if (( cgroup_ok == 1 )) || [[ "${CAPBOX_RESOURCES_APPLIED_DISK:-}" == loop:* ]]; then
    if declare -F audit_event >/dev/null 2>&1; then
      audit_event resources ok "detail=limits_prepared cgroup:${CAPBOX_RESOURCES_CGROUP_LEAF:-} mem=${CAPBOX_RESOURCES_APPLIED_MEMORY:-} cpu=${CAPBOX_RESOURCES_APPLIED_CPU:-} pids=${CAPBOX_RESOURCES_APPLIED_PIDS:-} disk=${CAPBOX_RESOURCES_APPLIED_DISK:-}" "exit=0" "ms=0"
    fi
  fi
  return 0
}

_resources_metrics_json() {
  _resources_probe_cgroup || true
  _resources_probe_disk || true
  printf '{'
  printf '"cgroup_status":"%s",' "${CAPBOX_CGROUP_STATUS:-unknown}"
  printf '"cgroup_detail":"%s",' "${CAPBOX_CGROUP_DETAIL//\"/\\\"}"
  printf '"disk_status":"%s",' "${CAPBOX_DISK_STATUS:-unset}"
  printf '"disk_detail":"%s",' "${CAPBOX_DISK_DETAIL//\"/\\\"}"
  printf '"memory_applied":"%s",' "${CAPBOX_RESOURCES_APPLIED_MEMORY:-}"
  printf '"cpu_applied":"%s",' "${CAPBOX_RESOURCES_APPLIED_CPU:-}"
  printf '"pids_applied":"%s",' "${CAPBOX_RESOURCES_APPLIED_PIDS:-}"
  printf '"disk_applied":"%s",' "${CAPBOX_RESOURCES_APPLIED_DISK:-}"
  printf '"mode":"%s"' "$(_resources_mode)"
  printf '}\n'
}

_resources_doctor_report() {
  _resources_probe_cgroup || true
  case "${CAPBOX_CGROUP_STATUS}" in
    ready) _doctor_pass_i18n doctor.cgroup_v2_writable detail="${CAPBOX_CGROUP_DETAIL}" ;;
    denied) _doctor_warn_i18n doctor.cgroup_v2_no_delegate detail="${CAPBOX_CGROUP_DETAIL}" ;;
    *) _doctor_warn_i18n doctor.cgroup_unavailable detail="$(i18n_or "${CAPBOX_CGROUP_DETAIL:-}" val.unknown)" ;;
  esac
  if [[ -n "${CAPBOX_DISK_MAX:-}" ]]; then
    _resources_probe_disk || true
    if [[ "${CAPBOX_DISK_STATUS}" == "capable" ]]; then
      _doctor_pass_i18n doctor.disk_max_honored detail="${CAPBOX_DISK_DETAIL}"
    else
      _doctor_warn_i18n doctor.disk_max_not_honored detail="${CAPBOX_DISK_DETAIL}"
    fi
  fi
  if ! _resources_any_configured; then
    _doctor_pass_i18n doctor.resources_unset
    return 0
  fi
  _doctor_pass_i18n doctor.resources_mode mode="$(_resources_mode)"
  [[ -n "${CAPBOX_MEMORY_MAX:-}" ]] && _doctor_pass_i18n doctor.memory_max_set value="$CAPBOX_MEMORY_MAX"
  [[ -n "${CAPBOX_CPU_MAX:-}" ]] && _doctor_pass_i18n doctor.cpu_max_set value="$CAPBOX_CPU_MAX"
  [[ -n "${CAPBOX_PIDS_MAX:-}" ]] && _doctor_pass_i18n doctor.pids_max_set value="$CAPBOX_PIDS_MAX"
  if [[ -n "${CAPBOX_DISK_MAX:-}" ]]; then
    local gp=""
    if gp="$(_resources_disk_guest_path)"; then
      _doctor_pass_i18n doctor.disk_max_set value="$CAPBOX_DISK_MAX" guest="$gp"
    else
      _doctor_warn_i18n doctor.disk_guest_path_invalid
    fi
  fi
}
