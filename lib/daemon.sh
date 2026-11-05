# shellcheck shell=bash
# =============================================================================
# CapBox —— 常驻容器（daemon 模式）客户端与生命周期
#
# 本文件提供：
#   daemon_running / daemon_info / daemon_request
#   cmd_up / cmd_down / cmd_status / cmd_logs
# 容器内的服务端在 lib/guest/daemon.sh（由本文件在 bwrap 里以 /bin/sh 启动）。
#
# 与他人文件的关系（契约 §4）：
#   * 优先复用 common.sh 的 build_bwrap_args / ensure_rootfs_dirs / log_* / die /
#     refresh_resolv 等；sandbox.sh 的 sandbox_bwrap_cmd 用于构造 bwrap argv。
#   * 这些文件缺失或函数未定义时，本文件用 _daemon_* 私有兜底，**绝不因此崩溃**。
#   * 本文件**不定义 capbox_main**（由 主模块的 bin/capbox 提供），只注册命令函数。
#
# ⚠️ 本文件最反直觉的一条设计（已实测，务必保留）：
#   DSH 的 bash 工具**每次调用都在新的 PID namespace 里**。实测同一会话里先后三次
#   调用得到的 /proc/self/ns/pid 分别是 4026532240 / 4026532245（前台）与
#   4026532237（后台 job），而三者的 $$ 都是 2。因此：
#     - 客户端**无法** kill -0 到守护容器里的 pid（那个 pid 在客户端 ns 里不存在）；
#     - 更糟的是 kill -0 会**误命中**同号的无关进程（实测 kill -0 2 命中的是客户端自己），
#       于是契约 §5 字面上的「kill -0 pid 成功」判据会产生假阳性。
#   结论：活性判据以**共享文件系统上的心跳文件** run/daemon/hb（mtime 新鲜）为准；
#   仅当 daemon.json 记录的 pidns 与当前进程 pidns 相同时，才把 kill -0 当权威。
#   同理 down 无法跨 ns 杀进程，只能靠 ctl/stop 让服务端自己优雅退出。
# =============================================================================

# =============================================================================
# 0. 兜底层：common.sh 缺失时的最小可用实现
# =============================================================================

# ---- 0.1 全局变量 ------------------------------------------------------------

if [[ -z "${CAPBOX_DIR:-}" ]]; then
  _daemon_self="${BASH_SOURCE[0]:-$0}"
  CAPBOX_DIR="$(cd "$(dirname "$_daemon_self")/.." && pwd)"
  unset _daemon_self
fi
: "${CAPBOX_WORKSPACE:=$(dirname "$CAPBOX_DIR")}"
: "${CAPBOX_DISTRO:=alpine}"
: "${CAPBOX_OS_DIR:=$CAPBOX_DIR/os}"
: "${CAPBOX_ROOTFS:=$CAPBOX_OS_DIR/$CAPBOX_DISTRO}"
: "${CAPBOX_STATE_DIR:=$CAPBOX_DIR/state}"
: "${CAPBOX_RUN_DIR:=$CAPBOX_DIR/run}"
: "${CAPBOX_DAEMON_DIR:=$CAPBOX_RUN_DIR/daemon}"
: "${CAPBOX_TMP_DIR:=$CAPBOX_RUN_DIR/tmp}"
: "${CAPBOX_VERSION:=0.3.0}"
: "${CAPBOX_BWRAP:=/usr/bin/bwrap}"
: "${CAPBOX_NET:=host}"
: "${CAPBOX_MIRROR:=cn}"
: "${CAPBOX_PROXY:=}"
: "${CAPBOX_HOSTNAME:=capbox}"
: "${CAPBOX_EXEC_TIMEOUT:=600}"

# ---- 0.2 日志与错误（common.sh 已有则不覆盖） --------------------------------

