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
#   * 复用 launch.sh 的 build_bwrap_args 及 common.sh 的 ensure_rootfs_dirs / log_* / die /
#     refresh_resolv 等；sandbox.sh 的 sandbox_bwrap_cmd 用于构造 bwrap argv。
#   * 启动策略只有 lib/launch.sh 一份；缺少必需模块时明确失败。
#   * 本文件**不定义 capbox_main**（由 主模块的 bin/capbox 提供），只注册命令函数。
#
# 本文件最反直觉的一条设计（已实测，必须保留）：
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
# 0. 基础工具与启动入口
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
: "${CAPBOX_VERSION:=0.4.2}"
: "${CAPBOX_BWRAP:=/usr/bin/bwrap}"
: "${CAPBOX_NET:=host}"
: "${CAPBOX_MIRROR:=cn}"
: "${CAPBOX_PROXY:=}"
: "${CAPBOX_HOSTNAME:=capbox}"
: "${CAPBOX_EXEC_TIMEOUT:=600}"

# ---- 0.2 日志与错误（common.sh 已有则不覆盖） --------------------------------

if ! declare -F log_info >/dev/null 2>&1; then
  log_info() { printf '%s %s\n' "${_CAPBOX_LOG_PREFIX_INFO:-[capbox]}" "$*" >&2; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn() { printf '%s %s\n' "${_CAPBOX_LOG_PREFIX_WARN:-[capbox] warning:}" "$*" >&2; }
fi
if ! declare -F log_err >/dev/null 2>&1; then
  log_err() { printf '%s %s\n' "${_CAPBOX_LOG_PREFIX_ERR:-[capbox] error:}" "$*" >&2; }
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
    for d in bin lib lib/guest cache logs os run run/daemon run/tmp state test services; do
      mkdir -p "$CAPBOX_DIR/$d" 2>/dev/null || true
    done
  }
fi

# ---- 0.4 统一 bwrap 参数入口 ------------------------------

# 复用同一安全门禁；模块不完整时失败，不维护第二份策略。
_daemon_require_bwrap_version() {
  if ! declare -F _capbox_enforce_bwrap_baseline >/dev/null 2>&1; then
    i18n_err daemon.launch_module_incomplete_unified_bwrap_security_gate
    return 5
  fi
  _capbox_enforce_bwrap_baseline
}

