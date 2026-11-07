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
    CAPBOX_CGROUP_DETAIL="无 /sys/fs/cgroup"
    return 1
  fi
  if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
    CAPBOX_CGROUP_DETAIL="非 cgroup v2 统一层级（缺 cgroup.controllers）"
    return 1
  fi

  local find_out=""
  if find_out="$(_resources_find_cgroup_root)"; then
    CAPBOX_CGROUP_ACTIVE="$find_out"
    CAPBOX_CGROUP_STATUS=ready
    if [[ -n "${CAPBOX_CGROUP_ROOT:-}" ]]; then
      CAPBOX_CGROUP_DETAIL="CAPBOX_CGROUP_ROOT=$find_out（控制器可用）"
    else
      CAPBOX_CGROUP_DETAIL="可写 cgroup 根: $find_out（控制器可用）"
    fi
    return 0
  fi
  CAPBOX_CGROUP_FIND_WHY="$find_out"

  if [[ -n "${CAPBOX_CGROUP_ROOT:-}" ]]; then
    CAPBOX_CGROUP_STATUS=denied
    CAPBOX_CGROUP_DETAIL="CAPBOX_CGROUP_ROOT=${CAPBOX_CGROUP_ROOT} 不可用：${find_out:-不可写或子 cgroup 缺少 cpu/memory/pids 控制器}"
    return 1
  fi

  local self cgpath err
  self="$(awk -F: '{print $NF; exit}' /proc/self/cgroup 2>/dev/null || true)"
  cgpath="/sys/fs/cgroup${self}"
  err="$(mkdir -p "${cgpath}/.capbox-probe-$$" 2>&1 || true)"
  rmdir "${cgpath}/.capbox-probe-$$" 2>/dev/null || true
  CAPBOX_CGROUP_STATUS=denied
  CAPBOX_CGROUP_DETAIL="无法获得可用 cgroup 父目录（self=${self:-/}）；${find_out:-mkdir 证据: ${err:-permission denied}}。控制器有 $(tr ' ' ',' </sys/fs/cgroup/cgroup.controllers 2>/dev/null || echo '?') 但当前路径无有效委派。可设置 CAPBOX_CGROUP_ROOT 指向已启用 cpu/memory/pids 的空父 cgroup。"
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

# 判定 root 是否可建子 cgroup，且子目录能出现所需控制器接口。
# 失败时由 _resources_find_cgroup_root 在 stdout 打印原因（兼容 $()）；亦写入 CAPBOX_CGROUP_FIND_WHY。
_resources_cgroup_root_usable() {
  local root="$1"
  local probe err=""
  if [[ ! -d "$root" ]]; then
    CAPBOX_CGROUP_FIND_WHY="不是目录"
    return 1
  fi
  probe="$root/.capbox-ctrl-probe-$$-$RANDOM"
  if ! mkdir -p "$probe" 2>/dev/null; then
    err="$(mkdir -p "$probe" 2>&1 || true)"
    CAPBOX_CGROUP_FIND_WHY="无法 mkdir 子目录: ${err:-permission denied}"
    return 1
  fi
  _resources_cgroup_try_enable "$root"
  if [[ ! -e "$probe/memory.max" && ! -e "$probe/cpu.max" && ! -e "$probe/pids.max" ]]; then
    rmdir "$probe" 2>/dev/null || true
    CAPBOX_CGROUP_FIND_WHY="子 cgroup 无 memory.max/cpu.max/pids.max（常见：父 cgroup 内仍有进程，subtree_control 写入 EBUSY）"
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
    printf '%s' "${CAPBOX_CGROUP_FIND_WHY:-不可用}"
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
  printf '%s' "${last_why:-无可用 cgroup 父目录}"
  return 1
}