if ! declare -F log_info >/dev/null 2>&1; then
  log_info() { printf '[capbox] %s\n' "$*" >&2; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn() { printf '[capbox] 警告: %s\n' "$*" >&2; }
fi
if ! declare -F log_err >/dev/null 2>&1; then
  log_err() { printf '[capbox] 错误: %s\n' "$*" >&2; }
fi
if ! declare -F log_debug >/dev/null 2>&1; then
  log_debug() { [[ "${CAPBOX_DEBUG:-0}" == "1" ]] || return 0; printf '[capbox] debug: %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() {
    local code="${1:-1}"
    shift || true
    [[ $# -gt 0 ]] && log_err "$*"
    exit "$code"
  }
fi
if ! declare -F have_cmd >/dev/null 2>&1; then
  have_cmd() { command -v "${1:-}" >/dev/null 2>&1; }
fi

# ---- 0.3 小工具（common.sh 已有同名函数时不重复定义） ------------------------

if ! declare -F json_escape >/dev/null 2>&1; then
  json_escape() { local s="${1-}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; printf '%s' "$s"; }
fi
if ! declare -F human_bytes >/dev/null 2>&1; then
  human_bytes() {
    local b="${1:-0}"
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    local units=(B KB MB GB TB) i=0
    while (( b >= 1024 && i < 4 )); do b=$((b / 1024)); i=$((i + 1)); done
    printf '%d%s' "$b" "${units[$i]}"
  }
fi
if ! declare -F dir_bytes >/dev/null 2>&1; then
  dir_bytes() { [[ -n "${1:-}" && -d "${1:-}" ]] && du -sb -- "$1" 2>/dev/null | cut -f1 || printf '0'; }
fi
if ! declare -F ensure_dirs >/dev/null 2>&1; then
  ensure_dirs() {
    local d
    for d in bin lib lib/guest cache logs os run run/daemon run/tmp state test; do
      mkdir -p "$CAPBOX_DIR/$d" 2>/dev/null || true
    done
  }
fi

# ---- 0.4 bwrap 参数兜底（契约 §3.4 的同构实现） ------------------------------

# _daemon_bwrap_args MODE   —— 打印一行一个参数（不含 -- 命令部分）
_daemon_bwrap_args() {
  local mode="${1:-daemon}"
  local -a a=()

  a+=(--bind "$CAPBOX_ROOTFS" /)
  a+=(--proc /proc)
  a+=(--dev /dev)
  if [[ "$mode" == "daemon" ]]; then
    mkdir -p "$CAPBOX_TMP_DIR" 2>/dev/null || true
    a+=(--bind "$CAPBOX_TMP_DIR" /tmp)
  else
    a+=(--tmpfs /tmp)
  fi
  a+=(--tmpfs /run)
  a+=(--bind "$CAPBOX_WORKSPACE" /workspace)
  # 防止 guest 改写 CLI / config.env（与 common.sh build_bwrap_args 同构）
  if declare -F _capbox_append_ro_cli_binds >/dev/null 2>&1; then
    _capbox_append_ro_cli_binds a
  else
    # 兜底：common.sh 未加载时手工 ro-bind
    local _gp
    if [[ -d "${CAPBOX_BIN_DIR:-}" ]]; then
      _gp="$(_daemon_guest_path "$CAPBOX_BIN_DIR")"
      [[ -n "$_gp" && "$_gp" == /workspace/* ]] && a+=(--ro-bind "$CAPBOX_BIN_DIR" "$_gp")
    fi
    if [[ -d "${CAPBOX_LIB_DIR:-}" ]]; then
      _gp="$(_daemon_guest_path "$CAPBOX_LIB_DIR")"
      [[ -n "$_gp" && "$_gp" == /workspace/* ]] && a+=(--ro-bind "$CAPBOX_LIB_DIR" "$_gp")
    fi
    if [[ -e "${CAPBOX_DIR:-}/config.env" ]]; then
      _gp="$(_daemon_guest_path "$CAPBOX_DIR/config.env")"
      [[ -n "$_gp" && "$_gp" == /workspace/* ]] && a+=(--ro-bind "$CAPBOX_DIR/config.env" "$_gp")
    fi
  fi

  if [[ -f "$CAPBOX_STATE_DIR/resolv.conf" ]]; then
    a+=(--ro-bind "$CAPBOX_STATE_DIR/resolv.conf" /etc/resolv.conf)
  fi
  if [[ ! -e "$CAPBOX_ROOTFS/etc/ssl/certs" && -d /etc/ssl/certs ]]; then
    mkdir -p "$CAPBOX_ROOTFS/etc/ssl/certs" 2>/dev/null || true
    a+=(--ro-bind /etc/ssl/certs /etc/ssl/certs)
  fi

  if declare -F _net_append_bwrap_args >/dev/null 2>&1; then
    _net_append_bwrap_args a
  else
    case "${CAPBOX_NET:-open}" in
      none | restricted) a+=(--unshare-net) ;;
    esac
  fi
  # 注意：restricted 的代理桥目前主要覆盖 oneshot exec；daemon 仅保证 unshare-net。
  # 若 CAPBOX_NET=restricted，daemon 内原始网络不可用，需走一次性 exec 或后续增强。
  a+=(--unshare-user --unshare-uts --unshare-ipc --unshare-pid)
  local _eu="${CAPBOX_EXEC_UID_OVERRIDE:-${CAPBOX_EXEC_UID:-0}}"
  local _eg="${CAPBOX_EXEC_GID_OVERRIDE:-${CAPBOX_EXEC_GID:-0}}"
  [[ "$_eu" =~ ^[0-9]+$ ]] || _eu=0
  [[ "$_eg" =~ ^[0-9]+$ ]] || _eg=0
  a+=(--uid "$_eu" --gid "$_eg" --cap-add ALL)
  a+=(--hostname "$CAPBOX_HOSTNAME")
  a+=(--chdir /workspace)
  a+=(--die-with-parent)
  a+=(--setenv HOME /root)
  a+=(--setenv PATH /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
  a+=(--setenv TERM "${TERM:-xterm-256color}")

  if [[ -n "$CAPBOX_PROXY" ]]; then
    local np="localhost,127.0.0.1,::1,*.local"
    a+=(--setenv http_proxy "$CAPBOX_PROXY" --setenv https_proxy "$CAPBOX_PROXY")
    a+=(--setenv all_proxy "$CAPBOX_PROXY" --setenv no_proxy "$np")
  fi

  printf '%s\n' "${a[@]}"
}

# =============================================================================
# 1. 路径与解析小工具
# =============================================================================

_daemon_ensure_dirs() {
  mkdir -p "$CAPBOX_DAEMON_DIR"/{req,out,ctl} 2>/dev/null || true
  mkdir -p "$CAPBOX_TMP_DIR" 2>/dev/null || true
  mkdir -p "$CAPBOX_RUN_DIR/guest-run" 2>/dev/null || true
}

# 宿主路径 -> 容器内路径（工作区映射为 /workspace）
_daemon_guest_path() {
  local p="${1:-}"
  case "$p" in
    "$CAPBOX_WORKSPACE") printf '/workspace' ;;
    "$CAPBOX_WORKSPACE"/*) printf '/workspace%s' "${p#"$CAPBOX_WORKSPACE"}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# 单引号转义，用于拼 sh 脚本
_daemon_shq() {
  local s="${1-}"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

# 读 daemon.json 里的字符串字段
_daemon_json_str() {
  local k="${1:-}"
  [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" ]] || return 1
  sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    "$CAPBOX_DAEMON_DIR/daemon.json" 2>/dev/null | head -1
}

# 读 daemon.json 里的数字字段
_daemon_json_num() {
  local k="${1:-}"
  [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" ]] || return 1
  sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\([0-9]\+\)[^0-9].*/\1/p" \
    "$CAPBOX_DAEMON_DIR/daemon.json" 2>/dev/null | head -1
}

_daemon_now() { date +%s 2>/dev/null || printf '0'; }

# 心跳陈旧秒数（文件不存在时输出一个大数）
_daemon_hb_age() {
  local hb="$CAPBOX_DAEMON_DIR/hb" m
  [[ -f "$hb" ]] || { printf '999999'; return 0; }
  m="$(stat -c %Y "$hb" 2>/dev/null || printf '0')"
  # mtime 只接受非负整数；负值（1970 之前的脏数据、时钟回拨）不能静默归零——
  # 归零会让 age 变成"当前时间的秒数"（约 17 亿），方向虽对但语义混乱。
  # 显式当作"极旧"，让调用方走清理分支。
  if [[ ! "$m" =~ ^[0-9]+$ ]]; then
    printf '999999'
    return 0
  fi
  local now
  now="$(_daemon_now)"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  # 时钟回拨：mtime 落在未来。按"刚写过"处理，避免 age 为负导致判断错乱。
  if (( now < m )); then
    printf '0'
    return 0
  fi
  printf '%s' "$(( now - m ))"
}

# daemon.json 里声明的 hb_ttl；缺省 6 秒
_daemon_hb_ttl() {
  local t
  t="$(_daemon_json_num hb_ttl 2>/dev/null)"
  [[ "$t" =~ ^[0-9]+$ ]] && (( t > 0 )) || t=6
  printf '%s' "$t"
}

# =============================================================================
# 2. 活性判据
# =============================================================================

# _daemon_alive：0=存活。做三层判定，兼容 PID namespace 隔离。
_daemon_alive() {
  local f="$CAPBOX_DAEMON_DIR/daemon.json"
  [[ -f "$f" ]] || return 1

  local pid myns dns
  pid="$(_daemon_json_num pid 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1

  myns="$(readlink /proc/self/ns/pid 2>/dev/null || printf 'unknown')"
  dns="$(_daemon_json_str pidns 2>/dev/null || true)"

  # 情况 A：与守护进程处于同一 pid namespace —— kill -0 才是可信判据
  if [[ -n "$dns" && "$dns" == "$myns" ]]; then
    kill -0 "$pid" 2>/dev/null || return 1
    # 同 ns 时仍要求心跳不太陈旧（防进程僵死但未退出的边界情况）
    (( $(_daemon_hb_age) <= $(( $(_daemon_hb_ttl) * 2 )) )) 2>/dev/null || return 0
    return 0
  fi

  # 情况 B：跨 pid namespace（DSH 每次调用都是新 ns，这是常态）
  # kill -0 在这里会误命中同号无关进程，绝不能用来判活；只看心跳。
  #
  # 心跳缺失 = 已死，**没有宽限期**。这不是偷懒，而是由服务端写文件的顺序保证的：
  # lib/guest/daemon.sh 先 beat() 写出 hb，再 write_json 写 daemon.json。
  # 因此「daemon.json 在而 hb 不在」只可能是崩溃/残留，不存在「刚启动还没来得及
  # 写心跳」的时间窗。（曾加过 15s 宽限期，结果陈旧的 daemon.json 会被误判为
  # 运行中，反而制造假阳性，故删除。）
  local age ttl
  age="$(_daemon_hb_age)"
  ttl="$(_daemon_hb_ttl)"
  if (( age <= ttl )); then
    return 0
  fi
  return 1
}

# daemon_running：契约 §5 的判据 —— json 存在 + 进程存活 + out 可写
daemon_running() {
  [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" ]] || return 1
  _daemon_alive || return 1
  [[ -d "$CAPBOX_DAEMON_DIR/out" && -w "$CAPBOX_DAEMON_DIR/out" ]] || return 1
  return 0
}

# daemon_info：输出 daemon.json 内容（不存在则失败）
daemon_info() {
  [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" ]] || return 1
  cat -- "$CAPBOX_DAEMON_DIR/daemon.json" 2>/dev/null
}

_daemon_uptime() {
  local st now
  st="$(_daemon_json_num started_at 2>/dev/null)"
  now="$(_daemon_now)"
  [[ "$st" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
  (( now >= st )) || { printf '0'; return 0; }
  printf '%s' "$(( now - st ))"
}

# 清理残留状态文件（stale daemon.json / hb / draining / 锁 / running 标记）
_daemon_clear_state() {
  rm -f "$CAPBOX_DAEMON_DIR/daemon.json" "$CAPBOX_DAEMON_DIR/daemon.json.tmp" 2>/dev/null || true
  rm -f "$CAPBOX_DAEMON_DIR/hb" "$CAPBOX_DAEMON_DIR/hb.tmp" 2>/dev/null || true
  # draining 是服务端在排空期写的标记；服务端崩溃时来不及删，会永久残留。
  # 留着会让后续客户端误以为新实例也在排空（见 _daemon_draining）。
  rm -f "$CAPBOX_DAEMON_DIR/ctl/draining" 2>/dev/null || true
  rm -rf "$CAPBOX_DAEMON_DIR/lock.d" 2>/dev/null || true
  rm -rf "$CAPBOX_DAEMON_DIR/running" 2>/dev/null || true
}

# _daemon_draining：0=服务端正在排空，不再接受新请求
# 服务端在收到 ctl/stop 进入排空时写 ctl/draining。
# 客户端据此拒绝新请求：既避免把请求投给一个即将退出的容器（必然 143），
# 也让报错信息更准确（"正在停止"而不是"心跳失联"）。
#
# 必须带过期判断：服务端崩溃时来不及删这个标记，若只看"文件存在"，一个陈旧的
# draining 会让之后所有请求都被永久拒绝（而守护容器其实可能已经重启）。
# 用 mtime + STOP_WAIT 的两倍做粗略过期，过期即视为陈旧、不再拦截。
_daemon_draining() {
  local f="$CAPBOX_DAEMON_DIR/ctl/draining" m age ttl
  [[ -f "$f" ]] || return 1
  m="$(stat -c %Y "$f" 2>/dev/null || printf '0')"
  [[ "$m" =~ ^[0-9]+$ ]] || return 0
  age=$(( $(_daemon_now) - m ))
  ttl=$(( ${CAPBOX_DAEMON_STOP_WAIT:-30} * 2 ))
  (( age <= ttl )) && return 0
  # 过期：视为陈旧标记，顺手清掉，避免永久拦截
  rm -f "$f" 2>/dev/null || true
  return 1
}

# =============================================================================
# 3. 客户端 RPC
# =============================================================================

# daemon_request CMD [TIMEOUT] [FOLLOW] [CWD]
#   通过文件 RPC 在常驻容器内执行 CMD（字符串，经 /bin/sh）。
#   TIMEOUT: 秒，0=不限；FOLLOW: 1=边执行边输出（用于 shell --daemon）。
#   返回容器内退出码；超时返回 124。
daemon_request() {
  local cmd="${1:-}"
  local timeout_s="${2:-}"
  local follow="${3:-0}"
  local cwd="${4:-/workspace}"

  [[ -n "$cmd" ]] || die 2 "daemon_request: 命令为空"
  [[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s="${CAPBOX_EXEC_TIMEOUT:-600}"
  [[ -n "$cwd" ]] || cwd=/workspace

  if ! daemon_running; then
    log_err "守护容器未运行；请先以 DSH 后台任务方式启动: capbox up"
    return 3
  fi

  # 服务端正在排空（已收到 stop，等旧任务收尾）：不再接受新请求。
  # 此时投递的请求要么被 _fail_pending 回写 143，要么一直没人消费到超时，
  # 都不如直接拒绝来得清晰。返回 3 与「未运行」一致，调用方可据此重试/重启。
  if _daemon_draining; then
    log_err "守护容器正在停止（排空在跑任务），暂不接受新请求；请稍后重试或重新 capbox up"
    return 3
  fi

  _daemon_ensure_dirs

  local id
  id="$(date +%s%N 2>/dev/null || date +%s)-$$-$RANDOM"
  local reqf="$CAPBOX_DAEMON_DIR/req/$id.sh"
  local outf="$CAPBOX_DAEMON_DIR/out/$id.log"
  local rcf="$CAPBOX_DAEMON_DIR/out/$id.rc"
  local inf="$CAPBOX_DAEMON_DIR/out/$id.in"

  # 非 tty 的 stdin：作为脚本内容喂给容器内 shell（支撑 echo '...' | capbox shell --daemon）
  local use_stdin=0
  if [[ "$follow" == "1" && ! -t 0 ]]; then
    if cat >"$inf.tmp" 2>/dev/null; then
      mv -f "$inf.tmp" "$inf" 2>/dev/null && use_stdin=1
    fi
  fi

  local guest_in
  guest_in="$(_daemon_guest_path "$inf")"

  # 请求脚本：先 cd，再执行；需要时把 stdin 重定向到 payload
  #
  # cd 用 `|| true` 而非 `|| exit 1`：主模块的 cmd_exec 会把 cwd 直接拼进 CMD
  # （`cd '<cwd>' 2>/dev/null || cd /workspace; <cmd>`），若这里因 cwd 无效提前
  # exit 1，就会抢在它自己的回退逻辑之前把请求打死。非致命更稳妥。
  {
    printf 'cd %s 2>/dev/null || true\n' "$(_daemon_shq "$cwd")"
    if (( use_stdin == 1 )); then
      printf 'exec < %s\n' "$(_daemon_shq "$guest_in")"
    fi
    printf '%s\n' "$cmd"
  } > "$reqf.tmp" 2>/dev/null || {
    log_err "无法写入请求文件: $reqf"
    rm -f "$inf" 2>/dev/null || true
    return 1
  }
  # 原子投递：客户端与服务端可能在两个 namespace，靠 rename 保证不读到半截文件
  mv -f "$reqf.tmp" "$reqf" 2>/dev/null || {
    log_err "无法投递请求: $reqf"
    return 1
  }

  local start now elapsed deadline=0
  start="$(_daemon_now)"
  (( timeout_s > 0 )) && deadline=$(( start + timeout_s ))

  local interval="0.05"
  local rc="" timed_out=0
  local shown=0 size
  local dead_strikes=0 daemon_died=0

  while :; do
    if [[ -f "$rcf" ]]; then
      rc="$(cat -- "$rcf" 2>/dev/null | tr -d '[:space:]')"
      [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
      break
    fi

    # FOLLOW：增量输出日志
    if [[ "$follow" == "1" && -f "$outf" ]]; then
      size="$(wc -c <"$outf" 2>/dev/null | tr -d '[:space:]')"
      [[ "$size" =~ ^[0-9]+$ ]] || size=0
      if (( size > shown )); then
        tail -c +$(( shown + 1 )) -- "$outf" 2>/dev/null | head -c "$(( size - shown ))"
        shown="$size"
      fi
    fi

    now="$(_daemon_now)"
    if (( deadline > 0 && now >= deadline )); then
      # 通知服务端终止该请求的整个进程组（服务端会写 rc=124）。
      # 注意：只写标记，不改 rc —— rc 的写入权归服务端，避免两边打架。
      mkdir -p "$CAPBOX_DAEMON_DIR/ctl/kill" 2>/dev/null || true
      : >"$CAPBOX_DAEMON_DIR/ctl/kill/$id" 2>/dev/null || true
      # 给服务端反应时间：它下一个 tick(0.2s) 就会处理，加上 0.3s 优雅退出
      local grace=0
      while (( grace < 60 )); do
        [[ -f "$rcf" ]] && break
        sleep 0.05
        grace=$((grace + 1))
      done
      if [[ -f "$rcf" ]]; then
        rc="$(cat -- "$rcf" 2>/dev/null | tr -d '[:space:]')"
        [[ "$rc" =~ ^[0-9]+$ ]] || rc=124
        break
      fi
      timed_out=1
      rc=124
      break
    fi

    # 守护容器在请求执行中途死掉时（心跳过期），必须快速失败而不是干等到超时。
    # 判据：心跳年龄超过 hb_ttl（服务端每 ~1s 刷一次，ttl 默认 6s，留足余量），
    # 且连续两次轮询都如此（避免刚好卡在两次心跳之间误判）。
    # 用 ttl 而不是 2*ttl：后者要 12s 才判死，用户会觉得"卡住"。
    if (( $(_daemon_hb_age) > $(_daemon_hb_ttl) )); then
      dead_strikes=$((dead_strikes + 1))
      if (( dead_strikes >= 2 )); then
        daemon_died=1
        rc=3
        break
      fi
    else
      dead_strikes=0
    fi

    sleep "$interval"
    # 指数退避：50ms -> 500ms
    case "$interval" in
      0.05) interval="0.1" ;;
      0.1) interval="0.2" ;;
      0.2) interval="0.35" ;;
      0.35) interval="0.5" ;;
    esac
  done

  # 输出（FOLLOW 已经边跑边打过增量，这里只补尾部）
  # 请求被取消（超时/守护进程退出）时，容器内的 shell 会往日志里写 "Terminated"
  # 之类的信号噪声。服务端会落一个 .cx 取消标记，据此处过滤 —— 契约 §3.3 要求
  # exec 的 stdout 只含容器内命令的输出。
  local cancelled=0
  [[ -f "$CAPBOX_DAEMON_DIR/out/$id.cx" ]] && cancelled=1

  if [[ "$follow" == "1" ]]; then
    if [[ -f "$outf" ]]; then
      size="$(wc -c <"$outf" 2>/dev/null | tr -d '[:space:]')"
      [[ "$size" =~ ^[0-9]+$ ]] || size=0
      if (( size > shown )); then
        if (( cancelled == 1 )); then
          tail -c +$(( shown + 1 )) -- "$outf" 2>/dev/null | head -c "$(( size - shown ))" |
            grep -v -E '^(Terminated|Killed|Killed:|Aborted|已终止)' || true
        else
          tail -c +$(( shown + 1 )) -- "$outf" 2>/dev/null | head -c "$(( size - shown ))"
        fi
      fi
    fi
  elif [[ -f "$outf" ]]; then
    if (( cancelled == 1 )); then
      grep -v -E '^(Terminated|Killed|Killed:|Aborted|已终止)' -- "$outf" 2>/dev/null || true
    else
      cat -- "$outf" 2>/dev/null
    fi
  fi

  if (( timed_out == 1 )); then
    log_err "容器内命令超时（${timeout_s}s）"
  elif (( daemon_died == 1 )); then
    log_err "守护容器在命令执行期间已停止（心跳失联），请求被放弃"
  fi

  # 清理本次请求文件（rc 由服务端写，日志与 payload 一并删掉）
  rm -f "$outf" "$rcf" "$inf" "$inf.tmp" "$reqf" "$reqf.tmp" "$CAPBOX_DAEMON_DIR/out/$id.cx" 2>/dev/null || true
  rm -f "$CAPBOX_DAEMON_DIR/ctl/kill/$id" 2>/dev/null || true

  return "$rc"
}

# =============================================================================
# 4. up —— 前台阻塞的守护容器
# =============================================================================

# 构造完整 argv（数组，最后一个元素是 -- 之后的东西）
# _daemon_build_up_argv ARRAYNAME
_daemon_build_up_argv() {
  local -n _out="$1"
  _out=()

  local -a base=()
  if declare -F sandbox_bwrap_cmd >/dev/null 2>&1; then
    local x
    while IFS= read -r -d '' x; do
      base+=("$x")
    done < <(sandbox_bwrap_cmd daemon "" "/workspace" 2>/dev/null)
  fi
  if (( ${#base[@]} == 0 )); then
    # 兜底：自己构造（契约 §3.4）
    local -a args=()
    mapfile -t args < <(_daemon_bwrap_args daemon)
    base=("$CAPBOX_BWRAP" "${args[@]}")
  fi

  local guest_daemon_dir guest_guest_script guest_tmp guest_run
  guest_daemon_dir="$(_daemon_guest_path "$CAPBOX_DAEMON_DIR")"
  guest_guest_script="$(_daemon_guest_path "$CAPBOX_DIR/lib/guest/daemon.sh")"
  guest_tmp="$(_daemon_guest_path "$CAPBOX_TMP_DIR")"
  guest_run="$(_daemon_guest_path "$CAPBOX_RUN_DIR/guest-run")"

  _out=("${base[@]}")

  # 常驻容器的 /tmp 与 /run 必须持久化（后挂载覆盖前面的 --tmpfs）
  _out+=(--bind "$CAPBOX_TMP_DIR" /tmp)
  _out+=(--bind "$CAPBOX_RUN_DIR/guest-run" /run)

  # 服务端需要的环境
  _out+=(--setenv CAPBOX_DAEMON_DIR "$guest_daemon_dir")
  _out+=(--setenv CAPBOX_DISTRO "$CAPBOX_DISTRO")
  _out+=(--setenv CAPBOX_ROOTFS_HOST "$CAPBOX_ROOTFS")
  _out+=(--setenv CAPBOX_VERSION "$CAPBOX_VERSION")
  _out+=(--setenv CAPBOX_HOSTNAME "$CAPBOX_HOSTNAME")
  _out+=(--setenv CAPBOX_DAEMON_MAXJOBS "${CAPBOX_DAEMON_MAXJOBS:-8}")
  _out+=(--setenv CAPBOX_DAEMON_TICK "${CAPBOX_DAEMON_TICK:-0.2}")
  _out+=(--setenv CAPBOX_DAEMON_HB_TTL "${CAPBOX_DAEMON_HB_TTL:-6}")
  _out+=(--setenv CAPBOX_DAEMON_STOP_WAIT "${CAPBOX_DAEMON_STOP_WAIT:-30}")

  _out+=(-- /bin/sh "$guest_guest_script")
}

cmd_up() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        cat <<'EOF'
用法: capbox up

启动常驻守护容器（**前台阻塞**，必须用 DSH 后台任务运行）。

  bash 工具: run_in_background=true 执行 `.capbox/bin/capbox up`

绝对不能写成 `nohup capbox up &`：DSH 的 bash 工具用 bwrap --die-with-parent
包裹每次调用，调用结束就杀掉整棵进程树。只有后台任务能让它跨调用存活。

停止: capbox down（或结束该后台任务）
EOF
        return 0
        ;;
      *) die 2 "up: 未知选项 $1" ;;
    esac
  done

  [[ -x "${CAPBOX_BWRAP:-}" ]] || die 5 "bwrap 不可用: ${CAPBOX_BWRAP:-未设置}（apt install bubblewrap）"
  # rootfs 判据必须按**容器语义**解析符号链接：rootfs 里 /bin/sh -> /bin/busybox 是
  # 指向容器内绝对路径的悬空链接，宿主侧 -e 会跟随到宿主 /bin/busybox 而误判为不存在。
  local rootfs_ok=0
  if declare -F rootfs_ready >/dev/null 2>&1; then
    rootfs_ready && rootfs_ok=1
  elif declare -F _rootfs_path_exists >/dev/null 2>&1; then
    _rootfs_path_exists "$CAPBOX_ROOTFS" /bin/sh && rootfs_ok=1
  elif [[ -e "$CAPBOX_ROOTFS/bin/sh" || -e "$CAPBOX_ROOTFS/bin/busybox" || -e "$CAPBOX_ROOTFS/bin/bash" ]]; then
    rootfs_ok=1
  fi
  (( rootfs_ok == 1 )) || die 4 "rootfs 不存在: $CAPBOX_ROOTFS（请先运行 capbox init）"
  [[ -f "$CAPBOX_DIR/lib/guest/daemon.sh" ]] || die 1 "缺少服务端脚本: $CAPBOX_DIR/lib/guest/daemon.sh"

  _daemon_ensure_dirs
  if declare -F ensure_rootfs_dirs >/dev/null 2>&1; then
    ensure_rootfs_dirs "$CAPBOX_ROOTFS" >/dev/null 2>&1 || true
  else
    local d
    for d in proc sys dev tmp run root etc workspace var var/log home mnt; do
      mkdir -p "$CAPBOX_ROOTFS/$d" 2>/dev/null || true
    done
  fi
  if declare -F refresh_resolv >/dev/null 2>&1; then
    refresh_resolv >/dev/null 2>&1 || true
  fi

  # ---- 串行化「检查是否在跑 → 清理残留 → 启动」这段临界区 ----
  # 没有这把锁会出真实故障：两个并发 up 可能**都**看到 daemon_running=false
  # （第一个还没写出 daemon.json），然后**都**执行 _daemon_clear_state，
  # 于是后者的清理把前者刚写好的 daemon.json/hb 删掉。表现就是
  # 「status 报 running=true，紧接着 exec --daemon 却返回 3」——状态文件在两次
  # 读取之间被人删了。容器内虽有 lock.d 防重入，但那只管"服务端"，
  # 管不到"客户端的启动前清理"。
  local lockf="$CAPBOX_RUN_DIR/daemon-up.lock"
  local have_lock=0
  mkdir -p "$CAPBOX_RUN_DIR" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    if exec 9>"$lockf" 2>/dev/null; then
      if flock -w 60 9 2>/dev/null; then
        have_lock=1
      fi
    fi
  fi
  # 拿不到 flock（无 flock 命令/超时）时降级为无锁启动：并发 up 仍可能互相清理，
  # 但这是环境受限下的最优选择，不因此让 up 直接失败。

  # 已在运行：幂等返回
  if daemon_running; then
    log_info "守护容器已在运行（pid $(_daemon_json_num pid 2>/dev/null || echo '?')），无需重复启动"
    if (( have_lock == 1 )); then flock -u 9 2>/dev/null; exec 9>&- 2>/dev/null; fi
    return 0
  fi

  # 清理上次残留（此刻持有锁，不会与另一个 up 的清理交错）
  _daemon_clear_state
  rm -f "$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || true
  rm -rf "$CAPBOX_DAEMON_DIR/ctl/kill" 2>/dev/null || true
  rm -f "$CAPBOX_DAEMON_DIR"/req/*.sh 2>/dev/null || true
  rm -f "$CAPBOX_DAEMON_DIR"/req/*.tmp 2>/dev/null || true
  rm -f "$CAPBOX_DAEMON_DIR"/out/*.rc "$CAPBOX_DAEMON_DIR"/out/*.log "$CAPBOX_DAEMON_DIR"/out/*.in 2>/dev/null || true

  local logf="$CAPBOX_DAEMON_DIR/daemon.log"
  # 日志超过 8MB 就轮转一份，避免无限增长
  if [[ -f "$logf" ]] && (( $(stat -c %s "$logf" 2>/dev/null || echo 0) > 8388608 )); then
    mv -f "$logf" "$logf.1" 2>/dev/null || true
  fi

  local -a argv=()
  _daemon_build_up_argv argv
  (( ${#argv[@]} > 0 )) || die 1 "无法构造 bwrap 命令"

  log_info "启动守护容器（rootfs=$CAPBOX_ROOTFS）"

  local child="" got_signal=0
  # 收到 TERM/INT：写 ctl/stop 让服务端优雅退出（它自己清理 daemon.json）
  _daemon_up_on_signal() {
    got_signal=1
    : > "$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || true
    log_info "收到终止信号，正在通知守护容器优雅退出…"
  }
  trap _daemon_up_on_signal TERM INT

  if declare -F _idmap_enabled >/dev/null 2>&1 && _idmap_enabled; then
    CAPBOX_IDMAP_SPAWN_LOG="$logf"
    child="$(_idmap_spawn_bwrap_argv "${argv[@]}")" || {
      log_err "idmap 启动守护容器失败：${CAPBOX_IDMAP_DETAIL:-unknown}"
      return 1
    }
  else
    if [[ "${CAPBOX_IDMAP:-auto}" == "on" && "${CAPBOX_IDMAP_STATUS:-}" == "blocked" ]]; then
      log_err "CAPBOX_IDMAP=on 但多 UID 映射不可用：${CAPBOX_IDMAP_DETAIL:-见 doctor}"
      return 1
    fi
    "${argv[@]}" >>"$logf" 2>&1 &
    child=$!
  fi

  # 等待容器就绪（最多 20s），期间保持对信号的响应。
  # 必须等 daemon.json，不能只等 hb：服务端的顺序是「先 beat() 写 hb，再 write_json
  # 写 daemon.json」，两者之间有窗口。若只等 hb 就宣告就绪，调用方紧接着执行
  # down/status 会撞上「hb 在但 json 不在」的中间态，被误判为未运行（rc=3）。
  local waited=0
  while (( waited < 200 )); do
    [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" ]] && break
    kill -0 "$child" 2>/dev/null || break
    (( got_signal == 1 )) && break
    sleep 0.1
    waited=$((waited + 1))
  done

  # 就绪判定完成（或已失败/已收信号）后立刻释放启动锁：
  # 锁只需覆盖「检查→清理→写出 daemon.json」这段，不能跨越整个前台阻塞期，
  # 否则后一个 up 会被阻塞到第一个退出为止。
  _daemon_release_up_lock() {
    if (( ${have_lock:-0} == 1 )); then
      flock -u 9 2>/dev/null || true
      exec 9>&- 2>/dev/null || true
    fi
  }

  if (( got_signal == 1 )); then
    # 启动途中就收到了终止信号：不必再宣告"就绪"，直接进入收尾等待
    log_info "收到终止信号，正在等待守护容器退出…"
    _daemon_release_up_lock
  elif [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" ]]; then
    log_info "守护容器就绪（容器内 pid $(_daemon_json_num pid 2>/dev/null || echo '?')，hostname ${CAPBOX_HOSTNAME}）"
    log_info "IPC 目录: $CAPBOX_DAEMON_DIR"
    log_info "停止: capbox down（或结束承载本进程的后台任务）"
    _daemon_release_up_lock
  elif ! kill -0 "$child" 2>/dev/null; then
    local brc=0
    wait "$child" 2>/dev/null
    brc=$?
    log_err "守护容器启动失败（退出码 $brc），最近日志："
    tail -n 20 -- "$logf" >&2 2>/dev/null || true
    _daemon_clear_state
    _daemon_release_up_lock
    trap - TERM INT
    return 1
  else
    # 既没就绪、进程也还在（20s 超时）：不当成失败，继续前台托管，
    # 但要放锁，别让后续 up 被阻塞。
    log_warn "守护容器在 20s 内未写出 daemon.json，继续等待（日志: $logf）"
    _daemon_release_up_lock
  fi

  local rc=0
  # 记住"本实例启动的那个服务端"的 iid，退出清理时据此判断是否已被接管。
  # 不能用 pid（容器内恒为 2），也不能用 pidns（inode 会被内核复用）——
  # 服务端生成的随机 iid 是唯一可靠的世代标识。
  local own_iid=""
  own_iid="$(_daemon_json_str iid 2>/dev/null || true)"
  while kill -0 "$child" 2>/dev/null; do
    # 收到 TERM/INT 时通知服务端优雅退出（正常路径绝不写 ctl/stop）
    if (( got_signal == 1 )); then
      : > "$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || true
    fi
    sleep 0.1
  done
  # 子进程已退出，reap 一次拿到真实退出码
  wait "$child" 2>/dev/null
  rc=$?

  trap - TERM INT
  # 退出时只清理「属于本实例」的状态：若期间已有**另一个** up 接管并写出了
  # 自己的 daemon.json，就不能把它的文件删掉——否则同样是
  # 「status=true 但 exec rc=3」的来源（状态文件被退出的旧实例顺手删了）。
  #
  # ⚠️ 判据必须用服务端生成的随机 iid：
  #   * 不能用 pid —— 容器内服务端永远是容器里的 pid 2（实测两个不同实例的
  #     daemon.json 都是 "pid":2），条件恒不成立，守卫形同虚设；
  #   * 不能用 pidns —— 命名空间 inode 销毁后会被内核复用
  #     （实测 run1/run3 都是 4026532252），同样区分不了世代。
  local cur_iid
  cur_iid="$(_daemon_json_str iid 2>/dev/null || true)"
  if [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" && -n "$cur_iid" && -n "$own_iid" && "$cur_iid" != "$own_iid" ]]; then
    log_warn "检测到新实例已接管（iid ${cur_iid:0:8}…），保留其状态文件"
  else
    _daemon_clear_state
  fi
  rm -f "$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || true
  rm -rf "$CAPBOX_DAEMON_DIR/ctl/kill" 2>/dev/null || true

  log_info "守护容器已停止（退出码 $rc）"
  return "$rc"
}

# =============================================================================
# 5. down
# =============================================================================
#
# 注意：`capbox clean` 会先调用本函数再清理 run/tmp（主模块的 common.sh
# cmd_clean 里 `declare -F cmd_down && _probe_daemon` 后调用）。因此本函数必须
# 满足两个约束，改这里时别破坏：
#   1. 未运行时返回 3 —— clean 现在**显式识别 3** 为「已自行退出」（不再靠
#      `|| log_warn` 把一切非零都吞掉）；只有其它非零值才会被当作真失败告警。
#      所以「返回 3」是契约，不是可以被随手改掉的细节。
#   2. 优雅退出：写 ctl/stop 让服务端自己收尾并清理 daemon.json，不依赖 kill。
# 另外 run/tmp 是容器内 /tmp 的 bind 后端，clean 只删内容不删目录，所以
# daemon 在 clean 之后仍能正常重启——这条由 主模块的 _safe_rm_dir_contents
# 保证，我的 cmd_up 里另有 mkdir -p 兜底。

cmd_down() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help) printf '用法: capbox down\n停止常驻守护容器\n'; return 0 ;;
      *) die 2 "down: 未知选项 $1" ;;
    esac
  done

  if ! daemon_running; then
    # 未运行。这里要非常小心：**不要把别人/别的实例正在写的状态当垃圾清掉**。
    #
    # 背景：hb 新鲜但没有 daemon.json，有两种可能——
    #   A) 某个服务端正在启动（先写 hb 再写 daemon.json，正常中间态）
    #   B) 某个服务端被 SIGKILL（json 和 hb 都残留，hb 冻结在死前最后一拍）
    # 早先这里只要看到 hb 存在就以"陈旧"为由清理，结果会误删**正在启动的实例**
    # 或**仍在运行但 json 恰好在窗口期缺失**的实例的 hb/lock.d，属于跨实例破坏。
    #
    # 正确判据：只有 hb **确实过期**（超过 hb_ttl）才能认定是残留。
    #   * hb 新鲜      -> 可能还有活容器在写，不清理，只报告状态不完整
    #   * hb 过期/缺失 -> 确实是残留，清理
    local hb_age ttl
    hb_age="$(_daemon_hb_age)"
    ttl="$(_daemon_hb_ttl)"
    if [[ -f "$CAPBOX_DAEMON_DIR/hb" ]] && (( hb_age <= ttl )); then
      # 心跳新鲜 = 有一个服务端还在 beat()。它没有 daemon.json，说明骨架曾被
      # 外部删掉（`rm -rf run/daemon`）而服务端没重建 —— 这是 **orphan 状态**：
      # 进程活着、还能消费 req/，但客户端 daemon_running 判 false，
      # 于是"既用不了、也停不掉"。
      #
      # 不能像早先那样直接拒绝（那会让 orphan 永久卡死，谁也没法收场）。
      # 正确做法：仍然发 ctl/stop 让它自己优雅退出。服务端的 self-heal 会先把
      # 骨架补回来（见 guest/daemon.sh 的 _self_heal），因此 ctl/ 一旦建出来
      # 它就能看到 stop 标记。
      log_warn "检测到孤儿服务端（有新鲜心跳但缺少 daemon.json）；尝试通知它优雅退出"
      _daemon_ensure_dirs
      : >"$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || true
      local ow=0
      while (( ow < 100 )); do
        [[ -f "$CAPBOX_DAEMON_DIR/hb" ]] || break
        [[ "$(_daemon_hb_age)" -gt "$ttl" ]] && break
        sleep 0.1
        ow=$((ow + 1))
      done
      if [[ -f "$CAPBOX_DAEMON_DIR/hb" ]] && (( $(_daemon_hb_age) <= ttl )); then
        log_err "孤儿服务端未在 10s 内退出（可能版本过旧、不支持 self-heal）"
        log_err "建议：结束承载它的 TTY/job，或删除 $CAPBOX_DAEMON_DIR/hb 后重试"
        return 1
      fi
      log_info "孤儿服务端已退出"
      _daemon_clear_state
      return 0
    fi

    if [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" || -f "$CAPBOX_DAEMON_DIR/hb" || -d "$CAPBOX_DAEMON_DIR/lock.d" ]]; then
      staleness=1
      log_warn "发现陈旧的状态文件（守护进程已不在），已清理"
      _daemon_clear_state
    else
      log_info "守护容器未运行"
    fi
    return 3
  fi

  local pid
  pid="$(_daemon_json_num pid 2>/dev/null || echo '?')"
  log_info "正在停止守护容器（容器内 pid $pid）"

  _daemon_ensure_dirs
  : >"$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || {
    log_err "无法写入 $CAPBOX_DAEMON_DIR/ctl/stop"
    return 1
  }

  # 等服务端收尾：daemon.json 消失即视为已退出。
  #
  # 但**不能盲等满 limit**：若服务端其实早已死了（崩溃/SIGKILL，只是 hb 还新鲜
  # 让 daemon_running 误判为活），没有任何进程会消费 ctl/stop，daemon.json 永远
  # 不会消失，于是 down 会白等满 40s 才走超时分支。实测过这种情况（27s 才返回）。
  #
  # 判据：服务端一旦真正响应 ctl/stop，会往 daemon.log 写「收到停止请求」。
  # 给了 NOACK 秒宽限仍不见这条日志、且 daemon.json 也没动 => 判定服务端已死，
  # 直接清理并返回，不必等到 40s。
  local waited=0 limit noack
  limit="${CAPBOX_DAEMON_DOWN_WAIT:-40}"     # 0.1s * 400 = 40s
  noack="${CAPBOX_DAEMON_DOWN_NOACK:-5}"     # 5s 内无回应即判死
  local logf="$CAPBOX_DAEMON_DIR/daemon.log"
  # 记录 down 开始时的日志行数，只检查之后新增的行。
  # 不能用 `tail -n 5 | grep`：并行任务多时日志行数增长很快，ack 那行很快就被
  # 挤出 5 行窗口，导致误判"没回应"→ 把正在排空的长任务当崩溃直接清掉
  # （实测：长任务 sleep 12 被误杀成 rc=143）。也不能全文 grep——会命中历史
  # 次 down 的旧记录而假 ack。
  local logbase=0
  [[ -f "$logf" ]] && logbase="$(wc -l <"$logf" 2>/dev/null | tr -d '[:space:]')"
  [[ "$logbase" =~ ^[0-9]+$ ]] || logbase=0
  local acked=0
  while (( waited < limit * 10 )); do
    [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" ]] || break
    if (( acked == 0 )) && [[ -f "$logf" ]]; then
      if tail -n +$(( logbase + 1 )) -- "$logf" 2>/dev/null | grep -q '收到停止请求'; then
        acked=1
      fi
    fi
    if (( acked == 0 )) && (( waited >= noack * 10 )); then
      log_warn "服务端 ${noack}s 内未响应停止请求（可能已崩溃），直接清理状态文件"
      _daemon_clear_state
      rm -f "$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || true
      rm -rf "$CAPBOX_DAEMON_DIR/ctl/kill" 2>/dev/null || true
      log_info "守护容器已停止"
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done

  if [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" ]]; then
    log_warn "守护容器未在 $((limit))s 内退出；清理状态文件"
    log_warn "（跨 PID namespace 无法强制 kill，容器会随承载它的后台任务一并结束）"
    _daemon_clear_state
    rm -f "$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || true
    return 1
  fi

  # 服务端已退出：清掉协作文件。daemon.json 由服务端 EXIT trap 自清，
  # 但 hb / .tmp 可能残留——留着会让「过期 hb 判死」的兜底逻辑多看一个陈旧文件。
  rm -f "$CAPBOX_DAEMON_DIR/hb" "$CAPBOX_DAEMON_DIR/hb.tmp" 2>/dev/null || true
  rm -f "$CAPBOX_DAEMON_DIR/daemon.json.tmp" 2>/dev/null || true
  rm -f "$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || true
  rm -rf "$CAPBOX_DAEMON_DIR/ctl/kill" 2>/dev/null || true
  log_info "守护容器已停止"
  return 0
}

# =============================================================================
# 6. status
# =============================================================================

cmd_status() {
  local json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      -h | --help) printf '用法: capbox status [--json]\n'; return 0 ;;
      *) die 2 "status: 未知选项 $1" ;;
    esac
  done

  local running=false pid=0 uptime=0
  if daemon_running; then
    running=true
    pid="$(_daemon_json_num pid 2>/dev/null || echo 0)"
    [[ "$pid" =~ ^[0-9]+$ ]] || pid=0
    uptime="$(_daemon_uptime)"
  fi

  local bytes
  if declare -F dir_bytes >/dev/null 2>&1; then
    bytes="$(dir_bytes "$CAPBOX_ROOTFS")"
  else
    bytes="$(du -sb -- "$CAPBOX_ROOTFS" 2>/dev/null | cut -f1)"
  fi
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0

  local mirror_url=""
  if declare -F mirror_url_for >/dev/null 2>&1; then
    mirror_url="$(mirror_url_for "$CAPBOX_DISTRO" 2>/dev/null || true)"
  fi
  [[ -n "$mirror_url" ]] || mirror_url="(未注入)"

  local rootfs_ok=0
  if declare -F rootfs_ready >/dev/null 2>&1; then
    rootfs_ready && rootfs_ok=1
  elif declare -F _rootfs_path_exists >/dev/null 2>&1; then
    _rootfs_path_exists "$CAPBOX_ROOTFS" /bin/sh && rootfs_ok=1
  elif [[ -e "$CAPBOX_ROOTFS/bin/sh" || -e "$CAPBOX_ROOTFS/bin/busybox" || -e "$CAPBOX_ROOTFS/bin/bash" ]]; then
    rootfs_ok=1
  fi

  if (( json == 1 )); then
    printf '{"distro":"%s","rootfs":"%s","rootfs_bytes":%s,"daemon":{"running":%s,"pid":%s,"uptime":%s},"net":"%s","mirror":"%s","proxy":"%s","bwrap":"%s","version":"%s"}\n' \
      "$(json_escape "$CAPBOX_DISTRO")" \
      "$(json_escape "$CAPBOX_ROOTFS")" \
      "$bytes" \
      "$running" "$pid" "$uptime" \
      "$(json_escape "${CAPBOX_NET:-host}")" \
      "$(json_escape "${CAPBOX_MIRROR:-cn}")" \
      "$(json_escape "${CAPBOX_PROXY:-}")" \
      "$(json_escape "${CAPBOX_BWRAP:-}")" \
      "$(json_escape "${CAPBOX_VERSION:-0.3.0}")"
    return 0
  fi

  local rootfs_state="缺失"
  (( rootfs_ok == 1 )) && rootfs_state="就绪"

  printf '发行版     : %s\n' "$CAPBOX_DISTRO"
  printf 'rootfs     : %s（%s，%s）\n' "$CAPBOX_ROOTFS" "$rootfs_state" "$(human_bytes "$bytes")"
  if [[ "$running" == true ]]; then
    printf '守护进程   : 运行中（pid %s，已运行 %ss）\n' "$pid" "$uptime"
    local hb_age
    hb_age="$(_daemon_hb_age)"
    printf '  心跳     : %ss 前（阈值 %ss）\n' "$hb_age" "$(_daemon_hb_ttl)"
    printf '  IPC      : %s\n' "$CAPBOX_DAEMON_DIR"
    printf '  日志     : %s\n' "$CAPBOX_DAEMON_DIR/daemon.log"
  else
    printf '守护进程   : 未运行（用后台任务运行 capbox up 启动）\n'
  fi
  printf '网络模式   : %s\n' "${CAPBOX_NET:-host}"
  if [[ "${CAPBOX_MIRROR:-cn}" == "none" ]]; then
    printf '镜像源     : none（未注入）\n'
  else
    printf '镜像源     : %s（%s）\n' "${CAPBOX_MIRROR:-cn}" "$mirror_url"
  fi
  if [[ -n "${CAPBOX_PROXY:-}" ]]; then
    printf '代理       : %s\n' "$CAPBOX_PROXY"
  else
    printf '代理       : 无（直连）\n'
  fi
  printf '宿主名     : %s\n' "${CAPBOX_HOSTNAME:-capbox}"
  printf 'bwrap      : %s\n' "${CAPBOX_BWRAP:-未设置}"
  printf '工作区     : %s\n' "$CAPBOX_WORKSPACE"
  printf '版本       : %s\n' "${CAPBOX_VERSION:-0.3.0}"
  return 0
}

# =============================================================================
# 7. logs
# =============================================================================

cmd_logs() {
  local follow=0 lines=50
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f | --follow) follow=1; shift ;;
      -n)
        lines="${2:-50}"
        shift 2 || shift
        ;;
      -n=* | --lines=*)
        lines="${1#*=}"
        shift
        ;;
      -h | --help)
        cat <<'EOF'
用法: capbox logs [-f] [-n N]

  输出守护容器（bwrap 那个进程）的 stdout/stderr。
  -f  持续跟随（Ctrl-C 退出）
  -n  显示最后 N 行，默认 50
EOF
        return 0
        ;;
      *) die 2 "logs: 未知选项 $1" ;;
    esac
  done
  [[ "$lines" =~ ^[0-9]+$ ]] || die 2 "logs: -n 必须是非负整数"

  local logf="$CAPBOX_DAEMON_DIR/daemon.log"
  if [[ ! -f "$logf" ]]; then
    log_info "暂无守护容器日志（$logf 不存在）"
    return 0
  fi

  if (( follow == 1 )); then
    tail -n "$lines" -f -- "$logf"
    return $?
  fi
  tail -n "$lines" -- "$logf"
  return 0
}
