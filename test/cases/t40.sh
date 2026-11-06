#!/usr/bin/env bash
# T40 — allowlist 端口/通配/私网地址，以及非法 CAPBOX_NET 失败即关闭
set -u
CASE_TITLE="网络策略：端口、通配、私网地址、非法 NET"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩的沙箱没有 lib/，策略测试只在真 CLI 验收里跑"
  case_finish
  exit 0
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

run_cmd python3 - "$REPO/lib/net-proxy.py" <<'PY'
import importlib.util, sys
path = sys.argv[1]
spec = importlib.util.spec_from_file_location("capbox_net", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

fails = []
def check(cond, msg):
    print(("ok" if cond else "FAIL"), msg)
    if not cond:
        fails.append(msg)

allow = ["example.com", "*.python.org", "github.com:22", "10.0.0.0/8", "169.254.169.254"]
check(mod.host_allowed("example.com", allow, 443), "apex https")
check(mod.host_allowed("example.com", allow, 80), "apex http")
check(not mod.host_allowed("example.com", allow, 22), "apex 非 80/443 默认拒绝")
check(not mod.host_allowed("www.example.com", allow, 443), "子域不再隐式放行")
check(mod.host_allowed("pypi.python.org", allow, 443), "*.python.org 子域")
check(not mod.host_allowed("python.org", allow, 443), "通配不含 apex")
check(mod.host_allowed("github.com", allow, 22), "显式端口")
check(not mod.host_allowed("github.com", allow, 443), "只写了 :22 就不放行 443")
check(not mod.host_allowed("example.com", ["com"], 443), "裸 TLD 不放行")
check(not mod.host_allowed("169.254.169.254", ["example.com"], 80), "未列出的元数据地址拒绝")
check(mod.host_allowed("169.254.169.254", allow, 443), "显式列出的链路本地地址放行")
check(mod.host_allowed("10.1.2.3", allow, 80), "显式 CIDR 放行")
check(not mod.host_allowed("10.1.2.3", ["example.com"], 443), "域名规则不放行私网 IP")
check(not mod.host_allowed("127.0.0.1", ["example.com"], 80), "回环默认拒绝")
if fails:
    raise SystemExit("FAIL " + "; ".join(fails))
print("allowlist policy ok")
PY
assert_rc 0 "python allowlist 策略"

log_err() { printf '%s\n' "$*" >&2; }
# shellcheck disable=SC1091
. "$REPO/lib/net.sh"
CAPBOX_NET=weird
net_rc=0
_net_mode >/dev/null 2>"$QA_TMP/t40-net.err" || net_rc=$?
assert_eq 2 "$net_rc" "非法 CAPBOX_NET 返回 2"
if grep -q '拒绝回退到 open' "$QA_TMP/t40-net.err"; then
  _ok "非法 NET 失败即关闭"
else
  _fail "非法 NET 的错误信息缺少失败即关闭说明" "$(cat "$QA_TMP/t40-net.err")"
fi

for key in alpine-x86_64 alpine-aarch64 ubuntu-x86_64 ubuntu-aarch64; do
  if grep -q "^${key} [0-9a-f]\\{64\\}$" "$REPO/lib/rootfs-sha256.txt"; then
    _ok "rootfs 校验和 $key"
  else
    _fail "缺少 rootfs 校验和 $key"
  fi
done

case_finish
exit 0
