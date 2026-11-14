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
    *)
      i18n_err config.capbox_net_must_none_restricted_open_host_2 net="${CAPBOX_NET}"
      return 2
      ;;
  esac
}

_net_needs_unshare() {
  local mode
  # 模式非法时按需要隔离处理（失败即关闭），调用方仍应先看 _net_mode 的退出码。
  mode="$(_net_mode)" || return 0
  case "$mode" in
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
  local private
  private="$(_capbox_host_state_dir)" || return 1
  printf '%s/net' "$private"
}

_net_shared_dir() { local nd; nd="$(_net_dir)" || return 1; printf '%s/shared' "$nd"; }

_net_guest_path() {
  local shared
  shared="$(_net_shared_dir)" || return 1
  case "$1" in "$shared"/*) printf '/run/capbox-net/%s' "${1##*/}" ;; *) return 1 ;; esac
}

# 仅宿主写入的就绪信号对 guest 可见；绝不暴露 argv/PID/socket。
_net_append_ready_bind() {
  local -n _ready_args="$1"
  [[ "$(_net_mode)" == restricted ]] || return 0
  local shared
  shared="$(_net_shared_dir)" || return 1
  mkdir -p "$shared" || return 1
  _ready_args+=(--ro-bind "$shared" /run/capbox-net)
}

# oneshot 与 daemon 使用不同的 sock/pid，避免一次性 exec 的清理杀掉常驻代理。
_net_session_tag() {
  local tag="${CAPBOX_NET_SESSION:-oneshot}"
  case "$tag" in
    daemon) printf 'daemon' ;;
    task-*)
      if [[ "$tag" =~ ^task-[0-9a-f]{32}$ ]]; then printf '%s' "$tag"
      else printf 'oneshot'; fi
      ;;
    svc-*)
      tag="$(printf '%s' "$tag" | tr -c 'A-Za-z0-9_-' '-')"
      printf '%s' "$tag"
      ;;
    *) printf 'oneshot' ;;
  esac
}

_net_proxy_sock() {
  local nd key
  nd="$(_net_dir)" || return 1
  key="$(printf '%s' "$(_net_session_tag)" | sha256sum)" || return 1
  printf '%s/%s.sock' "$nd" "${key:0:32}"
}
_net_proxy_ready() { printf '%s/%s-proxy.ready' "$(_net_dir)" "$(_net_session_tag)"; }
_net_proxy_pidf() { printf '%s/%s-proxy.pid' "$(_net_dir)" "$(_net_session_tag)"; }
_net_proxy_log() { printf '%s/%s-proxy.log' "$(_net_dir)" "$(_net_session_tag)"; }
_net_bridge_ready() { printf '%s/%s-bridge.ready' "$(_net_shared_dir)" "$(_net_session_tag)"; }
_net_bridge_pidf() { printf '%s/%s-bridge.pid' "$(_net_dir)" "$(_net_session_tag)"; }
_net_bridge_log() { printf '%s/%s-bridge.log' "$(_net_dir)" "$(_net_session_tag)"; }

