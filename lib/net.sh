# shellcheck shell=bash
# =============================================================================
# CapBox - net.sh
# 网络三档：none | restricted | open（host 为 open 的兼容别名）
#
# 强制语义（诚实说明，不假装 bwrap 能做域名过滤）：
#   none       : bwrap --unshare-net。容器内无网络（含出站）。
#   open/host  : 不 unshare-net，共享宿主网络（历史默认行为）。
#   restricted : --unshare-net（切断原始网络）+ 宿主 allowlist HTTP 代理
#                + 在 guest netns 的 loopback 上架 TCP→UNIX 桥。
#                仅尊重 http(s)_proxy 的客户端能出网；原始 TCP/UDP 无路由。
#                前置：python3、nsenter、bwrap --info-fd、非空 CAPBOX_NET_ALLOW。
# =============================================================================

: "${CAPBOX_NET_BRIDGE_PORT:=18787}"

_net_mode() {
  case "${CAPBOX_NET:-open}" in
    none) printf 'none' ;;
    restricted) printf 'restricted' ;;
    open | host | "") printf 'open' ;;
    *) printf 'open' ;;
  esac
}

_net_needs_unshare() {
  case "$(_net_mode)" in
    none | restricted) return 0 ;;
    *) return 1 ;;
  esac
}