_resources_setup_cgroup() {
  local root leaf find_out=""
  if ! find_out="$(_resources_find_cgroup_root)"; then
    if [[ -n "${CAPBOX_CGROUP_ROOT:-}" ]]; then
      log_warn "CAPBOX_CGROUP_ROOT=${CAPBOX_CGROUP_ROOT} 不可用：${find_out:-unknown}"
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
        log_warn "MEMORY_MAX=$CAPBOX_MEMORY_MAX 无法写入 cgroup memory.max（未应用；leaf 无控制器或不允许写）"
      fi
    else
      log_warn "MEMORY_MAX 无法解析: $CAPBOX_MEMORY_MAX"
    fi
  fi
  if [[ -n "${CAPBOX_PIDS_MAX:-}" ]]; then
    if [[ "$CAPBOX_PIDS_MAX" =~ ^[0-9]+$ ]]; then
      if [[ -e "$leaf/pids.max" && -w "$leaf/pids.max" ]] && echo "$CAPBOX_PIDS_MAX" >"$leaf/pids.max" 2>/dev/null; then
        applied=1
        CAPBOX_RESOURCES_APPLIED_PIDS="cgroup:$CAPBOX_PIDS_MAX"
      else
        log_warn "PIDS_MAX=$CAPBOX_PIDS_MAX 无法写入 cgroup pids.max（未应用；不会用 RLIMIT_NPROC 冒充）"
      fi
    else
      log_warn "PIDS_MAX 必须是正整数（当前: $CAPBOX_PIDS_MAX）"
    fi
  fi
  if [[ -n "${CAPBOX_CPU_MAX:-}" ]]; then
    local cpuv
    if cpuv="$(_resources_parse_cpu_max "$CAPBOX_CPU_MAX")"; then
      if [[ -e "$leaf/cpu.max" && -w "$leaf/cpu.max" ]] && echo "$cpuv" >"$leaf/cpu.max" 2>/dev/null; then
        applied=1
        CAPBOX_RESOURCES_APPLIED_CPU="cgroup:$cpuv"
      else
        log_warn "CPU_MAX=$CAPBOX_CPU_MAX 无法写入 cgroup cpu.max（未应用）"
      fi
    else
      log_warn "CPU_MAX 无法解析: $CAPBOX_CPU_MAX（支持 50% 或 'quota period'）"
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
    CAPBOX_DISK_DETAIL="未配置 CAPBOX_DISK_MAX"
    return 1
  fi
  local guest=""
  if ! guest="$(_resources_disk_guest_path)"; then
    CAPBOX_DISK_DETAIL="CAPBOX_DISK_GUEST_PATH 非法（必须是绝对路径，且不能含 .. 或 /.）"
    return 1
  fi
  if ! PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}" command -v losetup >/dev/null 2>&1 || ! PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}" command -v mkfs.ext4 >/dev/null 2>&1 || ! command -v mount >/dev/null 2>&1; then
    CAPBOX_DISK_DETAIL="缺少 losetup/mkfs.ext4/mount（需 e2fsprogs + util-linux）"
    return 1
  fi
  if [[ ! -e /dev/loop-control ]]; then
    CAPBOX_DISK_DETAIL="无 /dev/loop-control"
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
      CAPBOX_DISK_DETAIL="priv=direct；loop→${guest}（需 mount 权限，非 rootless）"
      return 0
      ;;
    sudo)
      CAPBOX_DISK_STATUS=capable
      CAPBOX_DISK_DETAIL="priv=sudo -n；loop→${guest}（需宿主授权，非 rootless）"
      return 0
      ;;
    *)
      local lsout
      lsout="$(ls -l /dev/loop-control 2>&1 || true)"
      CAPBOX_DISK_DETAIL="无 loop/mount 特权: $lsout；需要 root/disk 组或 sudo -n（拒绝假装已限额）"
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
    log_err "DISK_MAX 清理失败，保留 ${base}（未对仍挂载的目录做无特权 rm）"
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
    log_warn "DISK_MAX 无法解析: ${CAPBOX_DISK_MAX:-}"
    return 1
  }
  guest="$(_resources_disk_guest_path)" || {
    CAPBOX_DISK_DETAIL="CAPBOX_DISK_GUEST_PATH 非法（必须是绝对路径，且不能含 .. 或 /.）"
    return 1
  }
  _resources_probe_disk || return 1
  mode="${CAPBOX_DISK_PRIV_MODE:-none}"
  [[ "$mode" != "none" ]] || return 1
  [[ -d "${CAPBOX_ROOTFS:-}" && ! -L "${CAPBOX_ROOTFS}" ]] || return 1

  diskroot="${CAPBOX_STATE_DIR:?}/disk"
  mkdir -p -- "$diskroot" || return 1
  if [[ -L "$diskroot" || -L "${CAPBOX_STATE_DIR}" ]]; then
    CAPBOX_DISK_DETAIL="state/disk 是符号链接，拒绝建立配额盘"
    return 1
  fi
  base="$(mktemp -d "$diskroot/d.XXXXXX")" || return 1
  if [[ -L "$base" || ! -d "$base" ]]; then
    CAPBOX_DISK_DETAIL="配额目录不是真实目录"
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
    _resources_disk_fail_cleanup "$mode" "$ops" "$base" "建立 loop 配额盘失败（priv=$mode）"
    return 1
  fi

  local -a inner=("${_dw_cmd[@]}")
  if ! _resources_disk_bind_into inner "$base/mnt" "$guest"; then
    _resources_disk_fail_cleanup "$mode" "$ops" "$base" "argv 中没有 --，无法把配额盘挂进 guest"
    return 1
  fi

  # 命令结束后用同一份脚本卸载。sudo 失败不回落到无特权 rm。
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
         printf "capbox: DISK_MAX 卸载失败，保留 %s\n" "$base" >&2
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
  log_debug "DISK_MAX 已应用: $bytes -> guest:$guest via state loop (priv=$mode)"
  return 0
}

