#!/usr/bin/env bash
# T16 — daemon 并发：并行 4 个 exec --daemon，都返回 0，无串扰
# 契约 §5：服务端最多并发 8 个，客户端按 id 隔离 req/out。
# 无串扰判据：每个请求写独有内容并读回，内容必须一一对应（不是别人的输出）。
set -u
CASE_TITLE="daemon 并发：4 个 exec --daemon 并行无串扰"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

# 先判定开关门控，再判定前置条件（理由见 t15.sh）
if ! require_daemon; then case_finish; exit 0; fi
require_rootfs || { case_finish; exit 0; }

N=4
run_tag="$RANDOM$RANDOM"
pids=()
ros=()
for i in $(seq 1 "$N"); do
  o="$CASE_OUT/parallel-$i.out"
  e="$CASE_OUT/parallel-$i.err"
  tok="tag-${run_tag}-${i}"
  announce "$CAPBOX_BIN exec --daemon -- sh -c 'echo $tok; sleep 0.3; echo $tok-end'"
  # 每个请求输出自己的 token，并用 sleep 制造重叠窗口
  ( "$CAPBOX_BIN" exec --daemon -- sh -c "echo $tok; sleep 0.3; echo $tok-end" ) >"$o" 2>"$e" &
  pids+=($!)
  ros+=("$o|$e|$tok")
done

all_rc_ok=1
for idx in "${!pids[@]}"; do
  wait "${pids[$idx]}"
  rc=$?
  entry="${ros[$idx]}"
  o="${entry%%|*}"
  rest="${entry#*|}"
  e="${rest%%|*}"
  tok="${rest#*|}"
  printf '    [并发 %s] rc=%s token=%s\n' "$((idx + 1))" "$rc" "$tok"
  sed 's/^/      out: /' "$o"
  [ -s "$e" ] && sed 's/^/      err: /' "$e"
  if [ "$rc" != "0" ]; then
    all_rc_ok=0
    _fail "并发请求 #$((idx + 1)) 期望 rc=0，实际 $rc" \
      "stderr: $(_short "$(cat "$e" 2>/dev/null)")"
    continue
  fi
  CASE_ASSERTS=$((CASE_ASSERTS + 1))
  # 无串扰：输出必须恰好是本请求的两行 token，且不能包含其它请求的 token
  expected="$tok
$tok-end"
  got=$(cat "$o")
  if [ "$got" != "$expected" ]; then
    CASE_FAILS=$((CASE_FAILS + 1))
    _fail "并发请求 #$((idx + 1)) 输出串扰" "期望: [$expected]" "实际: [$got]"
    continue
  fi
  # 显式检查不含别的 token（前缀相同，靠 -i 后缀区分）
  others=$(for j in $(seq 1 "$N"); do [ "$j" = "$((idx + 1))" ] || printf 'tag-%s-%s\n' "$run_tag" "$j"; done)
  leaked=""
  while IFS= read -r ot; do
    [ -z "$ot" ] && continue
    printf '%s' "$got" | grep -qF -- "$ot" && leaked+="$ot "
  done <<<"$others"
  if [ -n "$leaked" ]; then
    CASE_FAILS=$((CASE_FAILS + 1))
    _fail "并发请求 #$((idx + 1)) 出现了其它请求的内容：$leaked" "实际输出: $got"
  else
    _ok "并发请求 #$((idx + 1)) rc=0 且输出隔离"
  fi
done

if [ "$all_rc_ok" = "1" ]; then
  _ok "$N 个并发请求全部返回 0"
fi

# 并发后 daemon 仍存活
run_cmd "$CAPBOX_BIN" status --json
assert_json_value "daemon.running" "true" "并发后 daemon 仍 running"

# 契约 §5：服务端最多并发 8 个，不应在并发后留下堆积的请求/输出文件
req_dir="$CAPBOX_DIR/run/daemon/req"
out_dir="$CAPBOX_DIR/run/daemon/out"
for d in "$req_dir" "$out_dir"; do
  if [ -d "$d" ]; then
    leftover=$(find "$d" -maxdepth 1 -type f | wc -l)
    if [ "$leftover" -le 2 ]; then
      _ok "并发后 $(basename "$d")/ 无堆积（剩 $leftover 个文件）"
    else
      _fail "并发后 $(basename "$d")/ 残留 $leftover 个文件（契约 §5：客户端应清理）"
    fi
  fi
done

case_finish
exit 0
