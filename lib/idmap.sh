# shellcheck shell=bash
# =============================================================================
# CapBox - idmap.sh
# 多 UID/GID 映射（newuidmap/newgidmap + bwrap --userns-block-fd）
#
# 配置：
#   CAPBOX_IDMAP=auto|on|off
#     auto —— 探测到 newuidmap + /etc/subuid 可用则启用多映射，否则单 UID
#     on   —— 强制多映射；不可用则启动失败（绝不静默退化）
#     off  —— 强制单 UID（历史行为：仅 0→宿主 uid）
#   CAPBOX_UID_MAP / CAPBOX_GID_MAP
#     空或 auto —— 按 subuid/subgid 自动生成
#     显式      —— guest:host:count[,guest:host:count...]
#   CAPBOX_SETGROUPS=allow|deny  （多映射默认 allow；单映射固定 deny）
#   CAPBOX_EXEC_UID / CAPBOX_EXEC_GID —— 容器内初始身份（默认 0/0）
#
# 宿主权限边界（诚实）：
#   无 setuid/newuidmap 时，内核只允许把「自身一个 uid」写入子 userns 的
#   uid_map。此时 chown/setgroups/setuid 到其它身份必然失败。本模块会探测
#   并报告；CAPBOX_IDMAP=on 时直接拒绝启动，而不是伪称多用户可用。
# =============================================================================

: "${CAPBOX_IDMAP:=auto}"
: "${CAPBOX_UID_MAP:=}"
: "${CAPBOX_GID_MAP:=}"
: "${CAPBOX_SETGROUPS:=}"
: "${CAPBOX_EXEC_UID:=0}"
: "${CAPBOX_EXEC_GID:=0}"

# 最近一次探测摘要（doctor / status 可读）
CAPBOX_IDMAP_STATUS="${CAPBOX_IDMAP_STATUS:-unknown}"
CAPBOX_IDMAP_DETAIL="${CAPBOX_IDMAP_DETAIL:-}"

_idmap_host_uid() { id -u 2>/dev/null || printf '0'; }
_idmap_host_gid() { id -g 2>/dev/null || printf '0'; }
_idmap_host_user() { id -un 2>/dev/null || printf 'unknown'; }

