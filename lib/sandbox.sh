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
    *) i18n_die 2 sandbox.sandbox_bwrap_cmd_unknown_mode_expected_oneshot mode="$mode" ;;
  esac

  [[ -x "${CAPBOX_BWRAP:-}" ]] || i18n_die 5 common.bwrap_unavailable bwrap="$(i18n_or "${CAPBOX_BWRAP:-}" val.unset)"
  rootfs_ready || i18n_die 4 sandbox.rootfs_missing_unusable_run_capbox_init_first rootfs="$(i18n_or "${CAPBOX_ROOTFS:-}" val.unset)"

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
    i18n_die "$_bbrc" common.unable_build_bwrap_arguments_rc_common_causes _bbrc="$_bbrc"
  fi
  (( ${#args[@]} > 0 )) || i18n_die 4 sandbox.unable_build_bwrap_arguments_rootfs_missing

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
  # Only the host task launcher supplies this context. Guest env uses --clearenv.
  local _audit_task_id="" _audit_task_path=""
  if [[ "${CAPBOX_TASK_AUDIT_ID:-}" =~ ^[0-9a-f]{32}$ &&
        "${CAPBOX_NET_SESSION:-}" == "task-$CAPBOX_TASK_AUDIT_ID" &&
        "${CAPBOX_TASK_AUDIT_PATH:-}" == /*/logs/audit.jsonl ]]; then
    _audit_task_id="$CAPBOX_TASK_AUDIT_ID"
    _audit_task_path="$CAPBOX_TASK_AUDIT_PATH"
  fi
  local _task_status_fd=""
  if [[ -n "$_audit_task_id" && "${CAPBOX_TASK_LAUNCH_STATUS:-}" == /*/"$_audit_task_id"/launch.jsonl ]]; then
    if exec {_task_status_fd}>"$CAPBOX_TASK_LAUNCH_STATUS"; then
      printf 'supported\n' >&"$_task_status_fd"
    else
      _task_status_fd=""
    fi
  fi
  local use_daemon=0
  local timeout_s="${CAPBOX_EXEC_TIMEOUT:-600}"
  local cwd="/workspace"
  local root_mode=0
  local net_override=""
  local uid_override="" gid_override="" user_override=""
  local profile_override=""
  local image_name=""
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
        [[ $# -ge 2 ]] || i18n_die 2 sandbox.exec_net_requires_mode_none_restricted_open
        net_override="${2}"
        shift 2
        ;;
      --net=*)
        net_override="${1#*=}"
        [[ -n "$net_override" ]] || i18n_die 2 sandbox.exec_net_requires_mode_none_restricted_open
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
      --image)
        image_name="${2:-}"
        shift 2 || shift
        ;;
      --image=*)
        image_name="${1#*=}"
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
        i18n_die 2 sandbox.exec_unknown_option_separate_guest_command arg="$1"
        ;;
      *)
        cmd+=("$@")
        break
        ;;
    esac
  done

  [[ ${#cmd[@]} -gt 0 ]] || i18n_die 2 sandbox.exec_missing_command_run_e_g_capbox

  [[ "$timeout_s" =~ ^[0-9]+$ ]] || i18n_die 2 sandbox.exec_timeout_must_non_negative_integer_number timeout_s="$timeout_s"

  if [[ -n "$net_override" && "$use_daemon" -eq 1 ]]; then
    i18n_die 2 sandbox.exec_daemon_uses_network_chosen_capbox_up
  fi
  if [[ -n "$net_override" ]]; then
    _capbox_declare_net "$net_override" exec
  fi

  if [[ -n "$profile_override" ]]; then
    case "$profile_override" in
      compat | untrusted | strict) CAPBOX_SECURITY_PROFILE="$profile_override" ;;
      *) i18n_die 2 sandbox.exec_profile_must_compat_untrusted_strict_got profile_override="$profile_override" ;;
    esac
  fi

  if [[ "${CAPBOX_AGENT_LOCKED:-}" == 1 ]] &&
     [[ "$use_daemon" == 1 || "$timeout_s" != 0 || -n "$image_name$uid_override$gid_override$user_override" ]]; then
    _agent_launch_failure exec_entry
    return 5
  fi

  # --image 只替换这一次的 rootfs，不改 DISTRO / config.env，也不能套进已启动的守护容器。
  # 放在 --user / --cwd 之前，让 passwd 和工作目录都按该镜像解释。
  if [[ -n "$image_name" ]]; then
    (( use_daemon == 1 )) && i18n_die 2 oci.exec_image_daemon
    _image_docker_use_rootfs "$image_name" || return $?
    rootfs_ready_at "$CAPBOX_ROOTFS" || i18n_die 4 oci.not_rootfs path="$CAPBOX_ROOTFS"
  fi

  # --user / --uid / --gid：覆盖容器内身份
  if [[ -n "$user_override" ]]; then
    local resolved=""
    if declare -F _idmap_resolve_user >/dev/null 2>&1; then
      resolved="$(_idmap_resolve_user "$user_override")" || resolved=""
    fi
    if [[ -z "$resolved" ]]; then
      i18n_die 2 sandbox.exec_unable_resolve_user_check_rootfs_etc user_override="$user_override"
    fi
    if [[ "$resolved" == *:* ]]; then
      uid_override="${resolved%%:*}"
      [[ -n "$gid_override" ]] || gid_override="${resolved#*:}"
    else
      uid_override="$resolved"
    fi
  fi
  if [[ -n "$uid_override" ]]; then
    [[ "$uid_override" =~ ^[0-9]+$ ]] || i18n_die 2 sandbox.exec_uid_must_non_negative_integer_got uid_override="$uid_override"
    export CAPBOX_EXEC_UID_OVERRIDE="$uid_override"
  fi
  if [[ -n "$gid_override" ]]; then
    [[ "$gid_override" =~ ^[0-9]+$ ]] || i18n_die 2 sandbox.exec_gid_must_non_negative_integer_got gid_override="$gid_override"
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
      /*) i18n_die 2 sandbox.exec_guest_directory_does_not_exist want_cwd="$want_cwd" ;;
      *) i18n_die 2 sandbox.exec_guest_directory_does_not_exist_workspace want_cwd="$want_cwd" ;;
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
    i18n_warn sandbox.guest_command_timed_out_s_terminated timeout_s="${timeout_s}"
  fi
  return "$rc"
}

# 走常驻容器；没有 daemon.sh / 未启动时给出清晰错误与退出码 3
_exec_via_daemon() {
  local cmdstr="${1:-}"
  local cwd="${2:-/workspace}"
  local timeout_s="${3:-600}"

  if ! declare -F daemon_request >/dev/null 2>&1; then
    i18n_err sandbox.persistent_container_feature_unavailable_missing_library_dae lib_dir="$CAPBOX_LIB_DIR"
    return 3
  fi
  if ! _probe_daemon; then
    i18n_err daemon.daemon_container_not_running_start_first_dsh
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
        [[ $# -ge 2 ]] || i18n_die 2 sandbox.shell_net_requires_mode_none_restricted_open
        net_override="${2}"
        shift 2
        ;;
      --net=*)
        net_override="${1#*=}"
        [[ -n "$net_override" ]] || i18n_die 2 sandbox.shell_net_requires_mode_none_restricted_open
        shift
        ;;
      -h | --help)
        i18n_print help.shell
        return 0
        ;;
      *) i18n_die 2 sandbox.shell_unknown_option arg="$1" ;;
    esac
  done

  if [[ -n "$net_override" && "$use_daemon" -eq 1 ]]; then
    i18n_die 2 sandbox.shell_daemon_uses_network_chosen_capbox_up
  fi
  if [[ -n "$net_override" ]]; then
    _capbox_declare_net "$net_override" shell
  fi

  if (( use_daemon == 1 )); then
    if ! declare -F daemon_request >/dev/null 2>&1 || ! _probe_daemon; then
      i18n_err daemon.daemon_container_not_running_start_first_dsh
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
  [[ -x "${CAPBOX_BWRAP:-}" ]] || i18n_die 5 common.bwrap_unavailable bwrap="$(i18n_or "${CAPBOX_BWRAP:-}" val.unset)"

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
  [[ -n "$path" ]] || i18n_die 2 sandbox.cp_empty_path spec="$spec"
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
        i18n_die 2 sandbox.cp_unknown_option arg="$1"
        ;;
      *)
        pos+=("$1")
        shift
        ;;
    esac
  done
  [[ ${#pos[@]} -eq 2 ]] || i18n_die 2 sandbox.usage_capbox_cp_src_dst

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
    src_abs="$(_capbox_guest_path_in_rootfs "$src_path")" || i18n_die 1 sandbox.refused_container_side_source_path_escapes_rootfs src_path="$src_path"
  else
    src_abs="$src_path"
  fi
  if [[ "$dst_side" == "guest" ]]; then
    dst_abs="$(_capbox_guest_path_in_rootfs "$dst_path")" || i18n_die 1 sandbox.refused_container_side_destination_path_escapes_rootfs dst_path="$dst_path"
  else
    dst_abs="$dst_path"
  fi

  if [[ ! -e "$src_abs" ]]; then
    if [[ "$src_side" == "guest" ]]; then
      i18n_die 1 sandbox.source_file_does_not_exist_container src_path="$src_path"
    fi
    i18n_die 1 sandbox.source_file_does_not_exist src_abs="$src_abs"
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
    i18n_err sandbox.copy_failed err="$(i18n_or "${err:-}" val.unknown_error)"
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
        i18n_die 2 sandbox.ls_unknown_option arg="$1"
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
  _container_dir_exists "$path" || i18n_die 1 sandbox.guest_directory_does_not_exist path="$path"
  require_rootfs
  local q
  q="$(printf '%q' "$path")"
  exec_in_guest "ls -la -- $q" /workspace "${CAPBOX_EXEC_TIMEOUT:-600}"
  return $?
}

# 在宿主上查好已翻译的进程计数字符串，再拼进 guest 命令；guest 内不得调用 i18n_*。
_sandbox_ps_proc_fallback_cmd() {
  local total_fmt
  total_fmt="$(i18n_get sandbox.ps_total)"
  total_fmt="${total_fmt//%/%%}"
  total_fmt="${total_fmt//\{count\}/%s}"
  printf '%s' 'i=0; for d in /proc/[0-9]*; do p=${d#/proc/}; c=$(cat "$d/comm" 2>/dev/null); echo "$p $c"; i=$((i+1)); done; printf '
  printf '%s' "$(_shq "$total_fmt")"
  printf '%s' ' "$i"; echo'
}

cmd_ps() {
  [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] || i18n_die 2 sandbox.usage_capbox_ps
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
    i18n_warn sandbox.ps_unavailable_falling_back_reading_proc
    exec_in_guest "$(_sandbox_ps_proc_fallback_cmd)" /workspace 60
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
      i18n_err sandbox.suspicious_package_name_rejected p="$p"
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
      [[ $# -gt 0 ]] || i18n_die 2 sandbox.pkg_install_missing_package_name
      _pkg_names_ok "$@" || i18n_die 2 sandbox.invalid_package_name
      if [[ "$distro" == "alpine" ]]; then
        cmdstr="apk add --no-cache $(_q_join "$@")"
      else
        cmdstr="DEBIAN_FRONTEND=noninteractive apt-get -o APT::Sandbox::User=root -o Acquire::Retries=3 update && DEBIAN_FRONTEND=noninteractive apt-get -o APT::Sandbox::User=root -o Acquire::Retries=3 install -y --no-install-recommends $(_q_join "$@")"
      fi
      ;;
    remove)
      [[ $# -gt 0 ]] || i18n_die 2 sandbox.pkg_remove_missing_package_name
      _pkg_names_ok "$@" || i18n_die 2 sandbox.invalid_package_name
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
        [[ "$pat" =~ ^[A-Za-z0-9._+:@/-]+$ ]] || i18n_die 2 sandbox.pkg_list_invalid_filter_pattern pat="$pat"
        cmdstr="$cmdstr | grep -i -- $(printf '%q' "$pat") || true"
      fi
      ;;
    *)
      i18n_die 2 sandbox.pkg_unknown_subcommand_install_remove_update_list sub="$sub"
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
      i18n_warn sandbox.pkg_returned_dpkg_audit_logs_above_judge sub="$sub" rc="$rc"
    else
      i18n_warn sandbox.pkg_returned_chown_warnings_common_under_single sub="$sub" rc="$rc"
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
      audit_command pkg "$rc" "$t0" "cmd=$_pkg_cmd" "detail=$(i18n_fmt audit.detail_pkg_returned sub="$sub" rc="$rc")"
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
    i18n_info sandbox.pkg_session_network_none_command_using_one sub="${sub}"
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
    i18n_err sandbox.dpkg_has_packages_not_fully_configured_state
    printf '%s\n' "$out" | head -n 40 >&2 || true
    i18n_err sandbox.not_hidden_success_check_capbox_idmap_postinst
    return 1
  fi
  if printf '%s\n' "$out" | grep -qi 'unpacked but not yet configured'; then
    i18n_err sandbox.dpkg_audit_reported_unconfigured_packages
    printf '%s\n' "$out" | head -n 40 >&2
    return 1
  fi
  i18n_info sandbox.dpkg_audit_no_leftover_iu
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
  [[ $# -eq 0 ]] || i18n_die 2 sandbox.ls_rootfs_no_arguments_expected
  ls -la -- "$CAPBOX_ROOTFS"
}
