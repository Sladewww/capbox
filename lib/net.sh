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
      log_err "CAPBOX_NET 只能是 none / restricted / open（host 为 open 的别名；当前: '${CAPBOX_NET}'）。拒绝回退到 open"
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
  printf '%s' "${CAPBOX_RUN_DIR:-$CAPBOX_DIR/run}/net"
}

# oneshot 与 daemon 使用不同的 sock/pid，避免一次性 exec 的清理杀掉常驻代理。
_net_session_tag() {
  local tag="${CAPBOX_NET_SESSION:-oneshot}"
  case "$tag" in
    daemon) printf 'daemon' ;;
    svc-*)
      tag="$(printf '%s' "$tag" | tr -c 'A-Za-z0-9_-' '-')"
      printf '%s' "$tag"
      ;;
    *) printf 'oneshot' ;;
  esac
}

_net_proxy_sock() { printf '%s/%s-proxy.sock' "$(_net_dir)" "$(_net_session_tag)"; }
_net_proxy_ready() { printf '%s/%s-proxy.ready' "$(_net_dir)" "$(_net_session_tag)"; }
_net_proxy_pidf() { printf '%s/%s-proxy.pid' "$(_net_dir)" "$(_net_session_tag)"; }
_net_proxy_log() { printf '%s/%s-proxy.log' "$(_net_dir)" "$(_net_session_tag)"; }
_net_bridge_ready() { printf '%s/%s-bridge.ready' "$(_net_dir)" "$(_net_session_tag)"; }
_net_bridge_pidf() { printf '%s/%s-bridge.pid' "$(_net_dir)" "$(_net_session_tag)"; }
_net_bridge_log() { printf '%s/%s-bridge.log' "$(_net_dir)" "$(_net_session_tag)"; }

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
    if [[ ! "$part" =~ ^[A-Za-z0-9._:/*-]+$ ]]; then
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
  mode="$(_net_mode)" || return $?
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
  sock="$(_net_proxy_sock)"
  ready="$(_net_proxy_ready)"
  pidf="$(_net_proxy_pidf)"
  rm -f "$sock" "$ready" "$pidf" 2>/dev/null || true
  _net_validate_allowlist "${CAPBOX_NET_ALLOW:-}" || return 2
  # 后台代理
  nohup python3 "$py" proxy --sock "$sock" --allow "$CAPBOX_NET_ALLOW" --ready "$ready" \
    ${CAPBOX_DEBUG:+--log} >>"$(_net_proxy_log)" 2>&1 &
  echo $! >"$pidf"
  local i
  for i in $(seq 1 50); do
    [[ -S "$sock" && -f "$ready" ]] && return 0
    if ! kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
      log_err "restricted 代理进程退出，见 $(_net_proxy_log)"
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
  nd="$(_net_dir)"
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
    log_err "无法进入容器 netns（child=$child）"
    return 1
  }
  nd="$(_net_dir)"
  py="$(_net_proxy_py)" || return 5
  sock="$(_net_proxy_sock)"
  ready="$(_net_bridge_ready)"
  pidf="$(_net_bridge_pidf)"
  rm -f "$ready" "$pidf" 2>/dev/null || true
  [[ -S "$sock" ]] || {
    log_err "代理 sock 不存在: $sock"
    return 1
  }
  # 不带 -t：配合 --preserve-credentials 进入 user+net ns。
  # bwrap 在放行后用 NLM_F_EXCL 添加 127.0.0.1。这里不能先改 lo，否则地址已存在，
  # RTM_NEWADDR 失败（报错里的 errno 经常是残留值，看起来像 No child processes）。
  nohup nsenter --user="/proc/$child/ns/user" --net="/proc/$child/ns/net" --preserve-credentials -- \
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
      log_err "restricted 桥接进程退出，见 $(_net_bridge_log)"
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
  log_err "restricted：argv 里没有 bwrap，无法注入 --info-fd"
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
  mode="$(_net_mode)" || {
    _doctor_fail "CAPBOX_NET 非法（${CAPBOX_NET:-}）；拒绝当作 open"
    return
  }
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
  log_err "PUBLISH 项非法（期望 HOST:GUEST 或 HOST:IP:GUEST）: $item"
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
    log_info "PUBLISH=$raw：NET=open 共享宿主网络，guest 端口已在宿主可见（无额外转发；不声称出站过滤）"
    return 0
  fi

  have_cmd python3 || { log_err "PUBLISH 在 none/restricted 下需要 python3"; return 5; }
  have_cmd nsenter || { log_err "PUBLISH 在 none/restricted 下需要 nsenter"; return 5; }

  local item pyf
  pyf="$pd/forward.py"
  cat >"$pyf" <<'PYF'
#!/usr/bin/env python3
import os, sys, time, socket, select, subprocess, threading
host_port=int(sys.argv[1]); guest_addr=sys.argv[2]; guest_port=int(sys.argv[3])
child_pid_file=sys.argv[4]; ready_file=sys.argv[5]

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
    raise SystemExit("publish: child netns not ready")

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
        # Dial guest from inside its netns; shuttle bytes via stdio of nsenter helper
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
            ["nsenter", f"--net=/proc/{child}/ns/net", "--preserve-credentials", "--",
             "python3", "-c", helper],
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
    child_pid_file="${CAPBOX_RUN_DIR}/services/${name}/supervisor.pid.child"
    rm -f "$ready"
    nohup python3 "$pyf" "$_pub_host_port" "$_pub_guest_addr" "$_pub_guest_port" "$child_pid_file" "$ready" \
      >>"$pd/forward.log" 2>&1 &
    echo $! >"$pidf"
    local j
    for j in $(seq 1 80); do
      [[ -f "$ready" ]] && break
      kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null || {
        log_warn "PUBLISH forwarder 尚未就绪（可能仍在等服务 netns）；见 $pd/forward.log"
        break
      }
      sleep 0.05
    done
    log_info "PUBLISH 127.0.0.1:${_pub_host_port} → guest ${_pub_guest_addr}:${_pub_guest_port}"
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
