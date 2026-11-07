#!/bin/sh
# shellcheck shell=sh
# =============================================================================
# CapBox —— 容器内常驻服务端（guest/daemon.sh）
#
# 本脚本在**容器内**以 /bin/sh 运行，是 `capbox up` 启动的守护容器的服务端。
# 宿主侧客户端见 ../daemon.sh。
#
# 目录（容器内视角，= 宿主的 <workspace>/.capbox/run/daemon/）：
#   daemon.json    服务端启动时写入，退出时删除（宿主据此判断活性）
#   hb             心跳文件，周期性 touch（宿主据此判断活性，见下）
#   req/<id>.sh    客户端投递的请求脚本
#   out/<id>.log   请求的 stdout+stderr
#   out/<id>.rc    请求完成标记，内容为退出码
#   ctl/stop       touch 后优雅退出
#   running/<id>   在跑任务标记（并发计数用），任务结束即删除
#   lock.d/        防重入锁（mkdir 原子性）
#
# 为什么需要心跳文件：
#   DSH 的 bash 工具每次调用都在**新的 PID namespace** 里（已实测：前台调用
#   pid:[4026532245]、后台 job pid:[4026532237]，两者 $$ 都为 2）。因此宿主侧
#   客户端无法用 kill -0 <pid> 判断容器内进程死活——那个 pid 在客户端的
#   namespace 里根本不存在，甚至会误命中无关进程。活性只能靠共享文件系统上的
#   心跳（mtime）来判定。
#
# 设计要点：
#   * POSIX sh：不使用 local / 数组 / [[ ]]，兼容 busybox ash 与 dash。
#   * 主循环绝不阻塞：请求丢到后台子 shell 执行，本进程持续 0.2s 轮询。
#   * 并发上限 8（CAPBOX_DAEMON_MAXJOBS），用 running/ 下的标记文件计数。
#   * 收到 ctl/stop 或 TERM/INT 时：等在跑任务完成（有上限），回写未完成请求的
#     退出码 143，清理状态文件后退出。
# =============================================================================

set -u

# ---------- 0. 配置（全部可由宿主经 bwrap --setenv 注入） ----------------------

# IPC 目录总是由宿主侧经 --setenv CAPBOX_DAEMON_DIR 注入（见 lib/daemon.sh）。
# 这里的兜底只在手动调试本脚本时生效，因此写成容器内的通用位置，
# 不写死 ".capbox" —— 仓库可能以任意目录名存在（见 CONTRIBUTING.md）。
D="${CAPBOX_DAEMON_DIR:-/workspace/.capbox-run/daemon}"
REQ="$D/req"
OUT="$D/out"
CTL="$D/ctl"
RUN="$D/running"
HB="$D/hb"
JSON="$D/daemon.json"
LOCKD="$D/lock.d"

MAXJOBS="${CAPBOX_DAEMON_MAXJOBS:-8}"
TICK="${CAPBOX_DAEMON_TICK:-0.2}"          # 轮询间隔（秒）
BEAT_EVERY="${CAPBOX_DAEMON_BEAT_EVERY:-5}" # 每 N 个 tick 写一次心跳（0.2*5=1s）
STOP_WAIT="${CAPBOX_DAEMON_STOP_WAIT:-30}"  # 停止时等待在跑任务的上限（秒）
HB_TTL="${CAPBOX_DAEMON_HB_TTL:-6}"         # 心跳陈旧阈值（秒），客户端也读这个值

DISTRO="${CAPBOX_DISTRO:-alpine}"
ROOTFS_HOST="${CAPBOX_ROOTFS_HOST:-}"
VERSION="${CAPBOX_VERSION:-0.3.6}"

# 数字型配置兜底校验（非法值一律回落默认，避免 set -u/算术炸掉）
case "$MAXJOBS" in ''|*[!0-9]*) MAXJOBS=8 ;; esac
case "$BEAT_EVERY" in ''|*[!0-9]*|0) BEAT_EVERY=5 ;; esac
case "$STOP_WAIT" in ''|*[!0-9]*) STOP_WAIT=30 ;; esac
case "$HB_TTL" in ''|*[!0-9]*) HB_TTL=6 ;; esac