_net_validate_allowlist() {
  local raw="${1:-}" part
  [[ -n "$raw" ]] || {
    i18n_err net.capbox_net_restricted_requires_non_empty_capbox
    return 2
  }
  IFS=',' read -r -a _net_allow_parts <<<"$raw"
  local n=0
  for part in "${_net_allow_parts[@]}"; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ -n "$part" ]] || continue
    if [[ ! "$part" =~ ^[A-Za-z0-9._:/*-]+$ ]]; then
      i18n_err net.capbox_net_allow_contains_illegal_characters part="$part"
      return 2
    fi
    n=$((n + 1))
  done
  (( n > 0 )) || {
    i18n_err net.capbox_net_allow_empty_after_parsing
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
    i18n_err net.capbox_net_restricted_missing_prerequisites miss="${miss[*]}"
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
  mode="$(_net_mode)" || return $?
  case "$mode" in
    none)
      _nb_arr+=(--unshare-net)
      ;;
    restricted)
      _nb_arr+=(--unshare-net)
      # 工作区已 RW bind；run/net 在工作区内，guest 可见 ready 文件
      local nd
      nd="$(_net_dir)" || return 1
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
  nd="$(_net_dir)" || return 1
  mkdir -p "$nd"
  mkdir -p "$(_net_shared_dir)" || return 1
  py="$(_net_proxy_py)" || return 5
  sock="$(_net_proxy_sock)"
  ready="$(_net_proxy_ready)"
  pidf="$(_net_proxy_pidf)"
  rm -f "$sock" "$ready" "$pidf" 2>/dev/null || true
  _net_validate_allowlist "${CAPBOX_NET_ALLOW:-}" || return 2
  if declare -F _credentials_prepare_restricted >/dev/null 2>&1; then
    _credentials_prepare_restricted || return $?
  fi
  # 后台代理（inject map 仅宿主可读，不挂进 guest）
  local inject_args=()
  if [[ -n "${_audit_task_id:-}" ]] && _audit_enabled; then
    inject_args+=(--audit-path "$_audit_task_path" --task-id "$_audit_task_id")
  fi
  if [[ -n "${CAPBOX_CRED_INJECT_MAP:-}" && -f "${CAPBOX_CRED_INJECT_MAP}" ]]; then
    inject_args+=(--inject-map "${CAPBOX_CRED_INJECT_MAP}")
  fi
  nohup python3 "$py" proxy --sock "$sock" --allow "$CAPBOX_NET_ALLOW" --ready "$ready" \
    "${inject_args[@]}" ${CAPBOX_DEBUG:+--log} >>"$(_net_proxy_log)" 2>&1 &
  echo $! >"$pidf"
  local i
  for i in $(seq 1 50); do
    [[ -S "$sock" && -f "$ready" ]] && return 0
    if ! kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
      i18n_err net.restricted_proxy_process_exited_see path="$(_net_proxy_log)"
      return 1
    fi
    sleep 0.05
  done
  i18n_err net.restricted_proxy_start_timed_out
  return 1
}

_net_stop_host_proxy() {
  local nd pidf pid
  nd="$(_net_dir)" || return 1
  pidf="$(_net_proxy_pidf)"
  if [[ -f "$pidf" ]]; then
    pid="$(cat "$pidf" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pidf"
  fi
  rm -f "$(_net_proxy_sock)" "$(_net_proxy_ready)" 2>/dev/null || true
}

_net_stop_bridge() {
  local nd pidf pid
  nd="$(_net_dir)" || return 1
  pidf="$(_net_bridge_pidf)"
  if [[ -f "$pidf" ]]; then
    pid="$(cat "$pidf" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pidf"
  fi
  rm -f "$(_net_bridge_ready)" "$nd/go" 2>/dev/null || true
}

# 在 guest netns 内启动 lo + TCP 桥
_net_start_bridge_for_child() {
  local child="${1:-}"
  local nd py sock ready pidf
  [[ -n "$child" && -r "/proc/$child/ns/net" && -r "/proc/$child/ns/user" ]] || {
    i18n_err net.unable_enter_container_netns_child child="$child"
    return 1
  }
  nd="$(_net_dir)" || return 1
  py="$(_net_proxy_py)" || return 5
  sock="$(_net_proxy_sock)"
  ready="$(_net_bridge_ready)"
  pidf="$(_net_bridge_pidf)"
  rm -f "$ready" "$pidf" 2>/dev/null || true
  [[ -S "$sock" ]] || {
    i18n_err net.proxy_sock_does_not_exist sock="$sock"
    return 1
  }
  # 不带 -t：配合 --preserve-credentials 进入 user+net ns。
  # bwrap 在放行后用 NLM_F_EXCL 添加 127.0.0.1。这里不能先改 lo，否则地址已存在，
  # RTM_NEWADDR 失败（报错里的 errno 经常是残留值，看起来像 No child processes）。
  nohup python3 "$py" enter-net --child "$child" -- \
    /bin/sh -c "
      i=0
      while [ \"\$i\" -lt 200 ]; do
        if ip -4 addr show dev lo 2>/dev/null | grep -q 127.0.0.1; then
          break
        fi
        i=\$((i+1))
        sleep 0.02
      done
      ip -4 addr show dev lo 2>/dev/null | grep -q 127.0.0.1 || exit 1
      ip link set lo up 2>/dev/null || ifconfig lo up 2>/dev/null || true
      exec python3 $(printf %q "$py") bridge --listen 127.0.0.1:${CAPBOX_NET_BRIDGE_PORT} --sock $(printf %q "$sock") --ready $(printf %q "$ready")
    " >>"$(_net_bridge_log)" 2>&1 &
  echo $! >"$pidf"
  local i
  for i in $(seq 1 50); do
    [[ -f "$ready" ]] && return 0
    if ! kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
      i18n_err net.restricted_bridge_process_exited_see path="$(_net_bridge_log)"
      return 1
    fi
    sleep 0.05
  done
  i18n_err net.restricted_bridge_start_timed_out
  return 1
}

# 以 restricted 模式运行 bwrap 命令（argv 在 "$@"，已含 bwrap 与参数，末尾是 -- cmd...）
# 更常用的入口是 _net_run_bwrap_oneshot
_net_cleanup_restricted_session() {
  _net_stop_bridge
  _net_stop_host_proxy
}

# 在 bwrap 参数数组里、紧跟 bwrap 可执行文件之后插入 --info-fd。
_net_inject_bwrap_info_fd() {
  local -n _inf="$1"
  local fd="${2:-3}"
  local i
  for (( i = 0; i < ${#_inf[@]}; i++ )); do
    if [[ "${_inf[$i]}" == */bwrap || "${_inf[$i]}" == "bwrap" || "${_inf[$i]}" == "${CAPBOX_BWRAP:-}" ]]; then
      _inf=("${_inf[@]:0:i+1}" --info-fd "$fd" "${_inf[@]:i+1}")
      return 0
    fi
  done
  i18n_err net.restricted_argv_has_no_bwrap_cannot_inject
  return 1
}

