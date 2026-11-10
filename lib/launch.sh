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

# build_bwrap_args MODE [CWD]
#   MODE = oneshot | daemon
# 打印 bwrap 参数，一行一个（数组语义），不含最终的 `-- 命令` 部分。
build_bwrap_args() {
  local mode="${1:-oneshot}"
  local cwd="${2:-/workspace}"
  local -a a=()

  _capbox_enforce_bwrap_baseline || return $?

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
  _capbox_append_ro_cli_binds a || return $?
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

  # ---- 环境白名单（clearenv 之后显式重建；勿透传宿主 *TOKEN/*_KEY/SSH/GPG）----
  a+=(--setenv HOME /root)
  a+=(--setenv PATH /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
  a+=(--setenv TERM "${TERM:-xterm-256color}")
  a+=(--setenv LANG "${LANG:-C.UTF-8}")

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

  printf '%s\n' "${a[@]}"
}