JOBS=""        # 形如 " <id>:<pid> <id>:<pid>"
STOPPING=0
TICKN=0
STARTED=0

# ---------- 1. 基础工具 --------------------------------------------------------

log() { printf '[capbox-daemon] %s\n' "$*"; }

_file_mtime() {
  stat -c %Y "$1" 2>/dev/null || printf '0'
}

_now() { date +%s 2>/dev/null || printf '0'; }

# 路径里的 " 和 \ 转义，保证 daemon.json 是合法 JSON
_json_esc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# 原子写：写 .tmp 再 mv
_write_atomic() {
  _dst="$1"; _val="$2"
  printf '%s\n' "$_val" > "$_dst.tmp" 2>/dev/null || return 1
  mv -f "$_dst.tmp" "$_dst" 2>/dev/null
}

# ---------- 2. 状态清理（必须可重入、绝不因文件缺失报错） ----------------------

cleanup_state() {
  rm -f "$JSON" "$JSON.tmp" "$HB" "$HB.tmp" 2>/dev/null
  rm -rf "$RUN" 2>/dev/null
  rm -rf "$LOCKD" 2>/dev/null
}

on_term() {
  STOPPING=1
  log "收到终止信号（TERM/INT），准备优雅退出"
}

trap on_term TERM INT

# ---------- 3. 启动：建目录、防重入、写 daemon.json ----------------------------

mkdir -p "$REQ" "$OUT" "$CTL" "$RUN" 2>/dev/null || {
  log "无法创建 IPC 目录: $D（/workspace 是否已 bind 进容器？）"
  exit 1
}

# 防重入：mkdir 是原子的。拿不到锁时先看上一个实例是否还活着（心跳新鲜）。
if ! mkdir "$LOCKD" 2>/dev/null; then
  _hb_age=$(( $( _now ) - $( _file_mtime "$HB" ) ))
  if [ -f "$HB" ] && [ "$_hb_age" -ge 0 ] && [ "$_hb_age" -le "$HB_TTL" ]; then
    log "已有守护容器在运行（心跳新鲜，${_hb_age}s 前），本实例退出"
    exit 0
  fi
  log "发现陈旧锁（心跳 ${_hb_age}s 未更新），接管"
  rm -rf "$LOCKD" 2>/dev/null
  mkdir "$LOCKD" 2>/dev/null || {
    log "无法获得守护容器锁，退出"
    exit 1
  }
fi

# 只有拿到锁的进程才能清状态。失败者退出不得删掉活着的那一份。
trap cleanup_state EXIT

STARTED="$(_now)"
PIDNS="$(readlink /proc/self/ns/pid 2>/dev/null || printf 'unknown')"
HOSTN="$(hostname 2>/dev/null || printf '%s' "${CAPBOX_HOSTNAME:-capbox}")"

# 全局唯一的实例 ID（instance generation id）。
# 为什么需要它：客户端的 cmd_up 退出时要判断「现在这份 daemon.json 还是我那份吗」，
# 不是的话就不能删（否则会把新实例的状态删掉）。
#   * 不能用 pid —— 容器内服务端永远是 pid 2，每个实例都一样；
#   * 不能用 pidns —— 命名空间 inode 在销毁后会被内核复用
#     （实测：run1 pidns=4026532252、run3 又是 4026532252），同样不可靠。
# 所以由服务端自己生成一个随机 ID 写进 daemon.json，天然区分世代。
INSTANCE_ID=""
INSTANCE_ID="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
[ -n "$INSTANCE_ID" ] || INSTANCE_ID="$( _now )-$$"

write_json() {
  printf '{"pid":%s,"started_at":%s,"distro":"%s","rootfs":"%s","v":1,"pidns":"%s","iid":"%s","hostname":"%s","version":"%s","maxjobs":%s,"tick":%s,"hb_ttl":%s}\n' \
    "$$" "$STARTED" \
    "$(_json_esc "$DISTRO")" "$(_json_esc "$ROOTFS_HOST")" \
    "$(_json_esc "$PIDNS")" "$(_json_esc "$INSTANCE_ID")" \
    "$(_json_esc "$HOSTN")" "$(_json_esc "$VERSION")" \
    "$MAXJOBS" "$TICK" "$HB_TTL" \
    > "$JSON.tmp" 2>/dev/null && mv -f "$JSON.tmp" "$JSON" 2>/dev/null
}