_net_proxy_py() {
  local cands=(
    "${CAPBOX_LIB_DIR:-}/net-proxy.py"
    "${_CAPBOX_TEMPLATE_DIR:-}/lib/net-proxy.py"
    "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/net-proxy.py"
  )
  local p
  for p in "${cands[@]}"; do
    [[ -n "$p" && -f "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

_net_dir() {
  printf '%s' "${CAPBOX_RUN_DIR:-$CAPBOX_DIR/run}/net"
}

_net_validate_allowlist() {
  local raw="${1:-}" part
  [[ -n "$raw" ]] || {
    log_err "CAPBOX_NET=restricted 需要非空 CAPBOX_NET_ALLOW（逗号分隔域名或 IP）"
    return 2
  }
  IFS=',' read -r -a _net_allow_parts <<<"$raw"
  local n=0
  for part in "${_net_allow_parts[@]}"; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ -n "$part" ]] || continue
    if [[ ! "$part" =~ ^[A-Za-z0-9._:/\-]+$ ]]; then
      log_err "CAPBOX_NET_ALLOW 含非法字符: $part"
      return 2
    fi
    n=$((n + 1))
  done
  (( n > 0 )) || {
    log_err "CAPBOX_NET_ALLOW 解析后为空"
    return 2
  }
  return 0
}

# 检查 restricted 前置条件；成功打印一行摘要到 stdout，失败返回非 0 并 log_err
_net_restricted_prereqs() {
  local miss=() py
  have_cmd python3 || miss+=("python3")
  have_cmd nsenter || miss+=("nsenter(util-linux)")
  [[ -x "${CAPBOX_BWRAP:-}" ]] || miss+=("bwrap")
  py="$(_net_proxy_py 2>/dev/null || true)"
  [[ -n "$py" ]] || miss+=("lib/net-proxy.py")
  if [[ ${#miss[@]} -gt 0 ]]; then
    log_err "CAPBOX_NET=restricted 缺少前置: ${miss[*]}"
    return 5
  fi
  _net_validate_allowlist "${CAPBOX_NET_ALLOW:-}" || return 2
  printf 'python3+nsenter+allowlist'
  return 0
}

# 向 bwrap 参数数组追加网络相关项（名字传递数组）
# 用法: _net_append_bwrap_args ARR_NAME
_net_append_bwrap_args() {
  local -n _nb_arr="$1"
  local mode
  mode="$(_net_mode)"
  case "$mode" in
    none)
      _nb_arr+=(--unshare-net)
      ;;
    restricted)
      _nb_arr+=(--unshare-net)
      # 工作区已 RW bind；run/net 在工作区内，guest 可见 ready 文件
      local nd
      nd="$(_net_dir)"
      mkdir -p "$nd" 2>/dev/null || true
      # 强制代理环境：只有走桥接端口才能出站
      local px="http://127.0.0.1:${CAPBOX_NET_BRIDGE_PORT}"
      local np="localhost,127.0.0.1,::1,*.local"
      _nb_arr+=(--setenv http_proxy "$px")
      _nb_arr+=(--setenv https_proxy "$px")
      _nb_arr+=(--setenv all_proxy "$px")
      _nb_arr+=(--setenv HTTP_PROXY "$px")
      _nb_arr+=(--setenv HTTPS_PROXY "$px")
      _nb_arr+=(--setenv ALL_PROXY "$px")
      _nb_arr+=(--setenv no_proxy "$np")
      _nb_arr+=(--setenv NO_PROXY "$np")
      _nb_arr+=(--setenv CAPBOX_NET restricted)
      _nb_arr+=(--setenv CAPBOX_NET_BRIDGE "127.0.0.1:${CAPBOX_NET_BRIDGE_PORT}")
      ;;
    open)
      # 共享宿主网络；若用户另配了 CAPBOX_PROXY，由 build_bwrap_args 其它逻辑处理
      ;;
  esac
}

# 启动宿主 unix 代理；写出 pid/sock/ready 到 net 目录
_net_start_host_proxy() {
  local nd py sock ready pidf
  nd="$(_net_dir)"
  mkdir -p "$nd"
  py="$(_net_proxy_py)" || return 5
  sock="$nd/proxy.sock"
  ready="$nd/proxy.ready"
  pidf="$nd/proxy.pid"
  rm -f "$sock" "$ready" "$pidf" 2>/dev/null || true
  _net_validate_allowlist "${CAPBOX_NET_ALLOW:-}" || return 2
  # 后台代理
  nohup python3 "$py" proxy --sock "$sock" --allow "$CAPBOX_NET_ALLOW" --ready "$ready" \
    ${CAPBOX_DEBUG:+--log} >>"$nd/proxy.log" 2>&1 &
  echo $! >"$pidf"
  local i
  for i in $(seq 1 50); do
    [[ -S "$sock" && -f "$ready" ]] && return 0
    if ! kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
      log_err "restricted 代理进程退出，见 $nd/proxy.log"
      return 1
    fi
    sleep 0.05
  done
  log_err "restricted 代理启动超时"
  return 1
}

_net_stop_host_proxy() {
  local nd pidf pid
  nd="$(_net_dir)"
  pidf="$nd/proxy.pid"
  if [[ -f "$pidf" ]]; then
    pid="$(cat "$pidf" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pidf"
  fi
  rm -f "$nd/proxy.sock" "$nd/proxy.ready" 2>/dev/null || true
}

_net_stop_bridge() {
  local nd pidf pid
  nd="$(_net_dir)"
  pidf="$nd/bridge.pid"
  if [[ -f "$pidf" ]]; then
    pid="$(cat "$pidf" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pidf"
  fi
  rm -f "$nd/bridge.ready" "$nd/go" 2>/dev/null || true
}

# 在 guest netns 内启动 lo + TCP 桥
_net_start_bridge_for_child() {
  local child="${1:-}"
  local nd py sock ready pidf
  [[ -n "$child" && -r "/proc/$child/ns/net" && -r "/proc/$child/ns/user" ]] || {
    log_err "无法进入容器 netns（child=$child）"
    return 1
  }
  nd="$(_net_dir)"
  py="$(_net_proxy_py)" || return 5
  sock="$nd/proxy.sock"
  ready="$nd/bridge.ready"
  pidf="$nd/bridge.pid"
  rm -f "$ready" "$pidf" 2>/dev/null || true
  [[ -S "$sock" ]] || {
    log_err "代理 sock 不存在: $sock"
    return 1
  }
  # 不带 -t：配合 --preserve-credentials 进入 user+net ns
  nohup nsenter --user="/proc/$child/ns/user" --net="/proc/$child/ns/net" --preserve-credentials -- \
    /bin/sh -c "
      ip link set lo up 2>/dev/null || ifconfig lo up 2>/dev/null || true
      exec python3 $(printf %q "$py") bridge --listen 127.0.0.1:${CAPBOX_NET_BRIDGE_PORT} --sock $(printf %q "$sock") --ready $(printf %q "$ready")
    " >>"$nd/bridge.log" 2>&1 &
  echo $! >"$pidf"
  local i
  for i in $(seq 1 50); do
    [[ -f "$ready" ]] && return 0
    if ! kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
      log_err "restricted 桥接进程退出，见 $nd/bridge.log"
      return 1
    fi
    sleep 0.05
  done
  log_err "restricted 桥接启动超时"
  return 1
}

# 以 restricted 模式运行 bwrap 命令（argv 在 "$@"，已含 bwrap 与参数，末尾是 -- cmd...）
# 更常用的入口是 _net_run_bwrap_oneshot
_net_cleanup_restricted_session() {
  _net_stop_bridge
  _net_stop_host_proxy
}

# run_bwrap_oneshot 的 restricted 实现：cwd timeout cmd...
_net_run_bwrap_oneshot() {
  local cwd="${1:-/workspace}"
  local to="${2:-0}"
  shift 2 || true
  [[ $# -gt 0 ]] || die 2 "_net_run_bwrap_oneshot: 缺少命令"

  _net_restricted_prereqs >/dev/null || return $?

  local nd info go guest_go
  nd="$(_net_dir)"
  mkdir -p "$nd"
  info="$nd/info-$$.json"
  go="$nd/go-$$"
  rm -f "$info" "$go" 2>/dev/null || true
  guest_go="$(_guest_workspace_path "$go")"
  [[ -n "$guest_go" ]] || guest_go="/workspace/.capbox/run/net/$(basename "$go")"

  _net_start_host_proxy || return 1
  # 注意：用固定清理函数，避免 trap 捕获过期路径
  _CAPBOX_NET_TMP_INFO="$info"
  _CAPBOX_NET_TMP_GO="$go"
  trap '_net_cleanup_restricted_session; rm -f -- "${_CAPBOX_NET_TMP_INFO:-}" "${_CAPBOX_NET_TMP_GO:-}" 2>/dev/null || true' RETURN

  local -a args=() wrap_cmd=()
  mapfile -t args < <(build_bwrap_args oneshot "$cwd")
  (( ${#args[@]} > 0 )) || die 4 "无法构造 bwrap 参数"

  # 等宿主写入 go 文件（位于工作区 bind 内）后再 exec 原 argv
  wrap_cmd=(
    "$CAPBOX_BWRAP" --info-fd 3 "${args[@]}"
    -- /bin/sh -c
    'while [ ! -f "$1" ]; do sleep 0.05; done; shift; exec "$@"'
    sh
    "$guest_go"
    "$@"
  )

  if declare -F _resources_wrap_argv >/dev/null 2>&1; then
    _resources_wrap_argv wrap_cmd || true
  fi

  local rc=0 child="" bp
  if (( to > 0 )) && have_cmd timeout; then
    timeout --kill-after=5 "$to" "${wrap_cmd[@]}" 3>"$info" &
  else
    "${wrap_cmd[@]}" 3>"$info" &
  fi
  bp=$!

  local i
  for i in $(seq 1 100); do
    if [[ -s "$info" ]]; then
      child="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("child-pid",""))' "$info" 2>/dev/null || true)"
      [[ -n "$child" ]] && break
    fi
    kill -0 "$bp" 2>/dev/null || break
    sleep 0.05
  done
  if [[ -z "$child" ]]; then
    log_err "restricted：未能从 bwrap --info-fd 取得 child-pid"
    kill "$bp" 2>/dev/null || true
    wait "$bp" 2>/dev/null || true
    return 1
  fi

  if ! _net_start_bridge_for_child "$child"; then
    kill "$bp" 2>/dev/null || true
    wait "$bp" 2>/dev/null || true
    return 1
  fi

  : >"$go"
  wait "$bp"
  rc=$?
  rm -f "$info" "$go" 2>/dev/null || true
  return "$rc"
}

# doctor 用的网络项报告
_net_doctor_report() {
  local mode
  mode="$(_net_mode)"
  case "$mode" in
    none)
      _doctor_pass "网络模式 none（--unshare-net，容器内无网络）"
      ;;
    open)
      _doctor_pass "网络模式 open（共享宿主网络；兼容别名 host）"
      ;;
    restricted)
      local pre
      if pre="$(_net_restricted_prereqs 2>/dev/null)"; then
        _doctor_pass "网络模式 restricted（unshare-net + allowlist 代理；$pre；ALLOW=${CAPBOX_NET_ALLOW})"
      else
        _doctor_warn "网络模式 restricted 但前置未满足（需要 python3、nsenter、非空 CAPBOX_NET_ALLOW）；exec 将失败"
      fi
      ;;
  esac
}