# 读 /etc/subuid 或 /etc/subgid：打印 "start count"；失败返回 1
_idmap_read_subid() {
  local kind="${1:-uid}" # uid|gid
  local user f line start count
  user="$(_idmap_host_user)"
  if [[ "$kind" == "gid" ]]; then
    f=/etc/subgid
  else
    f=/etc/subuid
  fi
  [[ -r "$f" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$user:"* ]] || continue
    start="${line#*:}"
    count="${start#*:}"
    start="${start%%:*}"
    [[ "$start" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || continue
    printf '%s %s' "$start" "$count"
    return 0
  done <"$f"
  return 1
}

# 解析 "g:h:c,g:h:c" → 通过 nameref 填入平行数组 guests hosts counts
_idmap_parse_spec() {
  local spec="${1:-}"
  local -n _g="$2" _h="$3" _c="$4"
  _g=(); _h=(); _c=()
  [[ -n "$spec" && "$spec" != "auto" ]] || return 1
  local IFS=',' part g h c
  for part in $spec; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ -n "$part" ]] || continue
    IFS=':' read -r g h c <<<"$part"
    [[ "$g" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$c" -gt 0 ]] || {
      log_err "UID/GID 映射段非法: '$part'（需要 guest:host:count）"
      return 2
    }
    _g+=("$g"); _h+=("$h"); _c+=("$c")
  done
  ((${#_g[@]} > 0)) || return 1
  return 0
}

# 自动映射：guest0→hostuid:1 + guest1→subuid_start:subuid_count
_idmap_auto_spec() {
  local kind="${1:-uid}"
  local host_id sub start count
  if [[ "$kind" == "gid" ]]; then
    host_id="$(_idmap_host_gid)"
  else
    host_id="$(_idmap_host_uid)"
  fi
  sub="$(_idmap_read_subid "$kind")" || return 1
  start="${sub%% *}"
  count="${sub#* }"
  # 至少留出常用系统账号空间（www-data=33, nobody=65534 等）
  if (( count < 100 )); then
    return 1
  fi
  printf '0:%s:1,1:%s:%s' "$host_id" "$start" "$count"
}

# 是否具备多映射工具链
_idmap_have_helpers() {
  have_cmd newuidmap && have_cmd newgidmap
}

# 实际探测：尝试短暂创建 userns 并写入多行映射。成功返回 0。
# 结果写入 CAPBOX_IDMAP_STATUS / CAPBOX_IDMAP_DETAIL。
_idmap_probe() {
  local mode="${CAPBOX_IDMAP:-auto}"
  case "$mode" in
    off)
      CAPBOX_IDMAP_STATUS="single"
      CAPBOX_IDMAP_DETAIL="CAPBOX_IDMAP=off（强制单 UID）"
      return 1
      ;;
  esac

  if ! _idmap_have_helpers; then
    CAPBOX_IDMAP_STATUS="blocked"
    CAPBOX_IDMAP_DETAIL="缺少 newuidmap/newgidmap（安装 uidmap 包）；内核仅允许单 UID 自映射"
    [[ "$mode" == "on" ]] && return 2
    return 1
  fi

  local uid_spec gid_spec
  if [[ -n "${CAPBOX_UID_MAP:-}" && "${CAPBOX_UID_MAP}" != "auto" ]]; then
    uid_spec="$CAPBOX_UID_MAP"
  else
    uid_spec="$(_idmap_auto_spec uid)" || {
      CAPBOX_IDMAP_STATUS="blocked"
      CAPBOX_IDMAP_DETAIL="用户 $(_idmap_host_user) 在 /etc/subuid 无可用条目"
      [[ "$mode" == "on" ]] && return 2
      return 1
    }
  fi
  if [[ -n "${CAPBOX_GID_MAP:-}" && "${CAPBOX_GID_MAP}" != "auto" ]]; then
    gid_spec="$CAPBOX_GID_MAP"
  else
    gid_spec="$(_idmap_auto_spec gid)" || gid_spec="$uid_spec"
  fi

  local -a ug uh uc gg gh gc
  _idmap_parse_spec "$uid_spec" ug uh uc || {
    CAPBOX_IDMAP_STATUS="blocked"
    CAPBOX_IDMAP_DETAIL="CAPBOX_UID_MAP 无法解析: $uid_spec"
    return 2
  }
  _idmap_parse_spec "$gid_spec" gg gh gc || {
    CAPBOX_IDMAP_STATUS="blocked"
    CAPBOX_IDMAP_DETAIL="CAPBOX_GID_MAP 无法解析: $gid_spec"
    return 2
  }

  # 实探：fork + unshare + newuidmap
  # 使用私有 mktemp 目录承载 chown 探测文件，避免 sticky /tmp 固定名留下
  # 无法删除的 subuid 属主文件（也不依赖 sudo 清理）。
  local ok=0 detail="" probe_dir="" probe_file=""
  local private
  private="$(_capbox_host_state_dir)" || return 1
  probe_dir="$(mktemp -d "$private/capbox-idmap.XXXXXX")" || {
    CAPBOX_IDMAP_STATUS="blocked"
    CAPBOX_IDMAP_DETAIL="无法创建 idmap 探测临时目录"
    [[ "$mode" == "on" ]] && return 2
    return 1
  }
  probe_file="$probe_dir/probe"
  : >"$probe_file" || {
    rmdir "$probe_dir" 2>/dev/null || true
    CAPBOX_IDMAP_STATUS="blocked"
    CAPBOX_IDMAP_DETAIL="无法创建 idmap 探测文件"
    [[ "$mode" == "on" ]] && return 2
    return 1
  }
  detail="$(
    python3 - "$uid_spec" "$gid_spec" "$probe_file" <<'PY' 2>&1
import ctypes, os, subprocess, sys
uid_spec, gid_spec, probe_path = sys.argv[1], sys.argv[2], sys.argv[3]

def parse(spec):
    out=[]
    for part in spec.split(','):
        part=part.strip()
        if not part: continue
        g,h,c = part.split(':')
        out += [g,h,c]
    return out

CLONE_NEWUSER=0x10000000
pr, pw = os.pipe(); gr, gw = os.pipe()
pid=os.fork()
if pid==0:
    os.close(pr); os.close(gw)
    # 较新的 Python 才有 os.unshare；这里走 libc，对齐 Linux ABI。
    libc = ctypes.CDLL(None, use_errno=True)
    libc.unshare.argtypes = [ctypes.c_int]
    libc.unshare.restype = ctypes.c_int
    if libc.unshare(CLONE_NEWUSER) != 0:
        err = ctypes.get_errno()
        print('FAIL user namespace:', os.strerror(err), flush=True)
        os._exit(1)
    os.write(pw, b'R'); os.close(pw)
    if os.read(gr, 1) != b'x':
        os._exit(1)
    # 在宿主提供的私有路径上验证 chown + setgroups + setuid
    try:
        with open(probe_path, 'w') as f:
            f.write('x')
        os.chown(probe_path, 33, 33)
        os.setgroups([0,33])
        c=os.fork()
        if c==0:
            os.setgid(33); os.setuid(33)
            os._exit(0 if os.getuid()==33 else 1)
        _, st = os.waitpid(c,0)
        rc = os.WEXITSTATUS(st) if os.WIFEXITED(st) else 1
        um=open('/proc/self/uid_map').read().strip().replace('\n','|')
        print('OK', um, 'rc', rc, flush=True)
        os._exit(0 if rc==0 else 1)
    except Exception as e:
        print('FAIL', type(e).__name__, e, flush=True)
        os._exit(1)

os.close(pw); os.close(gr)
if os.read(pr,1) != b'R':
    os.waitpid(pid, 0)
    sys.exit('FAIL user namespace child exited before mapping handshake')
ua=['newuidmap', str(pid)] + parse(uid_spec)
ga=['newgidmap', str(pid)] + parse(gid_spec)
try:
    subprocess.check_call(ua)
    open(f'/proc/{pid}/setgroups','w').write('allow\n')
    subprocess.check_call(ga)
except (OSError, subprocess.CalledProcessError) as exc:
    print('FAIL user namespace mapping:', exc, flush=True)
    os.close(gw)
    os.waitpid(pid, 0)
    sys.exit(1)
os.write(gw,b'x'); os.close(gw)
_, st = os.waitpid(pid,0)
sys.exit(0 if os.WIFEXITED(st) and os.WEXITSTATUS(st)==0 else 1)
PY
  )" && ok=1 || ok=0

  # 私有目录无 sticky bit：即使 probe 已被 chown 到 subuid，目录属主仍可 unlink
  rm -f "$probe_file" 2>/dev/null || true
  rmdir "$probe_dir" 2>/dev/null || true

  if (( ok == 1 )); then
    CAPBOX_IDMAP_STATUS="multi"
    CAPBOX_IDMAP_DETAIL="uid_map=$uid_spec; gid_map=$gid_spec; setgroups=allow; probe=$detail"
    # 缓存解析结果供本次进程使用
    CAPBOX_IDMAP_UID_SPEC="$uid_spec"
    CAPBOX_IDMAP_GID_SPEC="$gid_spec"
    export CAPBOX_IDMAP_UID_SPEC CAPBOX_IDMAP_GID_SPEC
    return 0
  fi

  CAPBOX_IDMAP_STATUS="blocked"
  CAPBOX_IDMAP_DETAIL="newuidmap 存在但写入多行映射失败：${detail:-unknown}"
  [[ "$mode" == "on" ]] && return 2
  return 1
}

# 当前是否应启用多映射（带缓存）
_idmap_enabled() {
  case "${CAPBOX_IDMAP_STATUS}" in
    multi) return 0 ;;
    single|blocked)
      [[ "${CAPBOX_IDMAP:-auto}" == "on" ]] && return 2
      return 1
      ;;
  esac
  _idmap_probe
  local rc=$?
  return "$rc"
}

# 解析初始 --uid/--gid（允许被 CAPBOX_EXEC_UID_OVERRIDE 覆盖）
_idmap_exec_id() {
  local v="${1:-}" n
  [[ "$v" =~ ^[0-9]+$ ]] || return 2
  n="$v"
  while [[ "$n" == 0* && ${#n} -gt 1 ]]; do
    n="${n#0}"
  done
  # 按十进制位数比较，避免 bash 算术把超长数字当成 0 或溢出后放行。
  if (( ${#n} > 10 )) || (( 10#$n > 4294967295 )); then
    return 2
  fi
  printf '%s' "$n"
}
_idmap_exec_uid() {
  _idmap_exec_id "${CAPBOX_EXEC_UID_OVERRIDE:-${CAPBOX_EXEC_UID:-0}}"
}
_idmap_exec_gid() {
  _idmap_exec_id "${CAPBOX_EXEC_GID_OVERRIDE:-${CAPBOX_EXEC_GID:-0}}"
}

# 从 guest /etc/passwd 解析用户名 → uid:gid（rootfs 内）
_idmap_resolve_user() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1
  if [[ "$name" =~ ^[0-9]+$ ]]; then
    printf '%s' "$name"
    return 0
  fi
  local f="${CAPBOX_ROOTFS:-}/etc/passwd" line un uid gid
  [[ -r "$f" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$name:"* ]] || continue
    IFS=':' read -r un _ uid gid _ <<<"$line"
    [[ "$uid" =~ ^[0-9]+$ ]] || return 1
    printf '%s:%s' "$uid" "${gid:-$uid}"
    return 0
  done <"$f"
  return 1
}

# 把映射应用到已阻塞的 child pid
_idmap_apply_to_pid() {
  local pid="${1:-}"
  [[ -n "$pid" && -d "/proc/$pid" ]] || return 1
  local uid_spec gid_spec sg
  uid_spec="${CAPBOX_IDMAP_UID_SPEC:-}"
  gid_spec="${CAPBOX_IDMAP_GID_SPEC:-}"
  if [[ -z "$uid_spec" ]]; then
    _idmap_probe || return $?
    uid_spec="${CAPBOX_IDMAP_UID_SPEC:-}"
    gid_spec="${CAPBOX_IDMAP_GID_SPEC:-}"
  fi
  [[ -n "$uid_spec" && -n "$gid_spec" ]] || return 1

  local -a ua=(newuidmap "$pid") ga=(newgidmap "$pid")
  local part g h c
  local IFS=','
  for part in $uid_spec; do
    IFS=':' read -r g h c <<<"$part"
    ua+=("$g" "$h" "$c")
  done
  for part in $gid_spec; do
    IFS=':' read -r g h c <<<"$part"
    ga+=("$g" "$h" "$c")
  done

  sg="${CAPBOX_SETGROUPS:-allow}"
  case "$sg" in allow|deny) ;; *) sg=allow ;; esac

  "${ua[@]}" || {
    log_err "newuidmap 失败（pid=$pid spec=$uid_spec）"
    return 1
  }
  if ! printf '%s\n' "$sg" >"/proc/$pid/setgroups" 2>/dev/null; then
    log_warn "无法写 /proc/$pid/setgroups=$sg（将继续尝试 newgidmap）"
  fi
  "${ga[@]}" || {
    log_err "newgidmap 失败（pid=$pid spec=$gid_spec）"
    return 1
  }
  return 0
}



# 在 argv 中定位「bwrap 之后的那条 --」（跳过 prlimit/bash -c 等外层包装的 --）
# $1 = 调用方数组变量名（字符串），避免 nameref 嵌套环
_idmap_find_bwrap_dd() {
  local __name="$1"
  local -n __fb_av="$__name"
  local i bwrap_i=-1
  for i in "${!__fb_av[@]}"; do
    case "${__fb_av[$i]}" in
      bwrap|*/bwrap) bwrap_i=$i ;;
    esac
  done
  if (( bwrap_i < 0 )); then
    for (( i=${#__fb_av[@]}-1; i>=0; i-- )); do
      [[ "${__fb_av[$i]}" == "--" ]] && { printf '%s' "$i"; return 0; }
    done
    return 1
  fi
  for (( i=bwrap_i+1; i<${#__fb_av[@]}; i++ )); do
    if [[ "${__fb_av[$i]}" == "--" ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

# 把 --info-fd / --userns-block-fd 插到 bwrap 段的 -- 之前
# $1 = 调用方数组变量名（字符串）
_idmap_inject_block_fds() {
  local __name="$1"
  local info_spec="$2" block_fd="$3"
  local -n __inj_av="$__name"
  local dd
  if ! dd="$(_idmap_find_bwrap_dd "$__name")"; then
    __inj_av+=(--info-fd "$info_spec" --userns-block-fd "$block_fd")
    return 0
  fi
  local -a head=("${__inj_av[@]:0:$dd}") tail=("${__inj_av[@]:$dd}")
  local -a filtered=()
  local x
  for x in "${head[@]}"; do
    # bwrap 拒绝 --disable-userns 与 --userns-block-fd 同时出现。
    [[ "$x" == "--disable-userns" ]] && continue
    filtered+=("$x")
  done
  __inj_av=("${filtered[@]}" --info-fd "$info_spec" --userns-block-fd "$block_fd" "${tail[@]}")
}

# 0 = 本次应走多 UID；1 = 不走；2 = CAPBOX_IDMAP=on 但映射不可用（调用方必须失败）
# 不能写 if _idmap_enabled：条件为假时 if 的状态是 0，返回码 2 会丢。
_capbox_idmap_decision() {
  if ! declare -F _idmap_enabled >/dev/null 2>&1; then
    return 1
  fi
  local rc=0
  _idmap_enabled || rc=$?
  if (( rc == 0 )); then
    return 0
  fi
  if (( rc == 2 )) || [[ "${CAPBOX_IDMAP:-auto}" == "on" && "${CAPBOX_IDMAP_STATUS:-}" == "blocked" ]]; then
    log_err "CAPBOX_IDMAP=on 但多 UID 映射不可用：${CAPBOX_IDMAP_DETAIL:-见 doctor}"
    return 2
  fi
  return 1
}


# ---------------------------------------------------------------------------
# 数字 uid/gid 降权助手（宿主构建的静态二进制，供 musl guest 使用）
# ---------------------------------------------------------------------------
# BusyBox setpriv 没有 --reuid；su 需要 passwd 用户名；alpine 常常没有
# python3。优先用宿主 `gcc -static` 从 lib/guest/capbox-drop-priv.c 编出
# 小助手，再以只读 bind 挂到 CapBox rootfs 的 /run/capbox-drop-priv
# （不写 rootfs）。

_idmap_drop_priv_src() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$here/guest/capbox-drop-priv.c" ]]; then
    printf '%s' "$here/guest/capbox-drop-priv.c"
    return 0
  fi
  if [[ -n "${CAPBOX_GUEST_DIR:-}" && -f "${CAPBOX_GUEST_DIR}/capbox-drop-priv.c" ]]; then
    printf '%s' "${CAPBOX_GUEST_DIR}/capbox-drop-priv.c"
    return 0
  fi
  return 1
}

_idmap_drop_priv_host_bin() {
  local private
  private="$(_capbox_host_state_dir)" || return 1
  printf '%s/helpers/capbox-drop-priv' "$private"
}

_idmap_drop_priv_guest_bin() {
  printf '%s' /run/capbox-drop-priv
}

# 在工作区外构建；调用方在挂上 guest /run 后再 bind 该助手。
_idmap_ensure_drop_priv_helper() {
  local src bin guest_abs cc tmp err
  src="$(_idmap_drop_priv_src)" || {
    CAPBOX_IDMAP_DROP_HELPER_DETAIL="缺少 capbox-drop-priv.c"
    return 1
  }
  bin="$(_idmap_drop_priv_host_bin)" || return 1
  mkdir -p "$(dirname "$bin")" 2>/dev/null || true

  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    cc=""
    if have_cmd gcc; then
      cc=gcc
    elif have_cmd cc; then
      cc=cc
    else
      CAPBOX_IDMAP_DROP_HELPER_DETAIL="没有 gcc/cc，无法构建静态助手"
      return 1
    fi
    tmp="$(mktemp "$(dirname "$bin")/build.XXXXXX")" || return 1
    err="$("$cc" -static -O2 -s -o "$tmp" "$src" 2>&1)" || {
      rm -f "$tmp"
      CAPBOX_IDMAP_DROP_HELPER_DETAIL="gcc -static 失败: ${err:-unknown}"
      return 1
    }
    mv -f "$tmp" "$bin"
    chmod 755 "$bin"
  fi

  if [[ -x "$bin" ]]; then
    CAPBOX_IDMAP_DROP_HELPER_DETAIL="静态助手已就绪，可供只读 bind（$bin）"
    return 0
  fi
  CAPBOX_IDMAP_DROP_HELPER_DETAIL="构建后仍缺少助手"
  return 1
}

# bwrap 在 --userns-block-fd 路径下不会可靠应用 --uid/--gid（实测恒为 0）。
# 多映射启用时在 guest 内降权：优先宿主 gcc -static 构建的 capbox-drop-priv
#（数字 uid，无需 passwd）；否则回退 GNU setpriv / python3 / chpst / su。
_idmap_wrap_argv_for_uid() {
  # $1 = 调用方数组变量名
  local __wname="$1"
  local -n _argv="$__wname"
  local uid gid dd=-1
  uid="$(_idmap_exec_uid)" || {
    log_err "EXEC_UID 必须是 0..4294967295 的数字（当前: ${CAPBOX_EXEC_UID_OVERRIDE:-${CAPBOX_EXEC_UID:-}}）"
    return 2
  }
  gid="$(_idmap_exec_gid)" || {
    log_err "EXEC_GID 必须是 0..4294967295 的数字（当前: ${CAPBOX_EXEC_GID_OVERRIDE:-${CAPBOX_EXEC_GID:-}}）"
    return 2
  }
  [[ "$uid" == "0" && "$gid" == "0" ]] && return 0
  dd="$(_idmap_find_bwrap_dd "$__wname" || true)"
  [[ -n "$dd" ]] || dd=-1
  (( dd >= 0 )) || return 0
  local -a rest=("${_argv[@]:$((dd+1))}")
  ((${#rest[@]} > 0)) || return 0
  local -a wrap=()
  local guest_helper host_helper guest_abs

  # 1) 首选：宿主 gcc -static 构建的数字 uid helper（不依赖 guest 包/passwd）
  if _idmap_ensure_drop_priv_helper; then
    guest_helper="$(_idmap_drop_priv_guest_bin)"
    host_helper="$(_idmap_drop_priv_host_bin)"
    if [[ -x "$host_helper" ]]; then
      local -a head=("${_argv[@]:0:$dd}")
      _argv=("${head[@]}" --ro-bind "$host_helper" "$guest_helper" -- "$guest_helper" "$uid" "$gid" "${rest[@]}")
      return 0
    fi
  fi

  # 2) 回退：guest 运行时选择器（GNU setpriv / python3 / chpst / su）
  # shellcheck disable=SC2016
  wrap=(
    /bin/sh -c '
uid=$1
gid=$2
shift 2
is_gnu_setpriv() {
  sp=$1
  [ -n "$sp" ] && [ -x "$sp" ] || return 1
  link=$(readlink -f "$sp" 2>/dev/null || readlink "$sp" 2>/dev/null || printf %s "$sp")
  case "$link" in
    *busybox*) return 1 ;;
  esac
  "$sp" --help 2>&1 | grep -q -- "--reuid"
}
try_gnu_setpriv() {
  sp=$1
  shift
  is_gnu_setpriv "$sp" || return 1
  exec "$sp" --reuid="$uid" --regid="$gid" --clear-groups -- "$@"
}
try_gnu_setpriv /usr/bin/setpriv "$@"
if command -v setpriv >/dev/null 2>&1; then
  try_gnu_setpriv "$(command -v setpriv)" "$@"
fi
if command -v python3 >/dev/null 2>&1; then
  exec python3 -c "import os,sys
uid=int(sys.argv[1]); gid=int(sys.argv[2]); cmd=sys.argv[3:]
os.setgid(gid)
try:
    os.setgroups([gid])
except OSError as exc:
    extra = [g for g in os.getgroups() if g != gid]
    if extra:
        sys.stderr.write(\"setgroups failed (%s); supplementary groups remain\\n\" % exc)
        sys.exit(1)
os.setuid(uid)
os.execvp(cmd[0], cmd)" "$uid" "$gid" "$@"
fi
if command -v chpst >/dev/null 2>&1; then
  exec chpst -u ":${uid}:${gid}" "$@"
fi
if command -v su >/dev/null 2>&1; then
  if su "$uid" -s /bin/sh -c "exec \"\$@\"" -- "$@" 2>/dev/null; then
    exit $?
  fi
  name=$(awk -F: -v u="$uid" '\''($3==u){print $1; exit}'\'' /etc/passwd 2>/dev/null || true)
  if [ -n "$name" ]; then
    exec su "$name" -s /bin/sh -c "exec \"\$@\"" -- "$@"
  fi
fi
printf "capbox: cannot drop privileges to %s:%s (need host gcc -static helper, util-linux setpriv, python3, chpst, or su; BusyBox setpriv --reuid unsupported)\n" "$uid" "$gid" >&2
exit 127
' sh "$uid" "$gid" "${rest[@]}"
  )
  _argv=("${_argv[@]:0:$dd}" -- "${wrap[@]}")
}

_idmap_run_bwrap_argv() {
  [[ $# -gt 0 ]] || return 2
  local -a _run_argv=("$@")
  _idmap_wrap_argv_for_uid _run_argv || return $?
  set -- "${_run_argv[@]}"
  local tmp info_out block_fifo private
  private="$(_capbox_host_state_dir)" || return 1
  tmp="$(mktemp -d "$private/idmap.XXXXXX")" || return 1
  info_out="$tmp/info.json"
  block_fifo="$tmp/block"
  mkfifo "$block_fifo" || return 1
  : >"$info_out"

  # 打开 block fifo 为读写，避免 open 阻塞
  local block_fd
  exec {block_fd}<>"$block_fifo"

  local -a launch=("$@")
  _idmap_inject_block_fds launch 4 "$block_fd"

  local bp helper_rc=0 rc=0
  # 启动 bwrap，info 写到 fd4。
  # bash 在无 job control 时会把后台任务的 stdin 接到 /dev/null；
  # 先复制 fd0，再显式重定向，否则 `capbox shell`/`sh -s` 管道输入会被吞掉（rc=0、无输出）。
  local stdin_fd
  exec {stdin_fd}<&0
  "${launch[@]}" 4>"$info_out" <&"$stdin_fd" &
  bp=$!
  exec {stdin_fd}<&-

  # 等待 info / 应用映射 / 放行
  local child="" i
  for i in $(seq 1 200); do
    if [[ -s "$info_out" ]]; then
      child="$(python3 -c 'import json,sys
try:
  print(json.load(open(sys.argv[1])).get("child-pid",""))
except Exception:
  print("")' "$info_out" 2>/dev/null || true)"
      [[ -n "$child" ]] && break
    fi
    kill -0 "$bp" 2>/dev/null || break
    sleep 0.05
  done

  if [[ -z "$child" ]]; then
    log_err "idmap：未能从 bwrap --info-fd 取得 child-pid"
    kill "$bp" 2>/dev/null || true
    wait "$bp" 2>/dev/null || true
    exec {block_fd}>&-
    rm -rf "$tmp"
    return 1
  fi

  if ! _idmap_apply_to_pid "$child"; then
    kill "$bp" 2>/dev/null || true
    # 仍尝试放行，避免永久卡住
    printf '\n' 1>&"$block_fd" 2>/dev/null || true
    wait "$bp" 2>/dev/null || true
    exec {block_fd}>&-
    rm -rf "$tmp"
    return 1
  fi

  # 先放行。bwrap 在这之后才配置 loopback；钩子里的桥必须等地址出现。
  printf '\n' 1>&"$block_fd" 2>/dev/null || true
  if declare -F _idmap_after_map_hook >/dev/null 2>&1; then
    _idmap_after_map_hook "$child" || helper_rc=$?
    if (( helper_rc != 0 )); then
      kill "$bp" 2>/dev/null || true
      wait "$bp" 2>/dev/null || true
      exec {block_fd}>&-
      rm -rf "$tmp"
      return "$helper_rc"
    fi
  fi

  wait "$bp"
  rc=$?
  exec {block_fd}>&-
  rm -rf "$tmp"
  return "$rc"
}

# 后台启动（daemon up）：打印子进程 host pid 到 stdout，映射在后台完成
_idmap_spawn_bwrap_argv() {
  [[ $# -gt 0 ]] || return 2
  local -a _run_argv=("$@")
  _idmap_wrap_argv_for_uid _run_argv || return $?
  set -- "${_run_argv[@]}"
  local tmp info_out block_fifo logf private
  private="$(_capbox_host_state_dir)" || return 1
  tmp="$(mktemp -d "$private/idmap.XXXXXX")" || return 1
  info_out="$tmp/info.json"
  block_fifo="$tmp/block"
  logf="${CAPBOX_IDMAP_SPAWN_LOG:-$tmp/spawn.log}"
  mkfifo "$block_fifo" || return 1
  : >"$info_out"

  local block_fd
  exec {block_fd}<>"$block_fifo"

  local -a launch=("$@")
  _idmap_inject_block_fds launch 4 "$block_fd"

  "${launch[@]}" 4>"$info_out" >>"$logf" 2>&1 &
  local bp=$!
  printf '%s\n' "$bp"

  # 同步完成映射后再返回（最多 ~10s），避免 daemon 在未映射时跑起来
  local child="" i
  for i in $(seq 1 200); do
    if [[ -s "$info_out" ]]; then
      child="$(python3 -c 'import json,sys
try:
  print(json.load(open(sys.argv[1])).get("child-pid",""))
except Exception:
  print("")' "$info_out" 2>/dev/null || true)"
      [[ -n "$child" ]] && break
    fi
    kill -0 "$bp" 2>/dev/null || break
    sleep 0.05
  done
  if [[ -z "$child" ]] || ! _idmap_apply_to_pid "$child"; then
    log_err "idmap：后台启动映射失败（见 $logf）"
    kill "$bp" 2>/dev/null || true
    printf '\n' 1>&"$block_fd" 2>/dev/null || true
    exec {block_fd}>&-
    rm -rf "$tmp"
    return 1
  fi
  # 先放行再跑钩子，避免桥抢在 bwrap 的 loopback 配置之前改 lo。
  printf '\n' 1>&"$block_fd" 2>/dev/null || true
  if declare -F _idmap_after_map_hook >/dev/null 2>&1; then
    _idmap_after_map_hook "$child" || {
      log_err "idmap：after_map hook 失败"
      kill "$bp" 2>/dev/null || true
      exec {block_fd}>&-
      rm -rf "$tmp"
      return 1
    }
  fi
  # block_fd 与 tmp 交给子进程生命周期；稍后清理 info 目录可能还在用，延迟删
  exec {block_fd}>&-
  # 保留 tmp 到进程结束较难；映射已完成，删 fifo 不影响已打开的 fd
  rm -rf "$tmp" 2>/dev/null || true
  return 0
}

_idmap_doctor_report() {
  local rc=0
  _idmap_probe || rc=$?
  case "${CAPBOX_IDMAP_STATUS}" in
    multi)
      _doctor_pass "UID 映射 multi（${CAPBOX_IDMAP_DETAIL}）"
      if _idmap_ensure_drop_priv_helper; then
        _doctor_pass "drop-priv helper（${CAPBOX_IDMAP_DROP_HELPER_DETAIL}）"
      else
        _doctor_warn "drop-priv helper 不可用（${CAPBOX_IDMAP_DROP_HELPER_DETAIL:-unknown}）；--uid 将依赖 guest setpriv/python/chpst/su"
      fi
      ;;
    single)
      _doctor_warn "UID 映射 single（${CAPBOX_IDMAP_DETAIL}）。chown/setgroups/多用户服务会失败"
      ;;
    blocked)
      if [[ "${CAPBOX_IDMAP:-auto}" == "on" ]]; then
        _doctor_fail "UID 映射被阻塞且 CAPBOX_IDMAP=on（${CAPBOX_IDMAP_DETAIL}）"
      else
        _doctor_warn "UID 映射不可用，已回退 single（${CAPBOX_IDMAP_DETAIL}）"
      fi
      ;;
    *)
      _doctor_warn "UID 映射状态未知"
      ;;
  esac
  return 0
}