beat() { _write_atomic "$HB" "$(_now)" >/dev/null 2>&1; }

beat
write_json

log "守护容器已启动（pid=$$ hostname=$HOSTN distro=$DISTRO 并发上限=$MAXJOBS 轮询=${TICK}s）"
log "IPC 目录: $D"

# ---------- 4. 任务管理 --------------------------------------------------------

# _prune：回收已完成的任务，维护 JOBS 与并发计数
_prune() {
  _nj=""
  for _e in $JOBS; do
    _jid="${_e%%:*}"
    _jpid="${_e#*:}"
    if [ -f "$RUN/$_jid" ] && kill -0 "$_jpid" 2>/dev/null; then
      _nj="$_nj $_e"
    else
      # 任务已结束（或标记被清）：立刻 wait 回收，避免僵尸堆积。
      # 标记文件由 run_one 在最后一步删除，所以这里的 wait 基本是瞬时的。
      wait "$_jpid" 2>/dev/null
      rm -f "$RUN/$_jid" 2>/dev/null
    fi
  done
  JOBS="$_nj"
}

_jobs_count() {
  _jcnt=0
  for _e in $JOBS; do _jcnt=$((_jcnt + 1)); done
  printf '%s' "$_jcnt"
}

# run_one ID SCRIPT —— 在后台子 shell 里执行一个请求，写 out/ID.log 与 out/ID.rc
#
# 用 setsid 把请求放进**独立进程组**（sid == 该组 pgid），并记到 running/ID.pg。
# 这样客户端超时想放弃时，服务端可以 kill -TERM -<pgid> 杀掉整组（含孙进程），
# 而不是只杀掉那层 sh 让真正的 sleep/服务进程变孤儿。
run_one() {
  _rid="$1"
  _rf="$2"

  # 若宿主没有 setsid，退化为同组执行（超时只能杀到直接子进程）
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c 'echo $$ > "$1"; shift; exec sh "$@"' _ \
      "$RUN/$_rid.pg" "$_rf" > "$OUT/$_rid.log" 2>&1
  else
    sh "$_rf" > "$OUT/$_rid.log" 2>&1
  fi
  _rrc=$?

  # 客户端已经因超时放弃（rc 已被写成 124），不要覆盖它
  if [ ! -f "$OUT/$_rid.rc" ]; then
    printf '%s\n' "$_rrc" > "$OUT/$_rid.rc.tmp" 2>/dev/null
    mv -f "$OUT/$_rid.rc.tmp" "$OUT/$_rid.rc" 2>/dev/null
  fi
  rm -f "$RUN/$_rid" "$RUN/$_rid.sh" "$RUN/$_rid.pg" 2>/dev/null
}

# _reap_kills：处理客户端的超时放弃请求 ctl/kill/<id>
#   客户端在超时后 touch ctl/kill/<id>，我们杀掉该请求的进程组并写 rc=124。
_reap_kills() {
  [ -d "$CTL/kill" ] || return 0
  for _kf in "$CTL"/kill/*; do
    [ -e "$_kf" ] || continue
    _kid="${_kf##*/}"
    # 只杀仍然在跑的请求：RUN 标记已消失说明它已自然结束，
    # 此时 pgid 可能已被系统复用，盲目 kill 会误伤无关进程。
    if [ -f "$RUN/$_kid" ]; then
      _kpg="$(cat "$RUN/$_kid.pg" 2>/dev/null | tr -d '[:space:]')"

      # 先落 rc=124，再杀进程组。
      # 顺序很重要：kill 之后 run_one 会拿到 143/137 并尝试写 rc，而 run_one 只在
      # rc 不存在时才写；先把 124 写下去，才能保证客户端看到的是契约规定的 124
      # 而不是被信号杀死的 143。
      # 注意：不往 out/ID.log 追加任何说明性文字 —— 那份日志会被客户端原样打到
      # stdout，而契约 §3.3 要求 exec 的 stdout 只含容器内命令的输出。
      if [ ! -f "$OUT/$_kid.rc" ]; then
        printf '124\n' > "$OUT/$_kid.rc.tmp" 2>/dev/null
        mv -f "$OUT/$_kid.rc.tmp" "$OUT/$_kid.rc" 2>/dev/null
      fi
      # 取消标记：被杀掉的 shell 会把 "Terminated" 之类的噪声写进 .log，
      # 客户端据此过滤，保证 stdout 只含容器内命令的真实输出（契约 §3.3）。
      : > "$OUT/$_kid.cx" 2>/dev/null

      case "$_kpg" in
        ''|*[!0-9]*) ;; # 无有效 pgid（没装 setsid），跳过
        *)
          kill -TERM "-$_kpg" 2>/dev/null
          sleep 0.3
          kill -KILL "-$_kpg" 2>/dev/null
          log "已取消超时请求 $_kid（进程组 $_kpg）"
          ;;
      esac
    fi
    rm -f "$_kf" 2>/dev/null
  done
}