_net_child_pid_from_info() {
  local info="${1:-}"
  [[ -s "$info" ]] || return 1
  python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("child-pid") or "")
except Exception:
    print("")' "$info" 2>/dev/null
}

# 等到 bwrap --info-fd 写出 child-pid。成功时打印 pid。
_net_wait_info_child() {
  local info="${1:-}" bp="${2:-}"
  local i child=""
  for i in $(seq 1 100); do
    if [[ -s "$info" ]]; then
      child="$(_net_child_pid_from_info "$info" || true)"
      if [[ -n "$child" ]]; then
        printf '%s' "$child"
        return 0
      fi
    fi
    if [[ -n "$bp" ]] && ! kill -0 "$bp" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  return 1
}

# run_bwrap_oneshot 的 restricted 实现：cwd timeout cmd...
_net_run_bwrap_oneshot() {
  local cwd="${1:-/workspace}"
  local to="${2:-0}"
  shift 2 || true
  [[ $# -gt 0 ]] || i18n_die 2 net.net_run_bwrap_oneshot_missing_command

  _net_restricted_prereqs >/dev/null || return $?

  local nd info go guest_go
  nd="$(_net_dir)" || return 1
  mkdir -p "$nd"
  info="$nd/info-$$.json"
  go="$(_net_shared_dir)/go-$$"
  rm -f "$info" "$go" 2>/dev/null || true
  guest_go="$(_net_guest_path "$go")" || return 1

  _net_start_host_proxy || return 1
  # 注意：用固定清理函数，避免 trap 捕获过期路径
  _CAPBOX_NET_TMP_INFO="$info"
  _CAPBOX_NET_TMP_GO="$go"
  trap '_net_cleanup_restricted_session; rm -f -- "${_CAPBOX_NET_TMP_INFO:-}" "${_CAPBOX_NET_TMP_GO:-}" 2>/dev/null || true' RETURN

  if [[ -z "${CAPBOX_BWRAP_BASELINE_CMD:-}" ]]; then
    CAPBOX_BWRAP_BASELINE_CMD="$*"
  fi

  local -a args=() wrap_cmd=()
  local _bbrc=0
  mapfile -t args < <(build_bwrap_args oneshot "$cwd"; printf 'CAPBOX_BWRAP_ARGS_RC=%s\n' "$?")
  if [[ ${#args[@]} -gt 0 && "${args[-1]}" == CAPBOX_BWRAP_ARGS_RC=* ]]; then
    _bbrc="${args[-1]#CAPBOX_BWRAP_ARGS_RC=}"
    unset 'args[-1]'
  fi
  if (( _bbrc == 6 )); then
    die 6
  fi
  if (( _bbrc != 0 )); then
    i18n_die "$_bbrc" common.unable_build_bwrap_arguments_rc_common_causes _bbrc="$_bbrc"
  fi
  (( ${#args[@]} > 0 )) || i18n_die 4 net.unable_build_bwrap_arguments

  # 等宿主写入 go 文件（位于工作区 bind 内）后再 exec 原 argv。
  # --info-fd 只在非 idmap 路径注入：idmap 自己用 fd 4，两套 info-fd 会冲突。
  wrap_cmd=(
    "$CAPBOX_BWRAP" "${args[@]}"
    -- /bin/sh -c
    'while [ ! -f "$1" ]; do sleep 0.05; done; shift; exec "$@"'
    sh
    "$guest_go"
    "$@"
  )

  if declare -F _resources_wrap_argv >/dev/null 2>&1; then
    _resources_wrap_argv wrap_cmd || return $?
  fi
  if declare -F _security_wrap_argv >/dev/null 2>&1; then
    _security_wrap_argv wrap_cmd || return $?
  fi
  if declare -F _landlock_apply_argv >/dev/null 2>&1; then
    _landlock_apply_argv wrap_cmd || return $?
  fi

  local idmap_rc=1
  if declare -F _capbox_idmap_decision >/dev/null 2>&1; then
    _capbox_idmap_decision
    idmap_rc=$?
  fi
  if (( idmap_rc == 2 )); then
    return 1
  fi
  if (( idmap_rc == 0 )); then
    _idmap_after_map_hook() {
      _net_start_bridge_for_child "$1" || return $?
      : >"$go"
      return 0
    }
    local rc=0
    _idmap_run_bwrap_argv "${wrap_cmd[@]}"
    rc=$?
    rm -f "$info" "$go" 2>/dev/null || true
    return "$rc"
  fi

  _net_inject_bwrap_info_fd wrap_cmd 3 || return 1

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
    i18n_err net.restricted_failed_get_child_pid_bwrap_info
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
  mode="$(_net_mode)" || {
    _doctor_fail_i18n doctor.net_invalid value="${CAPBOX_NET:-}"
    return
  }
  case "$mode" in
    none)
      _doctor_pass_i18n doctor.net_mode_none
      ;;
    open)
      _doctor_pass_i18n doctor.net_mode_open
      ;;
    restricted)
      local pre
      if pre="$(_net_restricted_prereqs 2>/dev/null)"; then
        _doctor_pass_i18n doctor.net_mode_restricted_ok pre="$pre" allow="${CAPBOX_NET_ALLOW}"
      else
        _doctor_warn_i18n doctor.net_mode_restricted_prereq
      fi
      ;;
  esac
}



# ---------- 端口发布 / 转发 --------------------------------------------------
# PUBLISH=hostPort:guestPort[,...] 或 hostPort:IP:guestPort
# open：共享宿主网络，guest bind 已在宿主可见 — 只记录，不做转发，不声称过滤。
# none/restricted：宿主监听 hostPort，经 nsenter 进入服务 netns 拨到 guest 地址。

_net_publish_dir() { printf '%s/publish' "$(_net_dir)"; }

_net_parse_publish_item() {
  local item="${1:-}"
  _pub_host_port="" _pub_guest_addr="127.0.0.1" _pub_guest_port=""
  if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
    _pub_host_port="${BASH_REMATCH[1]}"; _pub_guest_port="${BASH_REMATCH[2]}"; return 0
  fi
  if [[ "$item" =~ ^([0-9]+):([0-9.]+):([0-9]+)$ ]]; then
    _pub_host_port="${BASH_REMATCH[1]}"; _pub_guest_addr="${BASH_REMATCH[2]}"; _pub_guest_port="${BASH_REMATCH[3]}"; return 0
  fi
  i18n_err net.invalid_publish_entry_expected_host_guest_host item="$item"
  return 2
}

_net_publish_start() {
  local name="${1:-}" raw="${2:-}"
  [[ -n "$raw" ]] || return 0
  local mode pd
  mode="$(_net_mode)"
  pd="$(_net_publish_dir)/$name"
  mkdir -p "$pd"
  printf '%s\n' "$raw" >"$pd/spec"
  printf '%s\n' "$mode" >"$pd/mode"

  if [[ "$mode" == "open" ]]; then
    i18n_info net.publish_net_open_shares_host_network_so raw="$raw"
    return 0
  fi

  have_cmd python3 || { i18n_err net.publish_under_none_restricted_requires_python3; return 5; }
  have_cmd nsenter || { i18n_err net.publish_under_none_restricted_requires_nsenter; return 5; }

  local item pyf
  pyf="$pd/forward.py"
  cat >"$pyf" <<'PYF'
#!/usr/bin/env python3
import os, sys, time, socket, select, subprocess, threading
host_port=int(sys.argv[1]); guest_addr=sys.argv[2]; guest_port=int(sys.argv[3])
child_pid_file=sys.argv[4]; ready_file=sys.argv[5]
net_helper=sys.argv[6]

def wait_child():
    for _ in range(300):
        if os.path.isfile(child_pid_file):
            try:
                pid=int(open(child_pid_file).read().strip())
                if pid>0 and os.path.exists(f"/proc/{pid}/ns/net"):
                    return pid
            except Exception:
                pass
        time.sleep(0.05)
    raise SystemExit(os.environ.get("CAPBOX_PUBLISH_NETNS_MSG", "publish: child netns is not ready"))

child=wait_child()

def splice(a,b):
    try:
        while True:
            r,_,_=select.select([a,b],[],[],300)
            if not r: return
            for s in r:
                o=b if s is a else a
                d=s.recv(65536)
                if not d: return
                o.sendall(d)
    except Exception:
        pass
    finally:
        for s in (a,b):
            try: s.close()
            except Exception: pass

def handle(client):
    try:
        # 从 guest 自己的 netns 内拨号；经 nsenter 助手的 stdio 搬运字节
        helper = (
            "import socket,sys,os,select\n"
            f"g=socket.create_connection(('{guest_addr}',{guest_port}))\n"
            "h=socket.socket(fileno=0)\n"
            "while True:\n"
            " r,_,_=select.select([g,h],[],[],300)\n"
            " if not r: break\n"
            " for x in r:\n"
            "  y=h if x is g else g\n"
            "  d=x.recv(65536)\n"
            "  if not d: raise SystemExit\n"
            "  y.sendall(d)\n"
        )
        sp_h, sp_c = socket.socketpair()
        proc=subprocess.Popen(
            [sys.executable, net_helper, "enter-net", "--child", str(child), "--",
             sys.executable, "-c", helper],
            stdin=sp_c, stdout=sp_c, stderr=subprocess.DEVNULL,
            pass_fds=(sp_c.fileno(),),
        )
        sp_c.close()
        t=threading.Thread(target=splice, args=(client, sp_h), daemon=True)
        t.start(); t.join(timeout=3600)
        try: proc.kill()
        except Exception: pass
    except Exception:
        try: client.close()
        except Exception: pass

ls=socket.socket(socket.AF_INET, socket.SOCK_STREAM)
ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind(("127.0.0.1", host_port))
ls.listen(64)
open(ready_file,"w").write("ok\n")
while True:
    c,_=ls.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PYF
  chmod +x "$pyf"

  IFS=',' read -r -a _pubs <<<"$raw"
  for item in "${_pubs[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] || continue
    _net_parse_publish_item "$item" || return 2
    local ready pidf child_pid_file
    ready="$pd/ready-${_pub_host_port}"
    pidf="$pd/pid-${_pub_host_port}"
    child_pid_file="$(_service_run_dir "$name")/sandbox.pid"
    rm -f "$ready"
    CAPBOX_PUBLISH_NETNS_MSG="$(i18n_get net.publish_child_netns_not_ready)" \
    nohup python3 "$pyf" "$_pub_host_port" "$_pub_guest_addr" "$_pub_guest_port" "$child_pid_file" "$ready" "$(_net_proxy_py)" \
      >>"$pd/forward.log" 2>&1 &
    echo $! >"$pidf"
    local j
    for j in $(seq 1 80); do
      [[ -f "$ready" ]] && break
      kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null || {
        i18n_warn net.publish_forwarder_not_ready_yet_may_still pd="$pd"
        break
      }
      sleep 0.05
    done
    i18n_info net.publish_127_0_0_1_guest _pub_host_port="${_pub_host_port}" _pub_guest_addr="${_pub_guest_addr}" _pub_guest_port="${_pub_guest_port}"
  done
  return 0
}

_net_publish_stop() {
  local name="${1:-}" pd pidf pid
  pd="$(_net_publish_dir)/$name"
  [[ -d "$pd" ]] || return 0
  for pidf in "$pd"/pid-*; do
    [[ -f "$pidf" ]] || continue
    pid="$(cat "$pidf" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "$pidf"
  done
  return 0
}
