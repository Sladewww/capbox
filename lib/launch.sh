# shellcheck shell=bash
# 共享启动策略。本模块只拼装参数，从不拉起 guest。

# strict 且用户没有写过 ROOTFS_RO 时，在选择挂载方式之前打开只读 rootfs。
# load_config 会把缺省值写成 0，所以不能靠「变量为空」判断。
_capbox_apply_profile_rootfs_default() {
  local profile=""
  if ! declare -F _security_profile >/dev/null 2>&1; then
    return 0
  fi
  profile="$(_security_profile)" || return $?
  if [[ "$profile" == "strict" && -z "${CAPBOX_CFG_EXPLICIT[ROOTFS_RO]:-}" ]]; then
    CAPBOX_ROOTFS_RO=1
  fi
  return 0
}

# Locked launches are passed only by the host task controller.
_agent_launch_failure() {
  local check="$1"
  if [[ -n "${_task_status_fd:-}" ]]; then
    printf '{"phase":"protection_failed","check":"%s"}\n' "$check" >&"$_task_status_fd"
  fi
  i18n_err launch.agent_protection_failed check="$check"
}

_agent_launch_config_ok() {
  if (( UID == 0 || EUID == 0 )); then
    _agent_launch_failure host_uid
    return 5
  fi
  if [[ "$1" != oneshot || -z "${_task_status_fd:-}" ||
        "${CAPBOX_SECURITY_PROFILE:-}" != strict || "${CAPBOX_IDMAP:-}" != off ||
        "${CAPBOX_NET:-}" != none || "${CAPBOX_ROOTFS_RO:-}" != 1 ||
        "${CAPBOX_OVERLAY:-}" != off || "${CAPBOX_LANDLOCK:-}" != on ||
        "${CAPBOX_EXEC_UID:-}" != 0 || "${CAPBOX_EXEC_GID:-}" != 0 ||
        "${CAPBOX_BWRAP:-}" != /usr/bin/bwrap ||
        "${CAPBOX_BWRAP_NO_PIDNS:-0}" != 0 || "${CAPBOX_BWRAP_NO_DIE_WITH_PARENT:-0}" != 0 ||
        "${CAPBOX_ALLOW_OLD_BWRAP:-0}" != 0 || -n "${CAPBOX_ALLOW_OLD_BWRAP_ONCE:-}" ||
        -n "${CAPBOX_BWRAP_EXTRA:-}${CAPBOX_FS_BINDS:-}${CAPBOX_NET_ALLOW:-}${CAPBOX_PROXY:-}" ||
        -n "${CAPBOX_UID_MAP:-}${CAPBOX_GID_MAP:-}${CAPBOX_SETGROUPS:-}${CAPBOX_DISK_MAX:-}" ||
        -n "${CAPBOX_EXEC_UID_OVERRIDE:-}${CAPBOX_EXEC_GID_OVERRIDE:-}${CAPBOX_OCI_ENV_FILE:-}" ||
        -n "${CAPBOX_CRED_CA_CERT:-}${CAPBOX_CRED_GUEST_ENV_FILE:-}" ]]; then
    _agent_launch_failure resolved_policy
    return 5
  fi
}

_agent_launch_run() {
  local src private dir helper broker rc=0
  src="$(dirname -- "${BASH_SOURCE[0]}")"
  broker="$src/agent-launch.py"
  private="$(_capbox_host_state_dir)" || {
    _agent_launch_failure host_runtime
    return 5
  }
  dir="$(mktemp -d "$private/agent-launch.XXXXXX")" || {
    _agent_launch_failure host_runtime
    return 5
  }
  helper="$dir/probe"
  if ! /usr/bin/cc -static -O2 -o "$helper" "$src/guest/capbox-agent-probe.c"; then
    rm -rf -- "$dir"
    _agent_launch_failure probe_build
    return 5
  fi
  /usr/bin/python3 -I "$broker" "$_task_status_fd" "$helper" "$CAPBOX_ROOTFS" "$CAPBOX_WORKSPACE" "$@" || rc=$?
  rm -rf -- "$dir"
  return "$rc"
}