# _fail_pending：退出前把未完成的请求全部回写 143，避免客户端干等到超时。
# 只写 rc，不改写 out/ID.log —— 那份日志会原样进客户端 stdout，契约 §3.3 要求
# 它只含容器内命令的输出。
_fail_pending() {
  for _f in "$REQ"/*.sh "$RUN"/*.sh; do
    [ -e "$_f" ] || continue
    _b="${_f##*/}"
    _id="${_b%.sh}"
    _pg="$(cat "$RUN/$_id.pg" 2>/dev/null | tr -d '[:space:]')"
    case "$_pg" in
      ''|*[!0-9]*) ;;
      *) kill -TERM "-$_pg" 2>/dev/null ;;
    esac
    if [ ! -f "$OUT/$_id.rc" ]; then
      printf '143\n' > "$OUT/$_id.rc.tmp" 2>/dev/null
      mv -f "$OUT/$_id.rc.tmp" "$OUT/$_id.rc" 2>/dev/null
    fi
    # 取消标记（同上：客户端据此过滤被信号杀死时 shell 打的噪声行）
    : > "$OUT/$_id.cx" 2>/dev/null
    rm -f "$_f" 2>/dev/null
  done
}

# ---------- 5. 主循环 ----------------------------------------------------------

# 自愈：外部可能把整个 run/daemon 删掉（`rm -rf .capbox/run/daemon`、某些清理脚本）。
# 骨架只在启动时建过一次，被删后本进程不会重建 —— 于是变成 **orphan**：
# 服务端还活着、还在 beat()、还能消费 req/，但 daemon.json 没了，
# 客户端 daemon_running 判 false，于是既用不了它也停不掉它（down 走"未运行"分支）。
# 这个函数在主循环里定期调用，保证骨架和 daemon.json 存在。
_self_heal() {
  [ -d "$REQ" ] || mkdir -p "$REQ" "$OUT" "$CTL" "$RUN" 2>/dev/null
  [ -d "$OUT" ] || mkdir -p "$OUT" 2>/dev/null
  [ -d "$CTL" ] || mkdir -p "$CTL" 2>/dev/null
  [ -d "$RUN" ] || mkdir -p "$RUN" 2>/dev/null
  [ -d "$LOCKD" ] || mkdir -p "$LOCKD" 2>/dev/null
  # daemon.json 是客户端的"结构性存在标志"，丢了就重写（内容不变，iid 不变，
  # 因此不会打断既有的世代判断）。
  [ -f "$JSON" ] || write_json
}

