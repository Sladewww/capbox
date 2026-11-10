# shellcheck shell=bash
# =============================================================================
# CapBox —— sandbox.sh（一次性容器执行）
# 一次性容器执行：bwrap 命令构造、exec / shell / cp / ls / ps / pkg。
# 依赖 common.sh（build_bwrap_args 等）。
# =============================================================================

# ---------- 1. 完整 bwrap 命令构造 -------------------------------------------

# sandbox_bwrap_cmd MODE [CMD]：组装完整 bwrap 命令行
#   MODE：oneshot | daemon
#   输出 NUL 分隔的完整 argv（含 $CAPBOX_BWRAP、全部参数）。
#   - CMD 非空：末尾追加 `-- /bin/sh -c CMD`，得到可直接执行的完整命令。
#   - CMD 为空：只输出 bwrap 参数（供 daemon 自行追加自己的服务端命令）。
sandbox_bwrap_cmd() {
  local mode="${1:-oneshot}"
  local cmd="${2-}"
  local cwd="${3:-/workspace}"

  case "$mode" in
    oneshot | daemon) ;;
    *) die 2 "sandbox_bwrap_cmd: 未知模式 $mode（应为 oneshot 或 daemon）" ;;
  esac

  [[ -x "${CAPBOX_BWRAP:-}" ]] || die 5 "bwrap 不可用: ${CAPBOX_BWRAP:-未设置}"
  rootfs_ready || die 4 "rootfs 不存在或不可用: ${CAPBOX_ROOTFS:-未设置}；请先运行 capbox init"

  if [[ -z "${CAPBOX_BWRAP_BASELINE_CMD:-}" ]]; then
    if [[ "$mode" == "daemon" && -z "$cmd" ]]; then
      CAPBOX_BWRAP_BASELINE_CMD="up"
    else
      CAPBOX_BWRAP_BASELINE_CMD="${cmd:-exec}"
    fi
  fi

  local -a args=()
  local _bbrc=0
  mapfile -t args < <(build_bwrap_args "$mode" "$cwd"; printf 'CAPBOX_BWRAP_ARGS_RC=%s\n' "$?")
  if [[ ${#args[@]} -gt 0 && "${args[-1]}" == CAPBOX_BWRAP_ARGS_RC=* ]]; then
    _bbrc="${args[-1]#CAPBOX_BWRAP_ARGS_RC=}"
    unset 'args[-1]'
  fi
  # 6：基线说明已经写在 stderr。返回给 up，避免 die 把说明关进临时文件后直接退出。
  if (( _bbrc == 6 )); then
    return 6
  fi
  if (( _bbrc != 0 )); then
    die "$_bbrc" "无法构造 bwrap 参数（rc=$_bbrc；常见原因：bwrap 版本不足、FS_BINDS 越界、安全档/seccomp 失败）"
  fi
  (( ${#args[@]} > 0 )) || die 4 "无法构造 bwrap 参数（rootfs 缺失）"

  printf '%s\0' "$CAPBOX_BWRAP"
  printf '%s\0' "${args[@]}"
  if [[ -n "$cmd" ]]; then
    printf '%s\0' --
    printf '%s\0' /bin/sh -c "$cmd"
  fi
}

# ---------- 2. 容器内工作目录校验 ---------------------------------------------

# 校验并规范化 --cwd 参数。
# 注意：本函数会被 $( ) 捕获，**不能在里面 die**——子 shell 的 exit 不会
# 终止父进程，只会让调用方拿到空字符串并继续跑。因此只返回错误码。
# 返回：0=成功（stdout 为规范化路径）；2=目录不存在。
_resolve_guest_cwd() {
  local d="${1:-/workspace}"
  [[ -n "$d" ]] || d=/workspace
  case "$d" in
    /*) ;;
    *) d="/workspace/$d" ;; # 相对路径按容器内 /workspace 解释
  esac
  if ! _container_dir_exists "$d"; then
    return 2
  fi
  printf '%s' "$d"
}

# ---------- 3. exec（容器内执行） ----------------------------------------------

cmd_exec() {
  local use_daemon=0
  local timeout_s="${CAPBOX_EXEC_TIMEOUT:-600}"
  local cwd="/workspace"
  local root_mode=0
  local net_override=""
  local uid_override="" gid_override="" user_override=""
  local profile_override=""
  local -a cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --daemon) use_daemon=1; shift ;;
      --timeout)
        timeout_s="${2:-}"
        shift 2 || shift
        ;;
      --timeout=*)
        timeout_s="${1#*=}"
        shift
        ;;
      --cwd)
        cwd="${2:-/workspace}"
        shift 2 || shift
        ;;
      --cwd=*)
        cwd="${1#*=}"
        shift
        ;;
      --net)
        [[ $# -ge 2 ]] || die 2 "exec: --net 需要模式 none|restricted|open"
        net_override="${2}"
        shift 2
        ;;
      --net=*)
        net_override="${1#*=}"
        [[ -n "$net_override" ]] || die 2 "exec: --net 需要模式 none|restricted|open"
        shift
        ;;
      --uid)
        uid_override="${2:-}"
        shift 2 || shift
        ;;
      --uid=*)
        uid_override="${1#*=}"
        shift
        ;;
      --gid)
        gid_override="${2:-}"
        shift 2 || shift
        ;;
      --gid=*)
        gid_override="${1#*=}"
        shift
        ;;
      --user)
        user_override="${2:-}"
        shift 2 || shift
        ;;
      --user=*)
        user_override="${1#*=}"
        shift
        ;;
      --profile)
        profile_override="${2:-}"
        shift 2 || shift
        ;;
      --profile=*)
        profile_override="${1#*=}"
        shift
        ;;
      --root)
        root_mode=1
        cwd="/"
        shift
        ;;
      --)
        shift
        cmd+=("$@")
        break
        ;;
      -h | --help)
        i18n_print help.exec
        return 0
        ;;
      -*)
        die 2 "exec: 未知选项 $1（用 -- 分隔容器内命令）"
        ;;
      *)
        cmd+=("$@")
        break
        ;;
    esac
  done

  [[ ${#cmd[@]} -gt 0 ]] || die 2 "exec: 缺少要执行的命令，例如: capbox exec -- id -u"

  [[ "$timeout_s" =~ ^[0-9]+$ ]] || die 2 "exec: --timeout 必须是非负整数秒（当前: $timeout_s）"

  if [[ -n "$net_override" && "$use_daemon" -eq 1 ]]; then
    die 2 "exec: --daemon 用的是 capbox up 时的网络；要改网络请重新 up --net"
  fi
  if [[ -n "$net_override" ]]; then
    _capbox_declare_net "$net_override" exec
  fi

  if [[ -n "$profile_override" ]]; then
    case "$profile_override" in
      compat | untrusted | strict) CAPBOX_SECURITY_PROFILE="$profile_override" ;;
      *) die 2 "exec: --profile 必须是 compat|untrusted|strict（当前: $profile_override）" ;;
    esac
  fi

  # --user / --uid / --gid：覆盖容器内身份
  if [[ -n "$user_override" ]]; then
    local resolved=""
    if declare -F _idmap_resolve_user >/dev/null 2>&1; then
      resolved="$(_idmap_resolve_user "$user_override")" || resolved=""
    fi
    if [[ -z "$resolved" ]]; then
      die 2 "exec: 无法解析 --user $user_override（检查 rootfs /etc/passwd）"
    fi
    if [[ "$resolved" == *:* ]]; then
      uid_override="${resolved%%:*}"
      [[ -n "$gid_override" ]] || gid_override="${resolved#*:}"
    else
      uid_override="$resolved"
    fi
  fi
  if [[ -n "$uid_override" ]]; then
    [[ "$uid_override" =~ ^[0-9]+$ ]] || die 2 "exec: --uid 必须是非负整数（当前: $uid_override）"
    export CAPBOX_EXEC_UID_OVERRIDE="$uid_override"
  fi
  if [[ -n "$gid_override" ]]; then
    [[ "$gid_override" =~ ^[0-9]+$ ]] || die 2 "exec: --gid 必须是非负整数（当前: $gid_override）"
    export CAPBOX_EXEC_GID_OVERRIDE="$gid_override"
  elif [[ -n "$uid_override" ]]; then
    export CAPBOX_EXEC_GID_OVERRIDE="$uid_override"
  fi

  # --cwd 校验必须在父 shell 里做（不能用 $( ) 包住 die，否则 exit 只退子 shell，
  # 用户会看到错误信息却拿到 rc=0 并在错误的目录里执行）。
  local want_cwd="$cwd"
  (( root_mode == 1 )) && want_cwd="/"
  local resolved_cwd
  if ! resolved_cwd="$(_resolve_guest_cwd "$want_cwd")"; then
    case "$want_cwd" in
      /*) die 2 "exec: 容器内目录不存在: $want_cwd" ;;
      *) die 2 "exec: 容器内目录不存在: /workspace/$want_cwd" ;;
    esac
  fi
  cwd="$resolved_cwd"

  local cmdstr
  cmdstr="$(join_cmd_str "${cmd[@]}")"

  # daemon 模式无法改 bwrap --uid（容器已启动）；优先静态 drop helper，再 python
  if (( use_daemon == 1 )) && [[ -n "${CAPBOX_EXEC_UID_OVERRIDE:-}" ]]; then
    local _du="${CAPBOX_EXEC_UID_OVERRIDE}" _dg="${CAPBOX_EXEC_GID_OVERRIDE:-$_du}"
    local _qcmd _py _helper
    _qcmd="$(_shq "$cmdstr")"
    if declare -F _idmap_ensure_drop_priv_helper >/dev/null 2>&1; then
      _idmap_ensure_drop_priv_helper || true
    fi
    _helper="$(_idmap_drop_priv_guest_bin)"
    if [[ -x "$(_idmap_drop_priv_host_bin)" ]]; then
      cmdstr="$(_shq "$_helper") ${_du} ${_dg} /bin/sh -c ${_qcmd}"
    else
      _py=$(printf 'import os,sys\nos.setgid(%s)\ntry:\n os.setgroups([%s])\nexcept Exception:\n pass\nos.setuid(%s)\nos.execvp("/bin/sh",["sh","-c",sys.argv[1]])' "$_du" "$_dg" "$_du")
      cmdstr="python3 -c $(_shq "$_py") ${_qcmd}"
    fi
  fi

  local rc=0 t0 t1 ms
  t0=$(date +%s%3N 2>/dev/null || date +%s)
  if (( use_daemon == 1 )); then
    _exec_via_daemon "$cmdstr" "$cwd" "$timeout_s"
    rc=$?
  else
    require_rootfs
    exec_in_guest "$cmdstr" "$cwd" "$timeout_s"
    rc=$?
  fi
  t1=$(date +%s%3N 2>/dev/null || date +%s)
  ms=$((t1 - t0))
  unset CAPBOX_EXEC_UID_OVERRIDE CAPBOX_EXEC_GID_OVERRIDE
  if declare -F audit_command >/dev/null 2>&1; then
    audit_command exec "$rc" "$t0" "cmd=$cmdstr" "profile=${CAPBOX_SECURITY_PROFILE:-compat}" "net=${CAPBOX_NET:-open}"
  elif declare -F audit_event >/dev/null 2>&1; then
    if (( rc == 0 )); then
      audit_event exec ok "cmd=$cmdstr" "exit=$rc" "ms=$ms" "profile=${CAPBOX_SECURITY_PROFILE:-compat}" "net=${CAPBOX_NET:-open}"
    else
      audit_event exec fail "cmd=$cmdstr" "exit=$rc" "ms=$ms" "profile=${CAPBOX_SECURITY_PROFILE:-compat}" "net=${CAPBOX_NET:-open}"
    fi
  fi
  if declare -F _security_close_fd >/dev/null 2>&1; then
    _security_close_fd
  fi
  if (( rc == 124 )) && (( timeout_s > 0 )); then
    log_warn "容器内命令超时（${timeout_s}s），已终止"
  fi
  return "$rc"
}

# 走常驻容器；没有 daemon.sh / 未启动时给出清晰错误与退出码 3
_exec_via_daemon() {
  local cmdstr="${1:-}"
  local cwd="${2:-/workspace}"
  local timeout_s="${3:-600}"

  if ! declare -F daemon_request >/dev/null 2>&1; then
    log_err "常驻容器功能不可用：缺少库文件 $CAPBOX_LIB_DIR/daemon.sh"
    return 3
  fi
  if ! _probe_daemon; then
    log_err "守护容器未运行；请先以 DSH 后台任务方式启动: capbox up"
    return 3
  fi
  local rc=0
  # 契约 §4：daemon_request CMD [TIMEOUT] [FOLLOW] 只有三个参数。
  # 容器内工作目录因此拼进 CMD（契约 §5 的请求脚本格式就是 `cd <cwd>; <cmd>`）。
  # 注意用 POSIX 单引号转义（服务端是 /bin/sh，不能依赖 bash 的 %q）。
  daemon_request "cd $(_shq "$cwd") 2>/dev/null || cd /workspace; $cmdstr" "$timeout_s"
  rc=$?
  return "$rc"
}

# ---------- 4. shell（交互壳） ------------------------------------------------

cmd_shell() {
  local use_daemon=0 net_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --daemon) use_daemon=1; shift ;;
      --net)
        [[ $# -ge 2 ]] || die 2 "shell: --net 需要模式 none|restricted|open"
        net_override="${2}"
        shift 2
        ;;
      --net=*)
        net_override="${1#*=}"
        [[ -n "$net_override" ]] || die 2 "shell: --net 需要模式 none|restricted|open"
        shift
        ;;
      -h | --help)
        i18n_print help.shell
        return 0
        ;;
      *) die 2 "shell: 未知选项 $1" ;;
    esac
  done

  if [[ -n "$net_override" && "$use_daemon" -eq 1 ]]; then
    die 2 "shell: --daemon 用的是 capbox up 时的网络；要改网络请重新 up --net"
  fi
  if [[ -n "$net_override" ]]; then
    _capbox_declare_net "$net_override" shell
  fi

  if (( use_daemon == 1 )); then
    if ! declare -F daemon_request >/dev/null 2>&1 || ! _probe_daemon; then
      log_err "守护容器未运行；请先以 DSH 后台任务方式启动: capbox up"
      return 3
    fi
    # 契约 §4：daemon_request CMD [TIMEOUT] [FOLLOW]；FOLLOW=1 让客户端 tail -f 输出
    local t0 rc=0
    t0=$(date +%s%3N 2>/dev/null || date +%s)
    daemon_request 'cd /workspace; exec /bin/sh' 0 1
    rc=$?
    if declare -F audit_command >/dev/null 2>&1; then
      audit_command shell "$rc" "$t0" "cmd=shell --daemon" "net=${CAPBOX_NET:-open}"
    fi
    return "$rc"
  fi

  require_rootfs
  [[ -x "${CAPBOX_BWRAP:-}" ]] || die 5 "bwrap 不可用: ${CAPBOX_BWRAP:-未设置}"

  local shbin="/bin/sh"
  local -a shargs=()
  if [[ -t 0 && -t 1 ]]; then
    shargs=(-i)
  else
    # 无 tty：显式 -s 从 stdin 读脚本（与 --help「退化为读取 stdin 的 sh」一致）
    shargs=(-s)
  fi

  # 与 exec 同一条启动路径：restricted 挂 allowlist 桥，hardened 挂 seccomp。
  # timeout 0 = 不包 timeout，stdio 直接继承（idmap 路径须保留 stdin，见 _idmap_run_bwrap_argv）。
  # 交互式 shell 只记这次启动，不把会话里的每一行当审计。
  local t0 rc=0
  t0=$(date +%s%3N 2>/dev/null || date +%s)
  run_bwrap_oneshot /workspace 0 "$shbin" "${shargs[@]}"
  rc=$?
  if declare -F audit_command >/dev/null 2>&1; then
    audit_command shell "$rc" "$t0" "cmd=shell" "net=${CAPBOX_NET:-open}"
  fi
  return "$rc"
}

# ---------- 5. cp（宿主↔容器拷贝） --------------------------------------------

# 路径侧判定（严格按契约 §3.1）：
#   guest:/path  或  host:/path   显式前缀，永远优先
#   裸绝对路径 /x                 容器侧（以 os/<distro>/ 为根）
#   裸相对路径 x/y                容器侧（以 os/<distro>/ 为根）
# 也就是说 **不带前缀的一律是容器侧**；要操作宿主路径必须写 host:。
_cp_resolve() {
  local spec="${1:-}"
  local side path
  case "$spec" in
    guest:*)
      side="guest"
      path="${spec#guest:}"
      ;;
    host:*)
      side="host"
      path="${spec#host:}"
      ;;
    *)
      # 裸路径 = 容器侧（契约 §3.1：「容器侧路径以 os/<distro>/ 为根」）
      side="guest"
      path="$spec"
      ;;
  esac
  [[ -n "$path" ]] || die 2 "cp: 空路径: '$spec'"
  # 宿主侧相对路径按当前 cwd 解析
  if [[ "$side" == "host" ]]; then
    path="$(resolve_path "$path")"
  fi
  printf '%s\t%s\n' "$side" "$path"
}

cmd_cp() {
  local -a pos=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        i18n_print help.cp
        return 0
        ;;
      --)
        shift
        pos+=("$@")
        break
        ;;
      -*)
        die 2 "cp: 未知选项 $1"
        ;;
      *)
        pos+=("$1")
        shift
        ;;
    esac
  done
  [[ ${#pos[@]} -eq 2 ]] || die 2 "用法: capbox cp SRC DST"

  require_rootfs

  local src_spec="${pos[0]}" dst_spec="${pos[1]}"
  local src_info dst_info src_side src_path dst_side dst_path
  src_info="$(_cp_resolve "$src_spec")"
  dst_info="$(_cp_resolve "$dst_spec")"
  src_side="${src_info%%$'\t'*}"
  src_path="${src_info#*$'\t'}"
  dst_side="${dst_info%%$'\t'*}"
  dst_path="${dst_info#*$'\t'}"

  local src_abs dst_abs
  # 容器侧路径必须规范化并落在 CAPBOX_ROOTFS 内（拒绝 .. 穿越与越界 symlink）
  if [[ "$src_side" == "guest" ]]; then
    src_abs="$(_capbox_guest_path_in_rootfs "$src_path")" || die 1 "拒绝：容器侧源路径越界 rootfs: $src_path"
  else
    src_abs="$src_path"
  fi
  if [[ "$dst_side" == "guest" ]]; then
    dst_abs="$(_capbox_guest_path_in_rootfs "$dst_path")" || die 1 "拒绝：容器侧目标路径越界 rootfs: $dst_path"
  else
    dst_abs="$dst_path"
  fi

  if [[ ! -e "$src_abs" ]]; then
    if [[ "$src_side" == "guest" ]]; then
      die 1 "源文件在容器内不存在: $src_path"
    fi
    die 1 "源文件不存在: $src_abs"
  fi

  # 目标是已存在的目录 -> 拷进去（保持 basename 语义）
  local -a cpargs=(-a)
  if [[ -d "$dst_abs" ]]; then
    if [[ -d "$src_abs" ]]; then
      # cp -a dir dir 会拷成 dir/basename，符合预期
      :
    fi
  else
    mkdir -p "$(dirname "$dst_abs")" 2>/dev/null || true
  fi

  log_debug "cp $src_side:$src_path -> $dst_side:$dst_path"
  if ! cp "${cpargs[@]}" -- "$src_abs" "$dst_abs" 2>/tmp/.capbox-cp-err.$$; then
    local err
    err="$(cat /tmp/.capbox-cp-err.$$ 2>/dev/null || true)"
    rm -f /tmp/.capbox-cp-err.$$ 2>/dev/null || true
    log_err "拷贝失败: ${err:-未知错误}"
    return 1
  fi
  rm -f /tmp/.capbox-cp-err.$$ 2>/dev/null || true
  return 0
}

# ---------- 6. ls / ps（列目录与进程） ----------------------------------------

cmd_ls() {
  local path="/workspace"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        i18n_print help.ls
        return 0
        ;;
      --)
        shift
        [[ $# -gt 0 ]] && path="$1"
        break
        ;;
      -*)
        die 2 "ls: 未知选项 $1"
        ;;
      *)
        path="$1"
        shift
        ;;
    esac
  done

  case "$path" in
    /*) ;;
    *) path="/workspace/$path" ;;
  esac
  _container_dir_exists "$path" || die 1 "容器内目录不存在: $path"
  require_rootfs
  local q
  q="$(printf '%q' "$path")"
  exec_in_guest "ls -la -- $q" /workspace "${CAPBOX_EXEC_TIMEOUT:-600}"
  return $?
}

cmd_ps() {
  [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] || die 2 "用法: capbox ps"
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    i18n_print help.ps
    return 0
  fi
  require_rootfs
  # 优先 procps 的 ps aux，失败则退化为 busybox 的 ps
  exec_in_guest 'ps aux 2>/dev/null || ps' /workspace "${CAPBOX_EXEC_TIMEOUT:-600}"
  local rc=$?
  if (( rc != 0 )); then
    # 最坏情况：直接列 /proc
    log_warn "ps 不可用，退化为读取 /proc"
    exec_in_guest 'i=0; for d in /proc/[0-9]*; do p=${d#/proc/}; c=$(cat "$d/comm" 2>/dev/null); echo "$p $c"; i=$((i+1)); done; echo "共 $i 个进程"' /workspace 60
    return $?
  fi
  return 0
}

# ---------- 7. pkg（软件包管理） ----------------------------------------------

# 包名白名单校验（防注入）
_pkg_names_ok() {
  local p
  for p in "$@"; do
    [[ "$p" =~ ^[A-Za-z0-9][A-Za-z0-9._+:@/-]*(=[A-Za-z0-9][A-Za-z0-9._+:~/-]*)?$ ]] || {
      log_err "可疑包名，已拒绝: $p"
      return 1
    }
  done
  return 0
}

cmd_pkg() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  while [[ "${1:-}" == "--" ]]; do shift; done

  case "$sub" in
    -h | --help | "")
      i18n_print help.pkg
      return 0
      ;;
  esac

  require_rootfs

  # 装包前确保镜像源/代理是最新的（幂等）
  inject_mirrors "$CAPBOX_DISTRO" >/dev/null 2>&1 || true
  inject_proxy_files "$CAPBOX_DISTRO" >/dev/null 2>&1 || true

  local distro="$CAPBOX_DISTRO"
  local timeout_s="${CAPBOX_PKG_TIMEOUT:-1800}"
  local cmdstr rc

  case "$sub" in
    install)
      [[ $# -gt 0 ]] || die 2 "pkg install: 缺少包名"
      _pkg_names_ok "$@" || die 2 "包名非法"
      if [[ "$distro" == "alpine" ]]; then
        cmdstr="apk add --no-cache $(_q_join "$@")"
      else
        cmdstr="DEBIAN_FRONTEND=noninteractive apt-get -o APT::Sandbox::User=root -o Acquire::Retries=3 update && DEBIAN_FRONTEND=noninteractive apt-get -o APT::Sandbox::User=root -o Acquire::Retries=3 install -y --no-install-recommends $(_q_join "$@")"
      fi
      ;;
    remove)
      [[ $# -gt 0 ]] || die 2 "pkg remove: 缺少包名"
      _pkg_names_ok "$@" || die 2 "包名非法"
      if [[ "$distro" == "alpine" ]]; then
        cmdstr="apk del $(_q_join "$@")"
      else
        cmdstr="DEBIAN_FRONTEND=noninteractive apt-get -o APT::Sandbox::User=root remove -y $(_q_join "$@")"
      fi
      ;;
    update)
      if [[ "$distro" == "alpine" ]]; then
        cmdstr="apk update"
      else
        cmdstr="DEBIAN_FRONTEND=noninteractive apt-get -o APT::Sandbox::User=root -o Acquire::Retries=3 update"
      fi
      ;;
    list)
      local pat="${1:-}"
      if [[ "$distro" == "alpine" ]]; then
        cmdstr="apk list --installed 2>/dev/null | sed 's/ .*//' | sort"
      else
        cmdstr="dpkg-query -W -f='\${Package} \${Version}\n' 2>/dev/null | sort"
      fi
      if [[ -n "$pat" ]]; then
        [[ "$pat" =~ ^[A-Za-z0-9._+:@/-]+$ ]] || die 2 "pkg list: 过滤模式非法: $pat"
        cmdstr="$cmdstr | grep -i -- $(printf '%q' "$pat") || true"
      fi
      ;;
    *)
      die 2 "pkg: 未知子命令 $sub（install|remove|update|list）"
      ;;
  esac

  local t0=0
  t0=$(date +%s%3N 2>/dev/null || date +%s)
  rc=0
  _pkg_run_guest "$sub" "$cmdstr" "$timeout_s" || rc=$?

  if [[ "$sub" == "install" || "$sub" == "update" ]]; then
    _pkg_report_dpkg_audit || true
  fi

  if (( rc != 0 )); then
    if [[ "${CAPBOX_IDMAP_STATUS:-}" == "multi" ]]; then
      log_warn "pkg $sub 返回 $rc（请结合上方 dpkg audit / 日志判断）"
    else
      log_warn "pkg $sub 返回 $rc（单 UID 下 chown 告警常见；请看 dpkg audit 与可执行文件）"
    fi
  fi
  if declare -F audit_command >/dev/null 2>&1; then
    local _pkg_cmd="pkg $sub"
    if [[ $# -gt 0 ]]; then
      _pkg_cmd="pkg $sub $*"
    fi
    if (( rc == 0 )); then
      audit_command pkg "$rc" "$t0" "cmd=$_pkg_cmd"
    else
      audit_command pkg "$rc" "$t0" "cmd=$_pkg_cmd" "detail=pkg $sub 返回 $rc"
    fi
  fi
  return "$rc"
}

# install / update 在会话为 none 时单独出网。remove / list 和随后的 dpkg audit 不给网。
# 只改本进程的 CAPBOX_NET，调用结束恢复，不写 config.env。
_pkg_run_guest() {
  local sub="${1:-}" cmdstr="${2:-}" timeout_s="${3:-}"
  local saved="${CAPBOX_NET:-}" granted=0 rc=0
  local CAPBOX_APK_SCRIPT_FILTER=0
  if [[ "$CAPBOX_DISTRO" == alpine && ( "$sub" == install || "$sub" == remove ) ]]; then
    CAPBOX_APK_SCRIPT_FILTER=1
  fi
  if [[ "$sub" == "install" || "$sub" == "update" ]] && [[ "${CAPBOX_NET:-open}" == "none" ]]; then
    CAPBOX_NET=open
    granted=1
    log_info "pkg ${sub}: 会话网络是 none，本次命令单独出网"
  fi
  exec_in_guest "$cmdstr" /workspace "$timeout_s" || rc=$?
  _security_close_fd
  if (( granted == 1 )); then
    CAPBOX_NET="$saved"
  fi
  return "$rc"
}

# 明确报告 dpkg 未完成配置（iU/iF 等）；有问题返回 1
_pkg_report_dpkg_audit() {
  [[ "${CAPBOX_DISTRO:-}" == "ubuntu" || "${CAPBOX_DISTRO:-}" == "debian" ]] || return 0
  local out
  out="$(exec_in_guest 'dpkg --audit 2>/dev/null; echo ----; dpkg -l 2>/dev/null | awk '\''$1 ~ /[UF]/ {print}'\'' || true' /workspace 120)" || true
  if printf '%s\n' "$out" | grep -qE '^[hiurpn]*[UF]'; then
    log_err "dpkg 存在未完成配置的包（状态含 U/F，例如 iU/iF）："
    printf '%s\n' "$out" | head -n 40 >&2 || true
    log_err "这不是被掩盖的成功：请检查 CAPBOX_IDMAP 与 postinst 日志"
    return 1
  fi
  if printf '%s\n' "$out" | grep -qi 'unpacked but not yet configured'; then
    log_err "dpkg --audit 报告有未配置的包"
    printf '%s\n' "$out" | head -n 40 >&2
    return 1
  fi
  log_info "dpkg audit：无 iU/iF 残留"
  return 0

}

# 把参数安全拼成一行（每项单独 %q）
_q_join() {
  local i out=""
  for (( i = 1; i <= $#; i++ )); do
    (( i > 1 )) && out+=" "
    out+="$(_shq "${!i}")"
  done
  printf '%s' "$out"
}

# ---------- 8. 基础命令小工具 -------------------------------------------------

cmd_ls_rootfs() {
  [[ $# -eq 0 ]] || die 2 "ls-rootfs: 不需要参数"
  ls -la -- "$CAPBOX_ROOTFS"
}
