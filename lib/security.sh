# shellcheck shell=bash
# =============================================================================
# CapBox - security.sh
# 安全配置档：compat（默认，不削弱兼容） / untrusted / strict
#
# compat    : 现有行为（容器内 --cap-add ALL，无 seccomp，不额外藏路径）
# untrusted : 显式收紧 — 最小 capability、真实 seccomp BPF、敏感宿主路径不可见、
#             --disable-userns；仍允许常用包管理与服务所需操作
# strict    : untrusted + 更严 seccomp（ptrace/perf/...）+ 默认倾向 rootfs 只读
#
# Linux userns 边界（务必诚实）：
#   * 容器内 “root” 的能力受宿主 userns 与映射范围限制，不是宿主 root。
#   * seccomp/capability 降低的是 guest 攻击面；不能替代外层沙箱。
#   * 工作区 /workspace 默认仍 RW（设计如此）；敏感子路径可用 FS_HIDE 遮盖。
# =============================================================================

_security_profile() {
  case "${CAPBOX_SECURITY_PROFILE:-compat}" in
    "" | compat | default) printf 'compat' ;;
    untrusted) printf 'untrusted' ;;
    strict) printf 'strict' ;;
    *)
      log_err "CAPBOX_SECURITY_PROFILE 只能是 compat|untrusted|strict（当前: ${CAPBOX_SECURITY_PROFILE}）"
      return 2
      ;;
  esac
}

_security_is_hardened() {
  case "$(_security_profile 2>/dev/null || echo compat)" in
    untrusted | strict) return 0 ;;
    *) return 1 ;;
  esac
}