# build_bwrap_args MODE [CWD]
#   MODE = oneshot | daemon
# 普通启动逐行输出，锁定 Agent 用 NUL 分隔。两者都不含最终的 `-- 命令`。
build_bwrap_args() {
  local mode="${1:-oneshot}"
  local cwd="${2:-/workspace}"
  local -a a=()

  if [[ "${CAPBOX_AGENT_LOCKED:-}" == 1 ]]; then
    _agent_launch_config_ok "$mode" || return $?
  fi
  local baseline_rc=0
  _capbox_enforce_bwrap_baseline || baseline_rc=$?
  if (( baseline_rc != 0 )); then
    if [[ "${CAPBOX_AGENT_LOCKED:-}" == 1 ]]; then
      _agent_launch_failure bubblewrap_baseline
    fi
    return "$baseline_rc"
  fi

  [[ -n "${CAPBOX_ROOTFS:-}" && -d "$CAPBOX_ROOTFS" ]] || return 4
  if declare -F _capbox_require_safe_workspace >/dev/null 2>&1; then
    _capbox_require_safe_workspace || return $?
  fi
  _capbox_apply_profile_rootfs_default || return $?

  # ---- 文件系统 ----
  if declare -F _fsguard_apply_rootfs_mount >/dev/null 2>&1; then
    _fsguard_apply_rootfs_mount a
  else
    a+=(--bind "$CAPBOX_ROOTFS" /)
  fi
  if [[ -n "${_task_status_fd:-}" ]]; then
    if "$CAPBOX_BWRAP" --help | grep -F -- '--json-status-fd' >/dev/null; then
      a+=(--json-status-fd "$_task_status_fd")
    else
      printf 'unsupported\n' >&"$_task_status_fd"
    fi
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
  if [[ "$mode" == oneshot && "${CAPBOX_TASK_WORKSPACE_READONLY:-}" == 1 ]]; then
    a+=(--ro-bind "$CAPBOX_WORKSPACE" /workspace)
    local writable
    while IFS= read -r writable; do
      [[ -n "$writable" ]] || continue
      a+=(--bind "$CAPBOX_WORKSPACE/$writable" "/workspace/$writable")
    done <<<"${CAPBOX_TASK_WRITE_DIRS:-}"
  else
    a+=(--bind "$CAPBOX_WORKSPACE" /workspace)
  fi
  # 覆盖式只读挂载：防止 guest 改写宿主侧 CLI / 配置（下次执行 = RCE）
  _capbox_append_ro_cli_binds a || return $?
  # FS hide / 额外 binds（拒绝工作区外任意 bind）
  if declare -F _fsguard_append_bwrap_args >/dev/null 2>&1; then
    _fsguard_append_bwrap_args a || return $?
  fi

  # resolv.conf：必须是普通文件（宿主上是符号链接）
  if [[ "${CAPBOX_AGENT_LOCKED:-}" != 1 ]]; then
    refresh_resolv >/dev/null 2>&1 || true
  fi
  if [[ "${CAPBOX_AGENT_LOCKED:-}" != 1 && -f "$CAPBOX_STATE_DIR/resolv.conf" ]]; then
    a+=(--ro-bind "$CAPBOX_STATE_DIR/resolv.conf" /etc/resolv.conf)
  fi

  # CA 证书：rootfs 内没有就借用宿主的（坑 7）
  # RHEL/CentOS 系 /etc/ssl/certs 常是指向 /etc/pki/tls/certs 的符号链接，
  # bwrap 不允许挂载到符号链接目标；这类镜像自带 ca-bundle.crt，跳过宿主 CA bind。
  if [[ "${CAPBOX_AGENT_LOCKED:-}" != 1 ]] && _rootfs_lacks_ca &&
     [[ -d /etc/ssl/certs ]] && [[ ! -L "$CAPBOX_ROOTFS/etc/ssl/certs" ]]; then
    mkdir -p "$CAPBOX_ROOTFS/etc/ssl/certs" 2>/dev/null || true
    a+=(--ro-bind /etc/ssl/certs /etc/ssl/certs)
  fi

  # ---- 环境：先无条件清空宿主继承，再白名单重建 ----
  # 必须在任何 --setenv（含 net.sh / security.sh 注入）之前。
  # 否则容器会继承 AWS_*/GITHUB_TOKEN/SSH_AUTH_SOCK 等宿主密钥（见 SECURITY.md / CVE-2026-108592 同类根因）。
  a+=(--clearenv)

  # ---- 命名空间 / 网络三档 ----
  if declare -F _net_append_bwrap_args >/dev/null 2>&1; then
    _net_append_bwrap_args a || return $?
  else
    case "${CAPBOX_NET:-open}" in
      none | restricted) a+=(--unshare-net) ;;
      open | host | "") ;;
      *)
        i18n_err launch.capbox_net_invalid_net_sh_not_loaded net="${CAPBOX_NET}"
        return 2
        ;;
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
  if [[ ! "$_eu" =~ ^[0-9]+$ || ! "$_eg" =~ ^[0-9]+$ ]] || (( _eu > 4294967295 || _eg > 4294967295 )); then
    i18n_err launch.exec_uid_exec_gid_must_numbers_0 _eu="${_eu}" _eg="${_eg}"
    return 2
  fi
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

  if [[ "$mode" == oneshot && "${CAPBOX_TASK_WORKSPACE_READONLY:-}" == 1 ]]; then
    # Prevent reopening read-only mounts, including through a nested user namespace.
    a+=(--cap-drop CAP_SYS_ADMIN --disable-userns)
  fi

  # ---- 环境白名单（clearenv 之后显式重建；勿透传宿主 *TOKEN/*_KEY/SSH/GPG）----
  a+=(--setenv HOME /root)
  a+=(--setenv PATH /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
  a+=(--setenv TERM "${TERM:-xterm-256color}")
  a+=(--setenv LANG "${LANG:-C.UTF-8}")
  # docker/OCI 镜像的 Env 只在 image docker run 设置 CAPBOX_OCI_ENV_FILE 时注入。
  # 值来自 meta.json，经 --setenv 进入 guest，不 export 到宿主 shell。
  if [[ -n "${CAPBOX_OCI_ENV_FILE:-}" ]]; then
    if ! declare -F _oci_append_image_env >/dev/null 2>&1; then
      i18n_err oci.env_module_missing
      return 1
    fi
    _oci_append_image_env a "$CAPBOX_OCI_ENV_FILE" || return $?
  fi

  # 宿主凭证代理：此处只有占位符（真实密钥留在宿主 inject map）。
  if declare -F _credentials_append_bwrap_args >/dev/null 2>&1; then
    _credentials_append_bwrap_args a || return $?
  fi

  # restricted 模式由 net.sh 注入桥接代理；此处仅处理用户显式 CAPBOX_PROXY（open 模式）
  if [[ -n "${CAPBOX_PROXY:-}" ]]; then
    local _mode
    _mode="${CAPBOX_NET:-open}"
    if declare -F _net_mode >/dev/null 2>&1; then
      _mode="$(_net_mode)" || return $?
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

  # FS_BINDS / CAPBOX_BWRAP_EXTRA 都在第一次 logs 只读挂载之后。
  # 再挂一次，保证最后盖住 logs 的是只读绑定。
  _capbox_ro_protect_logs a || return $?

  if declare -F _net_append_ready_bind >/dev/null 2>&1; then
    _net_append_ready_bind a || return $?
  fi

  if [[ "${CAPBOX_AGENT_LOCKED:-}" == 1 ]]; then
    # Existing bwrap proc protections are conditional. Seal the fresh proc mount.
    a+=(--remount-ro /proc --assert-userns-disabled)
    printf '%s\0' "${a[@]}"
  else
    printf '%s\n' "${a[@]}"
  fi
}

