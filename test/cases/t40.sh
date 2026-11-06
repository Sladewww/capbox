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
import importlib.util, ipaddress, sys
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
cgnat = ipaddress.ip_address("100.100.100.200")
mapped = ipaddress.ip_address("::ffff:100.100.100.200")
check(mod._ip_forbidden(cgnat), "CGNAT 视为禁止")
check(mod._ip_forbidden(mapped), "v4-mapped CGNAT 视为禁止")
check(not cgnat.is_global and not cgnat.is_private, "确认解释器把 CGNAT 标成非 global 且非 private")
check(not mod.host_allowed("100.100.100.200", ["example.com"], 443), "未列出的 CGNAT 拒绝")
check(mod.host_allowed("100.100.100.200", ["100.64.0.0/10"], 80), "显式 CGNAT 网段放行 80")
check(not mod.host_allowed("10.1.2.3", ["example.com:*", "10.0.0.0/8"], 22), "解析网段仍受端口约束")
check(mod.host_allowed("10.1.2.3", ["example.com:*", "10.0.0.0/8"], 443), "同网段 443 放行")
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

# 纯函数：路径、配方键、rootfs 写入、uid 上界。假 CLI 已在上面跳过。
policy_tmp="$(mktemp -d)"
set +e
(
  set -euo pipefail
  export CAPBOX_DIR="$policy_tmp/cb"
  export CAPBOX_WORKSPACE="$policy_tmp"
  # 父用例把 CAPBOX_NET 设成非法值以测失败即关闭；这里要测的是另一组纯函数。
  unset CAPBOX_NET
  mkdir -p "$CAPBOX_DIR"
  # shellcheck disable=SC1091
  . "$REPO/lib/common.sh"
  # shellcheck disable=SC1091
  . "$REPO/lib/security.sh"
  # shellcheck disable=SC1091
  . "$REPO/lib/recipe.sh"
  # shellcheck disable=SC1091
  . "$REPO/lib/rootfs.sh"
  # shellcheck disable=SC1091
  . "$REPO/lib/idmap.sh"
  # shellcheck disable=SC1091
  . "$REPO/lib/resources.sh"
  # shellcheck disable=SC1091
  . "$REPO/lib/image.sh"

  unset 'CAPBOX_CFG_EXPLICIT[ROOTFS_RO]' || true
  CAPBOX_SECURITY_PROFILE=strict
  CAPBOX_ROOTFS_RO=0
  _capbox_apply_profile_rootfs_default
  [[ "$CAPBOX_ROOTFS_RO" == "1" ]]
  CAPBOX_CFG_EXPLICIT[ROOTFS_RO]=user
  CAPBOX_ROOTFS_RO=0
  _capbox_apply_profile_rootfs_default
  [[ "$CAPBOX_ROOTFS_RO" == "0" ]]

  if resolve_path "" >/dev/null; then
    echo "empty resolve_path should fail" >&2
    exit 1
  fi
  rt="$policy_tmp/rootfs"
  mkdir -p "$rt/etc"
  CAPBOX_ROOTFS="$rt"
  if _capbox_guest_path_in_rootfs "/etc/../passwd" >/dev/null; then
    echo "guest .. path should fail" >&2
    exit 1
  fi
  ln -s /tmp "$rt/out"
  if _capbox_guest_path_in_rootfs "/out/file" >/dev/null; then
    echo "guest symlink escape should fail" >&2
    exit 1
  fi
  got="$(_capbox_guest_path_in_rootfs "/etc")"
  [[ "$got" == "$(realpath -m -- "$rt/etc")" ]]

  (
    have_cmd() { return 1; }
    if out="$(resolve_path /tmp/anywhere)"; then
      echo "resolve_path without realpath should fail, got $out" >&2
      exit 1
    fi
    [[ -z "${out:-}" ]]
  )

  ln -s "$policy_tmp/outside-release" "$rt/etc/capbox-release"
  printf 'SAFE=1\n' | _rootfs_write_file "$rt/etc/capbox-release"
  [[ ! -L "$rt/etc/capbox-release" && -f "$rt/etc/capbox-release" ]]
  grep -q 'SAFE=1' "$rt/etc/capbox-release"
  if [[ -e "$policy_tmp/outside-release" ]] && grep -q 'SAFE=1' "$policy_tmp/outside-release"; then
    echo "write followed symlink" >&2
    exit 1
  fi
  mkdir -p "$rt/var"
  ln -s /tmp "$rt/var/lib"
  if printf 'NOLEAK\n' | _rootfs_write_file "$rt/var/lib/capbox-leak"; then
    echo "write through ancestor symlink should fail" >&2
    exit 1
  fi
  if [[ -e /tmp/capbox-leak ]] && grep -q 'NOLEAK' /tmp/capbox-leak; then
    echo "ancestor symlink was followed" >&2
    exit 1
  fi

  [[ "$(_resources_disk_guest_path)" == "/var/lib/capbox-data" ]]
  CAPBOX_DISK_GUEST_PATH="/var/../etc"
  if _resources_disk_guest_path >/dev/null; then
    echo "disk guest path .. should fail" >&2
    exit 1
  fi
  CAPBOX_DISK_GUEST_PATH="var/lib/capbox-data"
  if _resources_disk_guest_path >/dev/null; then
    echo "relative disk guest path should fail" >&2
    exit 1
  fi
  unset CAPBOX_DISK_GUEST_PATH

  if _idmap_exec_id 4294967296 >/dev/null; then
    echo "uid above 32-bit should fail" >&2
    exit 1
  fi
  if _idmap_exec_id abc >/dev/null; then
    echo "non-numeric uid should fail" >&2
    exit 1
  fi
  [[ "$(_idmap_exec_id 33)" == "33" ]]
  [[ "$(_idmap_exec_id 00033)" == "33" ]]
  # if 条件会把非零状态收成 0。on 但不可用必须仍是 2，不能当成「不走 idmap」。
  (
    _idmap_enabled() { return 2; }
    rc=0
    _capbox_idmap_decision >/dev/null || rc=$?
    [[ "$rc" -eq 2 ]]
  )

  cat >"$policy_tmp/one.recipe" <<'EOF'
SECURITY_PROFILE=strict
ROOTFS_RO=1
DISK_MAX=64M
RESOURCES_MODE=require
FS_HIDE=/etc/secret
INIT=0
EOF
  _recipe_cmd_apply "$policy_tmp/one.recipe"
  # config_set 会按 CAPBOX_DIR 和发行版重算派生路径，安装断言要指回夹具。
  CAPBOX_ROOTFS="$rt"
  grep -q "CAPBOX_SECURITY_PROFILE='strict'" "$CAPBOX_DIR/config.env"
  grep -q "CAPBOX_ROOTFS_RO='1'" "$CAPBOX_DIR/config.env"
  grep -q "CAPBOX_DISK_MAX='64M'" "$CAPBOX_DIR/config.env"
  grep -q "CAPBOX_FS_HIDE='/etc/secret'" "$CAPBOX_DIR/config.env"

  python3 - "$policy_tmp" <<'PY'
import io, os, sys, tarfile
base = sys.argv[1]
bad = os.path.join(base, "bad.tar.gz")
with tarfile.open(bad, "w:gz") as tf:
    info = tarfile.TarInfo("../evil")
    data = b"nope\n"
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
good = os.path.join(base, "good.tar.gz")
with tarfile.open(good, "w:gz") as tf:
    info = tarfile.TarInfo("var/cache/apk/pkg.apk")
    data = b"apk"
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
PY
  mkdir -p "$policy_tmp/badstage" "$policy_tmp/goodstage"
  if _image_extract_archive "$policy_tmp/bad.tar.gz" "$policy_tmp/badstage"; then
    echo "tar slip should fail" >&2
    exit 1
  fi
  [[ ! -e "$policy_tmp/evil" ]]
  _image_extract_archive "$policy_tmp/good.tar.gz" "$policy_tmp/goodstage"
  _image_install_tree "$policy_tmp/goodstage/var/cache/apk" "var/cache/apk"
  [[ -f "$(realpath -m -- "$rt")/var/cache/apk/pkg.apk" ]]
  rm -rf "$rt/var/cache"
  ln -s /tmp "$rt/var/cache"
  if _image_install_tree "$policy_tmp/goodstage/var/cache/apk" "var/cache/apk"; then
    echo "cache install followed symlink" >&2
    exit 1
  fi

  if command -v gcc >/dev/null 2>&1; then
    drop="$policy_tmp/drop"
    if gcc -O2 -o "$drop" "$REPO/lib/guest/capbox-drop-priv.c"; then
      rc=0
      "$drop" 4294967296 0 /bin/true || rc=$?
      [[ "$rc" -eq 2 ]]
      rc=0
      "$drop" abc 0 /bin/true || rc=$?
      [[ "$rc" -eq 2 ]]
    fi
  fi

  if grep -n 'mount --bind -o rw' "$REPO/lib/resources.sh" >/dev/null; then
    echo "disk still bind-mounts a rootfs tree" >&2
    exit 1
  fi
  if grep -n '_security_wrap_argv full || true' "$REPO/lib/service.sh" >/dev/null; then
    echo "service still ignores security wrap failure" >&2
    exit 1
  fi
) >"$QA_TMP/t40-policy.out" 2>"$QA_TMP/t40-policy.err"
policy_rc=$?
set -e
rm -rf "$policy_tmp"
if [[ "$policy_rc" -eq 0 ]]; then
  _ok "路径、配方、写入与 uid 上界"
else
  _fail "路径、配方、写入与 uid 上界" "$(tail -n 40 "$QA_TMP/t40-policy.err")"
fi

case_finish
exit 0