_security_seccomp_py() {
  local cands=(
    "${CAPBOX_LIB_DIR:-}/seccomp-gen.py"
    "${_CAPBOX_TEMPLATE_DIR:-}/lib/seccomp-gen.py"
    "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/seccomp-gen.py"
  )
  local p
  for p in "${cands[@]}"; do
    [[ -n "$p" && -f "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

_security_bpf_path() {
  local profile="${1:-untrusted}"
  printf '%s/seccomp-%s.bpf' "${CAPBOX_STATE_DIR:-$CAPBOX_DIR/state}" "$profile"
}

# 生成（或复用）BPF；成功时把绝对路径打到 stdout
_security_ensure_bpf() {
  local profile="${1:-}"
  case "$profile" in
    untrusted | strict) ;;
    *) return 1 ;;
  esac
  have_cmd python3 || {
    log_err "安全档 $profile 需要 python3 + libseccomp 生成 seccomp BPF"
    return 5
  }
  local py out
  py="$(_security_seccomp_py)" || {
    log_err "缺少 lib/seccomp-gen.py"
    return 5
  }
  mkdir -p "${CAPBOX_STATE_DIR:-$CAPBOX_DIR/state}" 2>/dev/null || true
  out="$(_security_bpf_path "$profile")"
  # 源比产物新或产物空则重建
  if [[ -s "$out" && "$out" -nt "$py" ]]; then
    printf '%s' "$out"
    return 0
  fi
  if ! python3 "$py" --profile "$profile" --out "$out" 2>"${CAPBOX_STATE_DIR:-/tmp}/seccomp-gen.err"; then
    log_err "seccomp BPF 生成失败（见 ${CAPBOX_STATE_DIR:-/tmp}/seccomp-gen.err）；拒绝伪实现"
    return 5
  fi
  [[ -s "$out" ]] || {
    log_err "seccomp BPF 为空，拒绝继续"
    return 5
  }
  printf '%s' "$out"
  return 0
}

# 默认敏感宿主路径：绝不 bind 进容器（compat 下本来也不 bind；此处作显式清单与负向测试用）
_security_default_hidden_host_paths() {
  printf '%s\n' \
    /home /root /var/run/docker.sock /run/docker.sock \
    /etc/shadow /etc/gshadow /etc/sudoers /etc/ssh \
    /proc/sys/kernel/core_pattern
}

# untrusted/strict 默认遮盖工作区内的敏感相对路径（tmpfs 盖住）
_security_default_workspace_hides() {
  printf '%s\n' \
    .ssh .gnupg .aws .azure .kube .docker \
    .capbox/cache/secrets .capbox/secrets
}

# 向 bwrap 参数数组追加安全档相关项（名字传递）
# 用法: _security_append_bwrap_args ARR_NAME
# 副作用：设置 CAPBOX_SECURITY_SECCOMP_FD / CAPBOX_SECURITY_BPF（供调用方保持 FD）
_security_append_bwrap_args() {
  local -n _sec_arr="$1"
  local profile
  profile="$(_security_profile)" || return $?

  _sec_arr+=(--setenv CAPBOX_SECURITY_PROFILE "$profile")

  case "$profile" in
    compat)
      # 保持历史：--cap-add ALL（由 build_bwrap_args 添加）；无 seccomp
      return 0
      ;;
  esac

  # ---- capability：先 ALL 再显式 drop 危险项（bwrap 语义）----
  # build_bwrap_args 会先加 --cap-add ALL；我们在其后追加 --cap-drop
  local -a drops=(
    CAP_SYS_MODULE CAP_SYS_RAWIO CAP_SYS_BOOT CAP_SYS_NICE
    CAP_SYS_RESOURCE CAP_SYS_TIME CAP_SYS_TTY_CONFIG
    CAP_MAC_ADMIN CAP_MAC_OVERRIDE
    CAP_SYSLOG CAP_WAKE_ALARM CAP_BLOCK_SUSPEND
    CAP_AUDIT_CONTROL CAP_AUDIT_READ CAP_AUDIT_WRITE
    CAP_PERFMON CAP_BPF CAP_CHECKPOINT_RESTORE
  )
  # strict 额外 drop SYS_PTRACE / SYS_ADMIN（可能影响部分服务；属显式档）
  if [[ "$profile" == "strict" ]]; then
    drops+=(CAP_SYS_PTRACE CAP_SYS_PACCT)
    # SYS_ADMIN 保留给部分挂载/服务兼容？strict 下 drop，逼用户用 compat/untrusted
    drops+=(CAP_SYS_ADMIN CAP_NET_ADMIN CAP_NET_RAW)
  else
    # untrusted：保留 CAP_SYS_ADMIN / NET_* 以兼容常见服务，靠 seccomp 挡 mount/module
    drops+=(CAP_SYS_PTRACE)
  fi
  local c
  for c in "${drops[@]}"; do
    _sec_arr+=(--cap-drop "$c")
  done

  # 禁止容器内再开 userns。与 --userns-block-fd 不能同时出现；
  # 真正走 idmap 的那次启动会在注入 block fd 时拿掉这个标志。
  # 探测到 multi 但本次没有 block fd（例如 restricted 早期返回）时必须留着它。
  _sec_arr+=(--disable-userns)
  CAPBOX_SECURITY_DISABLE_USERNS=on

  # 遮盖工作区敏感相对路径
  if declare -F _fsguard_append_default_hides >/dev/null 2>&1; then
    _fsguard_append_default_hides _sec_arr
  else
    local rel guest
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      guest="/workspace/$rel"
      # tmpfs 盖住（路径可不存在）
      _sec_arr+=(--tmpfs "$guest")
    done < <(_security_default_workspace_hides)
  fi

  # strict 的默认只读 rootfs 在挂载决策之前设置（_capbox_apply_profile_rootfs_default）。
  # 这里再写已经来不及：build_bwrap_args 先选 --bind / --overlay。

  # seccomp：真实 BPF，禁止伪实现
  local bpf
  if ! bpf="$(_security_ensure_bpf "$profile")"; then
    return $?
  fi
  # 调用方必须在 bwrap 生命周期内保持 FD；这里只记录路径
  CAPBOX_SECURITY_BPF="$bpf"
  export CAPBOX_SECURITY_BPF
  # 占位：实际 --seccomp FD 由 _security_wrap_argv / run 路径注入
  _sec_arr+=(--setenv CAPBOX_SECURITY_SECCOMP "$profile")

  if declare -F audit_event >/dev/null 2>&1; then
    audit_event security start "profile=$profile" "detail=bpf:$(basename "$bpf")"
  fi
  return 0
}