_resources_fail_closed_check() {
  [[ "$(_resources_mode)" == "require" ]] || return 0
  local missing=()
  if [[ -n "${CAPBOX_MEMORY_MAX:-}" && "${CAPBOX_RESOURCES_APPLIED_MEMORY:-}" != cgroup:* ]]; then
    missing+=("MEMORY_MAX(need cgroup memory.max, not prlimit)")
  fi
  if [[ -n "${CAPBOX_PIDS_MAX:-}" && "${CAPBOX_RESOURCES_APPLIED_PIDS:-}" != cgroup:* ]]; then
    missing+=("PIDS_MAX(need cgroup pids.max)")
  fi
  if [[ -n "${CAPBOX_CPU_MAX:-}" && "${CAPBOX_RESOURCES_APPLIED_CPU:-}" != cgroup:* ]]; then
    missing+=("CPU_MAX(need cgroup cpu.max)")
  fi
  if [[ -n "${CAPBOX_DISK_MAX:-}" && "${CAPBOX_RESOURCES_APPLIED_DISK:-}" != loop:* ]]; then
    _resources_probe_disk || true
    missing+=("DISK_MAX(${CAPBOX_DISK_DETAIL:-not applied as private loop})")
  fi
  if (( ${#missing[@]} > 0 )); then
    log_err "CAPBOX_RESOURCES_MODE=require：以下限额无法精确兑现: ${missing[*]}"
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
    local cg="${CAPBOX_RESOURCES_CGROUP_LEAF:?cgroup leaf missing after setup}"
    local -a inner=("${_rw_cmd[@]}")
    _rw_cmd=(
      /bin/bash -c
      'if ! echo $$ >"$1/cgroup.procs"; then printf "cgroup.procs write failed\n" >&2; exit 1; fi; shift; exec "$@"'
      bash
      "$cg"
      "${inner[@]}"
    )
    log_debug "资源限额经 cgroup 应用: $cg (mem=${CAPBOX_RESOURCES_APPLIED_MEMORY:-} cpu=${CAPBOX_RESOURCES_APPLIED_CPU:-} pids=${CAPBOX_RESOURCES_APPLIED_PIDS:-})"
  else
    _resources_probe_cgroup || true

    if [[ -n "${CAPBOX_CPU_MAX:-}" ]]; then
      log_warn "CPU_MAX=$CAPBOX_CPU_MAX 未应用：${CAPBOX_CGROUP_DETAIL:-无 cgroup 委派}"
    fi
    if [[ -n "${CAPBOX_PIDS_MAX:-}" ]]; then
      log_warn "PIDS_MAX=$CAPBOX_PIDS_MAX 未应用：需要 cgroup pids（拒绝使用 RLIMIT_NPROC）"
    fi

    if [[ -n "${CAPBOX_CGROUP_ROOT:-}" ]]; then
      log_err "CAPBOX_CGROUP_ROOT=${CAPBOX_CGROUP_ROOT} 无法兑现 cgroup 限额：${CAPBOX_CGROUP_DETAIL:-不可用}"
      if [[ "$(_resources_mode)" == "require" ]]; then
        # 仍尝试 DISK，再统一 fail-closed
        :
      fi
    elif [[ -n "${CAPBOX_MEMORY_MAX:-}" ]]; then
      local bytes
      if [[ "$(_resources_mode)" == "require" ]]; then
        log_err "MEMORY_MAX=$CAPBOX_MEMORY_MAX：require 模式拒绝 prlimit 降级（不是 cgroup memory.max）"
      elif bytes="$(_resources_parse_bytes "$CAPBOX_MEMORY_MAX")" && have_cmd prlimit; then
        log_warn "MEMORY_MAX=$CAPBOX_MEMORY_MAX 降级为 prlimit RLIMIT_AS=${bytes}（虚拟地址空间近似，**不是** cgroup memory.max）"
        local -a inner2=("${_rw_cmd[@]}")
        _rw_cmd=(prlimit "--as=$bytes" -- "${inner2[@]}")
        CAPBOX_RESOURCES_APPLIED_MEMORY="prlimit-as:$bytes"
      else
        log_warn "MEMORY_MAX=$CAPBOX_MEMORY_MAX 未应用：无 cgroup 且无 prlimit/无法解析"
      fi
    fi
  fi

  if [[ -n "${CAPBOX_DISK_MAX:-}" ]]; then
    if ! _resources_apply_disk_wrap _rw_cmd; then
      _resources_probe_disk || true
      log_warn "DISK_MAX=$CAPBOX_DISK_MAX 未应用：${CAPBOX_DISK_DETAIL:-setup failed}"
    fi
  fi

  if [[ "$(_resources_mode)" == "require" ]]; then
    _resources_fail_closed_check || return 1
  fi

  if (( cgroup_ok == 1 )) || [[ "${CAPBOX_RESOURCES_APPLIED_DISK:-}" == loop:* ]]; then
    if declare -F audit_event >/dev/null 2>&1; then
      audit_event resources ok "detail=cgroup:${CAPBOX_RESOURCES_CGROUP_LEAF:-} mem=${CAPBOX_RESOURCES_APPLIED_MEMORY:-} cpu=${CAPBOX_RESOURCES_APPLIED_CPU:-} pids=${CAPBOX_RESOURCES_APPLIED_PIDS:-} disk=${CAPBOX_RESOURCES_APPLIED_DISK:-}"
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
    ready) _doctor_pass "cgroup v2 可写（${CAPBOX_CGROUP_DETAIL}）" ;;
    denied) _doctor_warn "cgroup v2 存在但不可委派：${CAPBOX_CGROUP_DETAIL}" ;;
    *) _doctor_warn "cgroup 不可用：${CAPBOX_CGROUP_DETAIL:-unknown}" ;;
  esac
  if [[ -n "${CAPBOX_DISK_MAX:-}" ]]; then
    _resources_probe_disk || true
    if [[ "${CAPBOX_DISK_STATUS}" == "capable" ]]; then
      _doctor_pass "DISK_MAX 可兑现：${CAPBOX_DISK_DETAIL}"
    else
      _doctor_warn "DISK_MAX 无法兑现：${CAPBOX_DISK_DETAIL}"
    fi
  fi
  if ! _resources_any_configured; then
    _doctor_pass "资源限额未配置（MEMORY/CPU/PIDS/DISK 为空）"
    return 0
  fi
  _doctor_pass "RESOURCES_MODE=$(_resources_mode)"
  [[ -n "${CAPBOX_MEMORY_MAX:-}" ]] && _doctor_pass "已配置 MEMORY_MAX=$CAPBOX_MEMORY_MAX"
  [[ -n "${CAPBOX_CPU_MAX:-}" ]] && _doctor_pass "已配置 CPU_MAX=$CAPBOX_CPU_MAX"
  [[ -n "${CAPBOX_PIDS_MAX:-}" ]] && _doctor_pass "已配置 PIDS_MAX=$CAPBOX_PIDS_MAX"
  if [[ -n "${CAPBOX_DISK_MAX:-}" ]]; then
    local gp=""
    if gp="$(_resources_disk_guest_path)"; then
      _doctor_pass "已配置 DISK_MAX=$CAPBOX_DISK_MAX（guest $gp）"
    else
      _doctor_warn "DISK_MAX 的 guest 路径非法"
    fi
  fi
}