# 保留对调用方的内部入口；不另开独立策略回退。
_daemon_bwrap_args() {
  if ! declare -F build_bwrap_args >/dev/null 2>&1; then
    i18n_err daemon.launch_module_incomplete_lib_launch_sh_missing
    return 5
  fi
  build_bwrap_args "${1:-daemon}" /workspace
}

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
    # 同 ns 时仍要求心跳不太陈旧。比较失败（非数字、过期）都算死。
    local age ttl
    age="$(_daemon_hb_age)"
    ttl="$(_daemon_hb_ttl)"
    [[ "$age" =~ ^[0-9]+$ && "$ttl" =~ ^[0-9]+$ ]] || return 1
    (( age <= ttl * 2 )) || return 1
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

  [[ -n "$cmd" ]] || i18n_die 2 daemon.daemon_request_command_empty
  [[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s="${CAPBOX_EXEC_TIMEOUT:-600}"
  [[ -n "$cwd" ]] || cwd=/workspace

  if ! daemon_running; then
    i18n_err daemon.daemon_container_not_running_start_first_dsh
    return 3
  fi

  # 服务端正在排空（已收到 stop，等旧任务收尾）：不再接受新请求。
  # 此时投递的请求要么被 _fail_pending 回写 143，要么一直没人消费到超时，
  # 都不如直接拒绝来得清晰。返回 3 与「未运行」一致，调用方可据此重试/重启。
  if _daemon_draining; then
    i18n_err daemon.daemon_container_stopping_draining_flight_tasks_not
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
    i18n_err daemon.unable_write_request_file reqf="$reqf"
    rm -f "$inf" 2>/dev/null || true
    return 1
  }
  # 原子投递：客户端与服务端可能在两个 namespace，靠 rename 保证不读到半截文件
  mv -f "$reqf.tmp" "$reqf" 2>/dev/null || {
    i18n_err daemon.unable_submit_request reqf="$reqf"
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
    i18n_err daemon.guest_command_timed_out_s timeout_s="${timeout_s}"
  elif (( daemon_died == 1 )); then
    i18n_err daemon.daemon_container_stopped_while_command_running_heartbeat
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
  if [[ -z "${CAPBOX_BWRAP_BASELINE_CMD:-}" ]]; then
    CAPBOX_BWRAP_BASELINE_CMD="up"
  fi
  if declare -F sandbox_bwrap_cmd >/dev/null 2>&1; then
    local x errf outf private
    private="$(_capbox_host_state_dir)" || return 1
    errf="$(mktemp "$private/capbox-up-bwrap.XXXXXX")" || return 1
    outf="$(mktemp "$private/capbox-up-argv.XXXXXX")" || { rm -f "$errf"; return 1; }
    local brc=0
    sandbox_bwrap_cmd daemon "" "/workspace" >"$outf" 2>"$errf" || brc=$?
    if (( brc != 0 )); then
      if (( brc != 6 )); then
        i18n_err daemon.unable_build_daemon_container_bwrap_arguments_rc brc="$brc"
      fi
      [[ -s "$errf" ]] && cat "$errf" >&2
      rm -f "$errf" "$outf"
      return "$brc"
    fi
    while IFS= read -r -d '' x; do
      base+=("$x")
    done <"$outf"
    rm -f "$errf" "$outf"
    (( ${#base[@]} > 0 )) || {
      i18n_err daemon.daemon_container_bwrap_arguments_empty
      return 1
    }
  else
    local -a args=()
    local _bbrc=0
    mapfile -t args < <(_daemon_bwrap_args daemon; printf 'CAPBOX_BWRAP_ARGS_RC=%s\n' "$?")
    if [[ ${#args[@]} -gt 0 && "${args[-1]}" == CAPBOX_BWRAP_ARGS_RC=* ]]; then
      _bbrc="${args[-1]#CAPBOX_BWRAP_ARGS_RC=}"
      unset 'args[-1]'
    fi
    if (( _bbrc != 0 )); then
      return "$_bbrc"
    fi
    (( ${#args[@]} > 0 )) || return 1
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
  if declare -F _net_append_ready_bind >/dev/null 2>&1; then
    _net_append_ready_bind _out || return $?
  fi
  if declare -F _idmap_ensure_drop_priv_helper >/dev/null 2>&1 && _idmap_ensure_drop_priv_helper; then
    _out+=(--ro-bind "$(_idmap_drop_priv_host_bin)" "$(_idmap_drop_priv_guest_bin)")
  fi

  # 服务端需要的环境（base 已 --clearenv；此处仅白名单注入 daemon/guest 必需项）
  _out+=(--setenv CAPBOX_DAEMON_DIR "$guest_daemon_dir")
  _out+=(--setenv CAPBOX_DISTRO "$CAPBOX_DISTRO")
  _out+=(--setenv CAPBOX_ROOTFS_HOST "$CAPBOX_ROOTFS")
  _out+=(--setenv CAPBOX_VERSION "$CAPBOX_VERSION")
  _out+=(--setenv CAPBOX_HOSTNAME "$CAPBOX_HOSTNAME")
  _out+=(--setenv CAPBOX_DAEMON_MAXJOBS "${CAPBOX_DAEMON_MAXJOBS:-8}")
  _out+=(--setenv CAPBOX_DAEMON_TICK "${CAPBOX_DAEMON_TICK:-0.2}")
  _out+=(--setenv CAPBOX_DAEMON_BEAT_EVERY "${CAPBOX_DAEMON_BEAT_EVERY:-5}")
  _out+=(--setenv CAPBOX_DAEMON_HB_TTL "${CAPBOX_DAEMON_HB_TTL:-6}")
  _out+=(--setenv CAPBOX_DAEMON_STOP_WAIT "${CAPBOX_DAEMON_STOP_WAIT:-30}")

  # restricted 常驻容器：先等桥的 ready 文件再跑服务端，避免桥还没听就去访问网络。
  if [[ "${CAPBOX_NET_SESSION:-}" == "daemon" ]] && declare -F _net_bridge_ready >/dev/null 2>&1; then
    local ready_guest
    ready_guest="$(_net_guest_path "$(_net_bridge_ready)")" || return 1
    _out+=(
      -- /bin/sh -c
      'f=$1; i=0; while [ ! -f "$f" ]; do i=$((i+1)); [ "$i" -gt 400 ] && exit 1; sleep 0.05; done; shift; exec /bin/sh "$1"'
      sh "$ready_guest" "$guest_guest_script"
    )
  else
    _out+=(-- /bin/sh "$guest_guest_script")
  fi

  if declare -F _security_wrap_argv >/dev/null 2>&1; then
    _security_wrap_argv _out || return $?
  fi
  if declare -F _landlock_apply_argv >/dev/null 2>&1; then
    _landlock_apply_argv _out || return $?
  fi
}

_daemon_systemd_unit_name() {
  local base sum
  base="$(basename "${CAPBOX_WORKSPACE:-workspace}")"
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9' '-')"
  base="${base#-}"
  base="${base%-}"
  [[ -n "$base" ]] || base="workspace"
  if have_cmd sha256sum; then
    sum="$(printf '%s' "${CAPBOX_WORKSPACE:-}" | sha256sum | awk '{print $1}')"
  else
    sum="$(printf '%s' "${CAPBOX_WORKSPACE:-}" | cksum | awk '{print $1}')"
  fi
  printf 'capbox-%s-%s' "${base:0:32}" "${sum:0:12}"
}

# 把 capbox up 交给 systemd --user。调用方（常被外层 bwrap --die-with-parent 包住）可以马上返回。
_daemon_up_via_systemd() {
  command -v systemd-run >/dev/null 2>&1 || i18n_die 5 daemon.capbox_up_systemd_requires_systemd_run
  command -v systemctl >/dev/null 2>&1 || i18n_die 5 daemon.capbox_up_systemd_requires_systemctl
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    i18n_die 5 daemon.user_systemd_unavailable_systemctl_user_has_no
  fi
  local unit cli private
  private="$(_capbox_host_state_dir)" || return 1
  unit="$(_daemon_systemd_unit_name)"
  if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
    local wd
    wd="$(systemctl --user show -p WorkingDirectory --value "$unit" 2>/dev/null || true)"
    if [[ -n "$wd" && "$wd" != "${CAPBOX_WORKSPACE}" ]]; then
      i18n_die 1 daemon.systemd_unit_service_already_running_workingdirectory_which unit="${unit}" wd="${wd}" workspace="${CAPBOX_WORKSPACE}"
    fi
    i18n_info daemon.systemd_unit_service_already_running unit="${unit}"
    mkdir -p "$CAPBOX_RUN_DIR"
    printf '%s\n' "$unit" >"$private/systemd.unit"
    return 0
  fi
  cli="${_CAPBOX_CLI_BIN_DIR:-}/capbox"
  [[ -x "$cli" ]] || cli="$(command -v capbox 2>/dev/null || true)"
  [[ -n "$cli" && -x "$cli" ]] || i18n_die 1 daemon.capbox_executable_not_found_cannot_hand_off
  local -a child_cmd=("$cli")
  if [[ "${CAPBOX_ALLOW_OLD_BWRAP_ONCE:-}" == "1" ]]; then
    child_cmd+=(--allow-old-bwrap)
  fi
  mkdir -p "$CAPBOX_RUN_DIR"
  printf '%s\n' "$unit" >"$private/systemd.unit"
  local -a envargs=()
  local k
  for k in CAPBOX_NET CAPBOX_NET_ALLOW CAPBOX_SECURITY_PROFILE CAPBOX_DISTRO CAPBOX_PROXY CAPBOX_IDMAP CAPBOX_MIRROR CAPBOX_DEBUG; do
    if [[ -n "${!k+x}" ]]; then
      envargs+=(--setenv="${k}=${!k}")
    fi
  done
  envargs+=(--setenv="CAPBOX_ROOT=${CAPBOX_WORKSPACE}")
  envargs+=(--setenv="CAPBOX_UP_SYSTEMD_CHILD=1")
  if [[ "${CAPBOX_LANDLOCK:-}" == "on" || "${CAPBOX_LANDLOCK:-}" == "off" ]]; then
    envargs+=(--setenv="CAPBOX_LANDLOCK=${CAPBOX_LANDLOCK}")
  fi
  i18n_info daemon.handed_off_systemd_user_unit_service_detached unit="${unit}"
  if ! systemd-run --user --collect --unit="$unit" \
    -p "WorkingDirectory=${CAPBOX_WORKSPACE}" \
    "${envargs[@]}" \
    -- "${child_cmd[@]}" up; then
    i18n_err daemon.systemd_run_failed
    return 1
  fi
  i18n_info daemon.unit_submitted_inspect_systemctl_user_status_service unit="${unit}"
  i18n_info daemon.stop_capbox_down
  return 0
}

cmd_up() {
  local use_systemd=0 net_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        i18n_print help.up
        return 0
        ;;
      --systemd)
        use_systemd=1
        shift
        ;;
      --net)
        [[ $# -ge 2 ]] || i18n_die 2 daemon.up_net_requires_mode_none_restricted_open
        net_override="${2}"
        shift 2
        ;;
      --net=*)
        net_override="${1#*=}"
        [[ -n "$net_override" ]] || i18n_die 2 daemon.up_net_requires_mode_none_restricted_open
        shift
        ;;
      *) i18n_die 2 daemon.up_unknown_option arg="$1" ;;
    esac
  done

  if [[ -n "$net_override" ]]; then
    _capbox_declare_net "$net_override" up
  fi

  if (( use_systemd == 1 )) && [[ "${CAPBOX_UP_SYSTEMD_CHILD:-}" != "1" ]]; then
    _daemon_up_via_systemd || return $?
    return 0
  fi

  [[ -x "${CAPBOX_BWRAP:-}" ]] || i18n_die 5 common.bwrap_unavailable_apt_install_bubblewrap bwrap="$(i18n_or "${CAPBOX_BWRAP:-}" val.unset)"
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
  (( rootfs_ok == 1 )) || i18n_die 4 common.rootfs_does_not_exist_run_capbox_init rootfs="$CAPBOX_ROOTFS"
  [[ -f "$CAPBOX_DIR/lib/guest/daemon.sh" ]] || i18n_die 1 daemon.missing_server_script_lib_guest_daemon_sh dir="$CAPBOX_DIR"

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
  local private lockf
  private="$(_capbox_host_state_dir)" || return 1
  lockf="$private/daemon-up.lock"
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
    i18n_info daemon.daemon_container_already_running_pid_no_need pid="$(_daemon_json_num pid 2>/dev/null || echo '?')"
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

  local restricted_daemon=0 use_idmap=0
  if declare -F _net_mode >/dev/null 2>&1; then
    local _nm
    _nm="$(_net_mode)" || return $?
    if [[ "$_nm" == "restricted" ]]; then
      restricted_daemon=1
      export CAPBOX_NET_SESSION=daemon
      _net_restricted_prereqs >/dev/null || return $?
      _net_start_host_proxy || return 1
      mkdir -p "$(_net_dir)"
      rm -f "$(_net_dir)/daemon-child.pid" 2>/dev/null || true
      # idmap 在放行 guest 之前把 sandbox pid 写到这个文件；cmd_up 再去挂桥。
      _idmap_after_map_hook() {
        printf '%s\n' "$1" >"$(_net_dir)/daemon-child.pid"
      }
    fi
  fi

  local -a argv=()
  local _up_rc=0
  _daemon_build_up_argv argv || _up_rc=$?
  if (( _up_rc == 6 )); then
    die 6
  fi
  if (( _up_rc != 0 )); then
    i18n_die "$_up_rc" daemon.unable_build_bwrap_command
  fi
  (( ${#argv[@]} > 0 )) || i18n_die 1 daemon.unable_build_bwrap_command

  local idmap_rc=1
  if declare -F _capbox_idmap_decision >/dev/null 2>&1; then
    idmap_rc=0
    _capbox_idmap_decision || idmap_rc=$?
  elif declare -F _idmap_enabled >/dev/null 2>&1; then
    idmap_rc=0
    _idmap_enabled || idmap_rc=$?
  fi
  if (( idmap_rc == 2 )); then
    (( restricted_daemon == 1 )) && _net_cleanup_restricted_session
    return 1
  fi
  if (( idmap_rc == 0 )); then
    use_idmap=1
  fi

  local info=""
  if (( restricted_daemon == 1 && use_idmap == 0 )); then
    _net_inject_bwrap_info_fd argv 3 || {
      _net_cleanup_restricted_session
      return 1
    }
    info="$(_net_dir)/daemon-info.json"
    rm -f "$info"
  fi

  i18n_info daemon.starting_daemon_container_rootfs rootfs="$CAPBOX_ROOTFS"

  local child="" got_signal=0
  # 收到 TERM/INT：写 ctl/stop 让服务端优雅退出（它自己清理 daemon.json）
  _daemon_up_on_signal() {
    got_signal=1
    : > "$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || true
    i18n_info daemon.got_termination_signal_asking_daemon_container_shut
  }
  trap _daemon_up_on_signal TERM INT

  if (( use_idmap == 1 )); then
    CAPBOX_IDMAP_SPAWN_LOG="$logf"
    child="$(_idmap_spawn_bwrap_argv "${argv[@]}")" || {
      i18n_err daemon.idmap_failed_start_daemon_container detail="${CAPBOX_IDMAP_DETAIL:-unknown}"
      (( restricted_daemon == 1 )) && _net_cleanup_restricted_session
      trap - TERM INT
      return 1
    }
  elif (( restricted_daemon == 1 )); then
    "${argv[@]}" 3>"$info" >>"$logf" 2>&1 &
    child=$!
  else
    "${argv[@]}" >>"$logf" 2>&1 &
    child=$!
  fi

  if (( restricted_daemon == 1 )); then
    local sandboxed=""
    if [[ -s "$(_net_dir)/daemon-child.pid" ]]; then
      sandboxed="$(tr -d '[:space:]' <"$(_net_dir)/daemon-child.pid")"
    elif [[ -n "$info" ]]; then
      sandboxed="$(_net_wait_info_child "$info" "$child" || true)"
    fi
    if [[ -z "$sandboxed" ]] || ! _net_start_bridge_for_child "$sandboxed"; then
      i18n_err daemon.restricted_daemon_container_network_bridge_not_ready path="$(_net_dir)"
      kill "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      _net_cleanup_restricted_session
      trap - TERM INT
      return 1
    fi
    i18n_info daemon.restricted_daemon_container_allowlist_proxy_bridge_ready
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
    i18n_info daemon.got_termination_signal_waiting_daemon_container_exit
    _daemon_release_up_lock
  elif [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" ]]; then
    i18n_info daemon.daemon_container_ready_guest_pid_hostname pid="$(_daemon_json_num pid 2>/dev/null || echo '?')" hostname="${CAPBOX_HOSTNAME}"
    i18n_info daemon.ipc_directory daemon_dir="$CAPBOX_DAEMON_DIR"
    i18n_info daemon.stop_capbox_down_end_background_task_hosts
    _daemon_release_up_lock
  elif ! kill -0 "$child" 2>/dev/null; then
    local brc=0
    wait "$child" 2>/dev/null
    brc=$?
    i18n_err daemon.daemon_container_failed_start_exit_recent_logs brc="$brc"
    tail -n 20 -- "$logf" >&2 2>/dev/null || true
    _daemon_clear_state
    _daemon_release_up_lock
    trap - TERM INT
    if [[ "${CAPBOX_NET_SESSION:-}" == "daemon" ]] && declare -F _net_cleanup_restricted_session >/dev/null 2>&1; then
      _net_cleanup_restricted_session
    fi
    return 1
  else
    # 既没就绪、进程也还在（20s 超时）：不当成失败，继续前台托管，
    # 但要放锁，别让后续 up 被阻塞。
    i18n_warn daemon.daemon_container_did_not_write_daemon_json logf="$logf"
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
    i18n_warn daemon.new_instance_has_taken_over_iid_keeping cur_iid="${cur_iid:0:8}"
  else
    _daemon_clear_state
  fi
  rm -f "$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || true
  rm -rf "$CAPBOX_DAEMON_DIR/ctl/kill" 2>/dev/null || true

  i18n_info daemon.daemon_container_stopped_exit rc="$rc"
  if [[ "${CAPBOX_NET_SESSION:-}" == "daemon" ]] && declare -F _net_cleanup_restricted_session >/dev/null 2>&1; then
    _net_cleanup_restricted_session
  fi
  return "$rc"
}

# =============================================================================
# 5. down（停止）
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
      -h | --help) i18n_print help.down; return 0 ;;
      *) i18n_die 2 daemon.down_unknown_option arg="$1" ;;
    esac
  done

  local private
  private="$(_capbox_host_state_dir)" || return 1
  if [[ -f "$private/systemd.unit" ]] && command -v systemctl >/dev/null 2>&1; then
    local unit
    unit="$(tr -d '[:space:]' <"$private/systemd.unit" 2>/dev/null || true)"
    if [[ -n "$unit" ]] && systemctl --user is-active --quiet "$unit" 2>/dev/null; then
      i18n_info daemon.stopping_systemd_unit_service unit="${unit}"
      systemctl --user stop "$unit" || return 1
      rm -f "$private/systemd.unit"
      return 0
    fi
  fi

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
      i18n_warn daemon.orphan_server_detected_fresh_heartbeat_no_daemon
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
        i18n_err daemon.orphan_server_did_not_exit_within_10s
        i18n_err daemon.suggestion_end_tty_job_hosts_delete_hb daemon_dir="$CAPBOX_DAEMON_DIR"
        return 1
      fi
      i18n_info daemon.orphan_server_has_exited
      _daemon_clear_state
      return 0
    fi

    if [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" || -f "$CAPBOX_DAEMON_DIR/hb" || -d "$CAPBOX_DAEMON_DIR/lock.d" ]]; then
      staleness=1
      i18n_warn daemon.stale_state_files_found_daemon_process_gone
      _daemon_clear_state
    else
      i18n_info daemon.daemon_container_not_running
    fi
    return 3
  fi

  local pid
  pid="$(_daemon_json_num pid 2>/dev/null || echo '?')"
  i18n_info daemon.stopping_daemon_container_guest_pid pid="$pid"

  _daemon_ensure_dirs
  : >"$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || {
    i18n_err daemon.unable_write_ctl_stop daemon_dir="$CAPBOX_DAEMON_DIR"
    return 1
  }

  # 等服务端收尾：daemon.json 消失即视为已退出。
  #
  # 但**不能盲等满 limit**：若服务端其实早已死了（崩溃/SIGKILL，只是 hb 还新鲜
  # 让 daemon_running 误判为活），没有任何进程会消费 ctl/stop，daemon.json 永远
  # 不会消失，于是 down 会白等满 40s 才走超时分支。实测过这种情况（27s 才返回）。
  #
  # 判据：服务端一旦真正响应 ctl/stop，会往 daemon.log 写「received stop request」。
  # 宿主临时同时接受旧短语「收到停止请求」，这是一次升级兼容：已在跑的旧服务端
  # 仍会写那条中文日志；新服务端只写英文标记。若只认新标记，capbox down 会在
  # 5s NOACK 后把仍在排空的旧 daemon 当死进程清掉。
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
      if tail -n +$(( logbase + 1 )) -- "$logf" 2>/dev/null | grep -q -e 'received stop request' -e '收到停止请求'; then
        acked=1
      fi
    fi
    if (( acked == 0 )) && (( waited >= noack * 10 )); then
      i18n_warn daemon.server_did_not_acknowledge_stop_request_within noack="${noack}"
      _daemon_clear_state
      rm -f "$CAPBOX_DAEMON_DIR/ctl/stop" 2>/dev/null || true
      rm -rf "$CAPBOX_DAEMON_DIR/ctl/kill" 2>/dev/null || true
      i18n_info daemon.daemon_container_stopped
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done

  if [[ -f "$CAPBOX_DAEMON_DIR/daemon.json" ]]; then
    i18n_warn daemon.daemon_container_did_not_exit_within_s limit="$limit"
    i18n_warn daemon.cannot_force_kill_across_pid_namespace_container
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
  i18n_info daemon.daemon_container_stopped
  return 0
}

# =============================================================================
# 6. status（状态）
# =============================================================================

cmd_status() {
  local json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      -h | --help) i18n_print help.status; return 0 ;;
      *) i18n_die 2 common.status_unknown_option arg="$1" ;;
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
      "$(json_escape "${CAPBOX_VERSION:-0.4.2}")"
    return 0
  fi

  local rootfs_state
  if (( rootfs_ok == 1 )); then
    rootfs_state="$(i18n_get status.state_ready)"
  else
    rootfs_state="$(i18n_get status.state_missing)"
  fi

  printf '%s\n' "$(i18n_fmt status.label_distro value="$CAPBOX_DISTRO")"
  printf '%s\n' "$(i18n_fmt status.label_rootfs path="$CAPBOX_ROOTFS" state="$rootfs_state" size="$(human_bytes "$bytes")")"
  if [[ "$running" == true ]]; then
    printf '%s\n' "$(i18n_fmt status.daemon_running pid="$pid" uptime="$uptime")"
    local hb_age
    hb_age="$(_daemon_hb_age)"
    printf '%s\n' "$(i18n_fmt status.heartbeat age="$hb_age" ttl="$(_daemon_hb_ttl)")"
    printf '%s\n' "$(i18n_fmt status.ipc path="$CAPBOX_DAEMON_DIR")"
    printf '%s\n' "$(i18n_fmt status.log path="$CAPBOX_DAEMON_DIR/daemon.log")"
  else
    printf '%s\n' "$(i18n_get status.daemon_stopped_hint)"
  fi
  printf '%s\n' "$(i18n_fmt status.label_net value="${CAPBOX_NET:-host}")"
  if [[ "${CAPBOX_MIRROR:-cn}" == "none" ]]; then
    printf '%s\n' "$(i18n_get status.mirror_none)"
  else
    [[ -n "$mirror_url" ]] || mirror_url="$(i18n_get status.mirror_url_unset)"
    printf '%s\n' "$(i18n_fmt status.label_mirror mirror="${CAPBOX_MIRROR:-cn}" url="$mirror_url")"
  fi
  if [[ -n "${CAPBOX_PROXY:-}" ]]; then
    printf '%s\n' "$(i18n_fmt status.label_proxy value="$CAPBOX_PROXY")"
  else
    printf '%s\n' "$(i18n_get status.proxy_none)"
  fi
  printf '%s\n' "$(i18n_fmt status.label_hostname value="${CAPBOX_HOSTNAME:-capbox}")"
  printf '%s\n' "$(i18n_fmt status.label_bwrap value="$(i18n_or "${CAPBOX_BWRAP:-}" val.unset)")"
  printf '%s\n' "$(i18n_fmt status.label_workspace value="$CAPBOX_WORKSPACE")"
  printf '%s\n' "$(i18n_fmt status.label_version value="${CAPBOX_VERSION:-0.4.2}")"
  return 0
}

# =============================================================================
# 7. logs（日志）
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
        i18n_print help.logs
        return 0
        ;;
      *) i18n_die 2 daemon.logs_unknown_option arg="$1" ;;
    esac
  done
  [[ "$lines" =~ ^[0-9]+$ ]] || i18n_die 2 daemon.logs_n_must_non_negative_integer

  local logf="$CAPBOX_DAEMON_DIR/daemon.log"
  if [[ ! -f "$logf" ]]; then
    i18n_info daemon.no_daemon_container_logs_yet_does_not logf="$logf"
    return 0
  fi

  if (( follow == 1 )); then
    tail -n "$lines" -f -- "$logf"
    return $?
  fi
  tail -n "$lines" -- "$logf"
  return 0
}