while :; do
  TICKN=$((TICKN + 1))

  # 5.0 自愈（每 10 个 tick 检查一次，约每 2s）
  if [ $((TICKN % 10)) -eq 1 ]; then
    _self_heal
  fi

  # 5.1 心跳（每 BEAT_EVERY 个 tick 一次）
  if [ "$TICKN" -eq 1 ] || [ $((TICKN % BEAT_EVERY)) -eq 0 ]; then
    beat
  fi

  # 5.2 回收已完成任务
  _prune

  # 5.2b 处理客户端超时放弃的请求
  _reap_kills

  # 5.3 派发新请求
  _paused=0
  for _f in "$REQ"/*.sh; do
    [ -e "$_f" ] || continue

    # 并发已满：先等空位（期间持续心跳）。等太久说明有长任务占满，
    # 本轮先不派发，留给下一个 tick，避免主循环卡死影响 ctl/stop 响应。
    if [ "$(_jobs_count)" -ge "$MAXJOBS" ]; then
      _w=0
      while [ "$(_jobs_count)" -ge "$MAXJOBS" ] && [ "$_w" -lt 200 ]; do
        _prune
        beat
        if [ -f "$CTL/stop" ]; then
          STOPPING=1
          break
        fi
        [ "$(_jobs_count)" -lt "$MAXJOBS" ] && break
        _w=$((_w + 1))
        sleep 0.05
      done
      if [ "$(_jobs_count)" -ge "$MAXJOBS" ]; then
        _paused=1
        break
      fi
    fi
    if [ -f "$CTL/stop" ] || [ "$STOPPING" -eq 1 ]; then
      STOPPING=1
      break
    fi

    # 原子认领：mv 走请求文件，避免同一请求被派发两次
    _id="${_f##*/}"
    _id="${_id%.sh}"
    mv -f "$_f" "$RUN/$_id.sh" 2>/dev/null || continue

    : > "$RUN/$_id" 2>/dev/null
    run_one "$_id" "$RUN/$_id.sh" &
    JOBS="$JOBS $_id:$!"
  done
  [ "$_paused" -eq 1 ] && log "并发已达上限 $MAXJOBS，本轮暂缓派发新请求"

  # 5.4 停止判定
  if [ -f "$CTL/stop" ] || [ "$STOPPING" -eq 1 ]; then
    log "收到停止请求，等待在跑任务完成（上限 ${STOP_WAIT}s）"

    # 排空期**必须继续 beat()**，原因是一个真实踩过的矛盾：
    #   * 若排空期不发心跳，则 hb 会在 STOP_WAIT 内停止前进；
    #     而客户端 exec 的死判是「hb_age > hb_ttl(6s) => daemon 死」，
    #     于是排空超过 6s 时，**正在等的长任务会被客户端自己放弃**（实测 rc=3，
    #     长任务 sleep 12 排在排空中被判"心跳失联"，输出丢失）。这是回归 bug。
    #   * 但排空期若发心跳，down 返回后 hb 会被服务端写回（"复活"问题）。
    #
    # 两个需求不矛盾，只是语义没拆开：
    #   hb       = 「进程还活着」（排空期间依然成立，必须继续发）
    #   draining = 「不再接新活」（排空开始就写，让客户端知道不要再投递新请求）
    # 而 down 的 hb 残留问题，改由「服务端在退出时自己删 hb」+「客户端 down 在
    # 服务端确认退出后清理」共同覆盖（见 cmd_down 的 NOACK 逻辑）。
    _write_atomic "$CTL/draining" "$(_now)" >/dev/null 2>&1
    # 排空上限按**秒**计，不能拿 STOP_WAIT 直接当循环次数：
    # 每轮 sleep 0.2s，若 `_waited >= STOP_WAIT` 就 break，实际只等 STOP_WAIT*0.2 秒
    # （STOP_WAIT=30 时只有 6 秒！）。这曾把 12 秒的长任务在排空 6 秒时强行掐断，
    # 任务返回 143、输出丢失。改成用 _deadline 比较墙钟时间。
    _deadline=$(( $(_now) + STOP_WAIT ))
    while :; do
      _prune
      [ -z "$JOBS" ] && break
      [ "$(_now)" -ge "$_deadline" ] && {
        log "仍有任务未完成，已到排空上限 ${STOP_WAIT}s，强制退出（其请求将被取消）"
        break
      }
      sleep 0.2
      beat
    done
    # 排空结束：删心跳 + draining，让「hb 存在 = 进程还活着」恢复为严格不变式。
    # EXIT trap 的 cleanup_state 也会删，这里提前删以缩短窗口。
    rm -f "$HB" "$HB.tmp" 2>/dev/null
    rm -f "$CTL/draining" 2>/dev/null
    _fail_pending
    rm -f "$CTL/stop" 2>/dev/null
    log "守护容器退出（运行 $(( $(_now) - STARTED ))s，已处理的请求共 $TICKN 轮）"
    exit 0
  fi

  sleep "$TICK"
done
