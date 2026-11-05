#!/usr/bin/env bash
# CapBox restricted 网络真实证据（默认可单独跑；不进默认 CI）
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CB="$ROOT/bin/capbox"
# 使用仓库项目自身 .capbox 状态；清理 CAPBOX_* 污染
unset CAPBOX_ROOT CAPBOX_DIR CAPBOX_WORKSPACE CAPBOX_NET CAPBOX_NET_ALLOW
export -n CAPBOX_ROOT CAPBOX_DIR CAPBOX_WORKSPACE 2>/dev/null || true
cd "$ROOT" || exit 1

evid="$ROOT/test/tmp/net-evidence-$$"
mkdir -p "$evid"
pass=0; fail=0
ok(){ echo "  PASS  $*"; pass=$((pass+1)); echo "PASS $*" >>"$evid/summary.txt"; }
bad(){ echo "  FAIL  $*"; fail=$((fail+1)); echo "FAIL $*" >>"$evid/summary.txt"; }

echo "[net-slow] root=$ROOT evidence=$evid"
"$CB" status | tee "$evid/status.txt" | sed -n '1,15p'
ws=$("$CB" status 2>/dev/null | sed -n 's/^工作区[[:space:]]*:[[:space:]]*//p' | head -1)
echo "workspace=[$ws]" | tee "$evid/workspace.txt"
case "$ws" in
  /workspace) bad "工作区被误设为 /workspace" ;;
  "") bad "未解析到工作区" ;;
  *) ok "工作区不是裸 /workspace ($ws)" ;;
esac

"$CB" config set CAPBOX_NET open >/dev/null
"$CB" exec --timeout 30 -- curl -fsS -o /dev/null -w '%{http_code}\n' --max-time 15 https://example.com/ | tee "$evid/open-example.txt"
grep -q 200 "$evid/open-example.txt" && ok "open example.com=200" || bad "open example.com"

"$CB" config set CAPBOX_NET_ALLOW 'example.com' >/dev/null
"$CB" config set CAPBOX_NET restricted >/dev/null
"$CB" exec --timeout 35 -- curl -fsS -o /dev/null -w '%{http_code}\n' --max-time 15 https://example.com/ \
  >"$evid/allow-example.out" 2>"$evid/allow-example.err"
ec=$?
echo "ec=$ec" | tee -a "$evid/allow-example.out"
if [[ $ec -eq 0 ]] && grep -q 200 "$evid/allow-example.out"; then ok "restricted allow example.com=200"; else bad "restricted allow example.com"; fi

"$CB" exec --timeout 35 -- curl -fsS -o /dev/null -w '%{http_code}\n' --max-time 15 https://httpbin.org/get \
  >"$evid/deny-httpbin.out" 2>"$evid/deny-httpbin.err"
ec=$?
echo "ec=$ec" | tee -a "$evid/deny-httpbin.out"
cat "$evid/deny-httpbin.err" | tee -a "$evid/deny-httpbin.out" >/dev/null
if [[ $ec -ne 0 ]] && grep -qiE '403|Forbidden|CONNECT tunnel failed' "$evid/deny-httpbin.out" "$evid/deny-httpbin.err"; then
  ok "restricted deny httpbin (403/CONNECT fail)"
else
  bad "restricted deny httpbin (ec=$ec)"
fi

"$CB" exec --timeout 20 -- sh -c 'curl --noproxy "*" -fsS --max-time 5 -o /dev/null https://example.com/; echo RC=$?' \
  >"$evid/noproxy.out" 2>"$evid/noproxy.err"
if grep -qE 'RC=[1-9]' "$evid/noproxy.out"; then ok "noproxy 原始出站失败（unshare-net）"; else bad "noproxy 未失败（可能仍共享宿主网）"; fi

"$CB" config set CAPBOX_NET_ALLOW 'com' >/dev/null
"$CB" exec --timeout 25 -- curl -fsS -o /dev/null -w '%{http_code}\n' --max-time 12 https://example.com/ \
  >"$evid/tld.out" 2>"$evid/tld.err"
ec=$?
if [[ $ec -ne 0 ]]; then ok "裸 TLD allow=com 不放行"; else bad "裸 TLD 仍放行"; fi

"$CB" config set CAPBOX_NET open >/dev/null
"$CB" config set CAPBOX_NET_ALLOW '' >/dev/null

echo "[net-slow] PASS=$pass FAIL=$fail evidence=$evid"
echo "PASS=$pass FAIL=$fail" >"$evid/summary.rc"
exit $(( fail>0 ? 1 : 0 ))