# 在最终 argv 上注入 --seccomp FD（需保持打开）
# 用法: _security_wrap_argv cmd_array_name
# 通过 CAPBOX_SECURITY_SECCOMP_FD_HOLD 全局保存 FD，避免提前关闭
_security_wrap_argv() {
  local -n _sw_cmd="$1"
  _security_is_hardened || return 0
  local bpf="${CAPBOX_SECURITY_BPF:-}"
  [[ -n "$bpf" && -s "$bpf" ]] || {
    local profile
    profile="$(_security_profile)"
    bpf="$(_security_ensure_bpf "$profile")" || return $?
    CAPBOX_SECURITY_BPF="$bpf"
  }

  # 打开只读 FD
  local fd
  exec {fd}<"$bpf" || {
    log_err "无法打开 seccomp BPF: $bpf"
    return 5
  }
  CAPBOX_SECURITY_SECCOMP_FD_HOLD="$fd"
  export CAPBOX_SECURITY_SECCOMP_FD_HOLD

  # 插入到 bwrap 与首个参数之间：找到 bwrap 位置
  local i bwrap_i=-1
  for (( i = 0; i < ${#_sw_cmd[@]}; i++ )); do
    if [[ "${_sw_cmd[$i]}" == */bwrap || "${_sw_cmd[$i]}" == "bwrap" || "${_sw_cmd[$i]}" == "${CAPBOX_BWRAP:-}" ]]; then
      bwrap_i=$i
      break
    fi
  done
  if (( bwrap_i < 0 )); then
    # 可能被 resources/idmap 包了一层；把 --seccomp 放在整段 argv 靠前、在第一个 -- 之前
    local -a new=()
    local seen_dd=0
    for (( i = 0; i < ${#_sw_cmd[@]}; i++ )); do
      if [[ "${_sw_cmd[$i]}" == "--" && seen_dd -eq 0 ]]; then
        new+=(--seccomp "$fd")
        seen_dd=1
      fi
      new+=("${_sw_cmd[$i]}")
    done
    if (( seen_dd == 0 )); then
      new+=(--seccomp "$fd")
    fi
    _sw_cmd=("${new[@]}")
    return 0
  fi

  local -a new2=("${_sw_cmd[@]:0:bwrap_i+1}" --seccomp "$fd" "${_sw_cmd[@]:bwrap_i+1}")
  _sw_cmd=("${new2[@]}")
  return 0
}

_security_close_fd() {
  if [[ -n "${CAPBOX_SECURITY_SECCOMP_FD_HOLD:-}" ]]; then
    eval "exec ${CAPBOX_SECURITY_SECCOMP_FD_HOLD}<&-" 2>/dev/null || true
    unset CAPBOX_SECURITY_SECCOMP_FD_HOLD
  fi
}

_security_doctor_report() {
  local profile
  profile="$(_security_profile 2>/dev/null || echo compat)"
  case "$profile" in
    compat)
      _doctor_pass "安全档 compat（默认兼容：全量 capability、无 seccomp；不削弱现有行为）"
      _doctor_warn "userns 边界：guest root ≠ 宿主 root；无 seccomp 时攻击面较大，不可信负载请改 CAPBOX_SECURITY_PROFILE=untrusted|strict"
      ;;
    untrusted | strict)
      local py bpf
      if py="$(_security_seccomp_py 2>/dev/null)" && have_cmd python3; then
        if bpf="$(_security_ensure_bpf "$profile" 2>/dev/null)"; then
          local dus="${CAPBOX_SECURITY_DISABLE_USERNS:-}"
          if declare -F _idmap_enabled >/dev/null 2>&1 && _idmap_enabled 2>/dev/null; then
            dus="skipped-idmap"
          fi
          _doctor_pass "安全档 $profile（seccomp BPF=$(basename "$bpf")，capability drop，disable-userns=${dus:-on}）"
          if [[ "$dus" == "skipped-idmap" ]]; then
            _doctor_warn "不可信负载不要和多 UID idmap 一起用：已跳过 --disable-userns，guest 仍可嵌套 user namespace。装包可以开 idmap；跑不可信命令请 CAPBOX_IDMAP=off（或单 UID）后再用 untrusted/strict"
          fi
        else
          _doctor_fail "安全档 $profile 但无法生成 seccomp BPF（拒绝伪实现）"
        fi
      else
        _doctor_fail "安全档 $profile 需要 python3 + lib/seccomp-gen.py + libseccomp"
      fi
      _doctor_pass "userns 边界已记录：harden 降低 guest 攻击面，不声称宿主级隔离"
      ;;
  esac
}

# 负向探针（供测试）：在当前档下尝试危险操作，返回探测结果文本
_security_probe_negative() {
  local out
  out="$(exec_in_guest 'mount -t tmpfs none /mnt 2>&1; echo MOUNT_RC=$?; ls -d /workspace/.ssh 2>&1 | head -1; echo DONE' / 60)" || true
  printf '%s\n' "$out"
}
