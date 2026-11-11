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
# 单独 source net.sh 时也要加载目录；test/lib.sh 已钉 CAPBOX_LANG=zh。
# shellcheck disable=SC1091
. "$REPO/lib/i18n.sh"
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
  eval "$(declare -f config_set | sed '1s/^config_set/_config_set_real/')"
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
  python3 - "$policy_tmp" <<'PY'
import os, sys, tarfile
base = sys.argv[1]
abs_tar = os.path.join(base, "abs.tar.gz")
with tarfile.open(abs_tar, "w:gz") as tf:
    info = tarfile.TarInfo("usr/sbin/add-shell")
    info.type = tarfile.SYMTYPE
    info.linkname = "/bin/busybox"
    tf.addfile(info)
badlink = os.path.join(base, "badlink.tar.gz")
with tarfile.open(badlink, "w:gz") as tf:
    info = tarfile.TarInfo("usr/sbin/escape")
    info.type = tarfile.SYMTYPE
    info.linkname = "/tmp/../../etc/passwd"
    tf.addfile(info)
PY
  mkdir -p "$policy_tmp/absstage"
  _image_extract_archive "$policy_tmp/abs.tar.gz" "$policy_tmp/absstage"
  [[ "$(readlink -- "$policy_tmp/absstage/usr/sbin/add-shell")" == "/bin/busybox" ]]
  if _image_extract_archive "$policy_tmp/badlink.tar.gz" "$policy_tmp/absstage"; then
    echo "absolute link with .. should fail" >&2
    exit 1
  fi
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

  # shellcheck disable=SC1091
  . "$REPO/lib/sandbox.sh"
  seen_net="$policy_tmp/seen-net"
  exec_in_guest() { printf '%s\n' "${CAPBOX_NET}" >"$seen_net"; return 0; }
  log_info() { :; }
  config_writes=0
  config_set() { config_writes=$((config_writes + 1)); return 0; }
  CAPBOX_NET=none
  CAPBOX_NET_ALLOW=
  _pkg_run_guest install true 5
  [[ "$(cat "$seen_net")" == "open" ]]
  [[ "$CAPBOX_NET" == "none" ]]
  [[ "$config_writes" -eq 0 ]]
  _pkg_run_guest update true 5
  [[ "$(cat "$seen_net")" == "open" ]]
  [[ "$CAPBOX_NET" == "none" ]]
  _pkg_run_guest remove true 5
  [[ "$(cat "$seen_net")" == "none" ]]
  _pkg_run_guest list true 5
  [[ "$(cat "$seen_net")" == "none" ]]
  CAPBOX_NET=restricted
  _pkg_run_guest install true 5
  [[ "$(cat "$seen_net")" == "restricted" ]]
  [[ "$CAPBOX_NET" == "restricted" ]]
  _capbox_declare_net host t40
  [[ "$CAPBOX_NET" == "open" ]]
  CAPBOX_NET_ALLOW=example.com
  _capbox_declare_net restricted t40
  [[ "$CAPBOX_NET" == "restricted" ]]
  rc=0
  ( CAPBOX_NET_ALLOW=; _capbox_declare_net restricted t40 ) || rc=$?
  [[ "$rc" -eq 2 ]]
  rc=0
  ( _capbox_declare_net weird t40 ) || rc=$?
  [[ "$rc" -eq 2 ]]
  rc=0
  ( cmd_exec --daemon --net open -- true ) || rc=$?
  [[ "$rc" -eq 2 ]]
  rc=0
  ( cmd_shell --daemon --net open ) || rc=$?
  [[ "$rc" -eq 2 ]]
  # shellcheck disable=SC1091
  . "$REPO/lib/daemon.sh"
  rc=0
  ( cmd_up --net ) || rc=$?
  [[ "$rc" -eq 2 ]]
  # Exercise the real batch commit, rather than observing old config_set calls.
  _apply_agent_preset
  [[ "$CAPBOX_NET" == none && "$CAPBOX_SECURITY_PROFILE" == untrusted ]]
  [[ "$CAPBOX_IDMAP" == off && "$CAPBOX_RESOURCES_MODE" == require ]]
  grep -q "CAPBOX_NET='none'" "$CAPBOX_DIR/config.env"
  grep -q "CAPBOX_SECURITY_PROFILE='untrusted'" "$CAPBOX_DIR/config.env"
  grep -q "CAPBOX_IDMAP='off'" "$CAPBOX_DIR/config.env"
  grep -q "CAPBOX_RESOURCES_MODE='require'" "$CAPBOX_DIR/config.env"

  # 仓库即状态：logs 必须出现在 --ro-bind 里。符号链接和普通文件拒绝。
  (
    ws="$policy_tmp/repolike"
    mkdir -p "$ws/bin" "$ws/lib" "$ws/logs"
    CAPBOX_DIR="$ws"
    CAPBOX_WORKSPACE="$ws"
    CAPBOX_BIN_DIR="$ws/bin"
    CAPBOX_LIB_DIR="$ws/lib"
    _capbox_derive_paths
    declare -a ro=()
    _capbox_append_ro_cli_binds ro
    found=0
    seen_cache=0
    i=0
    while (( i < ${#ro[@]} )); do
      if [[ "${ro[$i]}" == "--ro-bind" && "${ro[$((i+1))]}" == "$ws/logs" ]]; then
        found=1
      fi
      if [[ "${ro[$i]}" == "--ro-bind" ]] && (( i + 2 < ${#ro[@]} )) \
        && [[ "${ro[$((i+1))]}" == "/dev/null" && "${ro[$((i+2))]}" == "/workspace/state/bwrap-version" ]]; then
        seen_cache=1
      fi
      i=$((i+1))
    done
    [[ "$found" -eq 1 ]]
    [[ "$seen_cache" -eq 1 ]]
    rm -rf "$ws/state"
    mkdir -p "$ws/state"
    ln -s /tmp/x "$ws/state/bwrap-version"
    rc=0
    declare -a ro_cache=()
    _capbox_append_ro_cli_binds ro_cache || rc=$?
    [[ "$rc" -eq 1 ]]
    rm -f "$ws/state/bwrap-version"
    rm -rf "$ws/logs"
    ln -s /tmp "$ws/logs"
    rc=0
    declare -a ro2=()
    _capbox_append_ro_cli_binds ro2 || rc=$?
    [[ "$rc" -eq 1 ]]
    rm -f "$ws/logs"
    printf 'x\n' >"$ws/logs"
    rc=0
    declare -a ro3=()
    _capbox_append_ro_cli_binds ro3 || rc=$?
    [[ "$rc" -eq 1 ]]
    rm -f "$ws/logs"
    mkdir -p "$ws/logs"
    ln -s /tmp/not-audit "$ws/logs/audit.jsonl"
    rc=0
    declare -a ro4=()
    _capbox_append_ro_cli_binds ro4 || rc=$?
    [[ "$rc" -eq 1 ]]
    rm -f "$ws/logs/audit.jsonl"
    declare -a seq=()
    _capbox_append_ro_cli_binds seq
    seq+=(--bind "$ws/logs" /workspace/logs)
    _capbox_ro_protect_logs seq
    last=-1
    i=0
    while (( i < ${#seq[@]} )); do
      if [[ "${seq[$i]}" == "--ro-bind" && "${seq[$((i+1))]}" == "$ws/logs" ]]; then
        last=$i
      fi
      i=$((i + 1))
    done
    [[ "$last" -gt 0 ]]
    # 最后一次 logs 挂载必须晚于刚才插入的可写 --bind
    bind_at=-1
    i=0
    while (( i < ${#seq[@]} )); do
      if [[ "${seq[$i]}" == "--bind" && "${seq[$((i+1))]}" == "$ws/logs" ]]; then
        bind_at=$i
      fi
      i=$((i + 1))
    done
    [[ "$last" -gt "$bind_at" ]]

    # shellcheck disable=SC1091
    . "$REPO/lib/fsguard.sh"
    CAPBOX_FS_BINDS="$ws/logs:/workspace/logs:rw"
    rc=0
    declare -a fb=()
    _fsguard_append_binds fb || rc=$?
    [[ "$rc" -eq 2 ]]
    unset CAPBOX_FS_BINDS

    # shellcheck disable=SC1091
    . "$REPO/lib/service.sh"
    mkdir -p "$ws/services"
    printf '%s\n' "CMD=true" "CWD=/workspace" "USER=root" "MY_VAR=hello" >"$ws/services/demo.env"
    declare -A sv=() se=()
    _service_load demo sv se
    [[ "${sv[CMD]}" == "true" ]]
    [[ "${se[MY_VAR]}" == "hello" ]]
    [[ -z "${sv[MY_VAR]:-}" ]]
    declare -a argv=()
    _service_append_env_args argv sv se
    ok_my=0
    ok_cwd=0
    ok_user=0
    i=0
    while (( i < ${#argv[@]} )); do
      if [[ "${argv[$i]}" == "--setenv" && "${argv[$((i+1))]}" == "MY_VAR" && "${argv[$((i+2))]}" == "hello" ]]; then
        ok_my=1
      fi
      if [[ "${argv[$i]}" == "--setenv" && "${argv[$((i+1))]}" == "CWD" && "${argv[$((i+2))]}" == "/workspace" ]]; then
        ok_cwd=1
      fi
      if [[ "${argv[$i]}" == "--setenv" && "${argv[$((i+1))]}" == "USER" && "${argv[$((i+2))]}" == "root" ]]; then
        ok_user=1
      fi
      i=$((i + 1))
    done
    [[ "$ok_my" == 1 && "$ok_cwd" == 1 && "$ok_user" == 1 ]]
  )
  # 标准 .capbox：logs 的只读绑定在 run 的可写挂回之后。
  (
    ws="$policy_tmp/stdws"
    mkdir -p "$ws/.capbox/logs" "$ws/.capbox/run" "$ws/.capbox/cache" "$ws/.capbox/bin" "$ws/.capbox/lib"
    CAPBOX_DIR="$ws/.capbox"
    CAPBOX_WORKSPACE="$ws"
    _capbox_derive_paths
    declare -a ro=()
    _capbox_append_ro_cli_binds ro
    seen_rw=0
    seen_logs_after=0
    seen_cache=0
    logs_at=-1
    cache_at=-1
    i=0
    while (( i < ${#ro[@]} )); do
      if [[ "${ro[$i]}" == "--bind" && "${ro[$((i+1))]}" == "$CAPBOX_DIR/run" ]]; then
        seen_rw=1
      fi
      if [[ "${ro[$i]}" == "--ro-bind" && "${ro[$((i+1))]}" == "$CAPBOX_DIR/logs" ]]; then
        [[ "$seen_rw" -eq 1 ]]
        seen_logs_after=1
        logs_at=$i
      fi
      if [[ "${ro[$i]}" == "--ro-bind" ]] && (( i + 2 < ${#ro[@]} )) \
        && [[ "${ro[$((i+1))]}" == "/dev/null" && "${ro[$((i+2))]}" == "/workspace/.capbox/state/bwrap-version" ]]; then
        seen_cache=1
        cache_at=$i
      fi
      i=$((i+1))
    done
    [[ "$seen_logs_after" -eq 1 ]]
    [[ "$seen_cache" -eq 1 ]]
    [[ "$cache_at" -gt "$logs_at" ]]
  )

  old="$policy_tmp/bwrap-old"
  printf '%s\n' '#!/bin/sh' 'echo bubblewrap 0.11.1' >"$old"
  chmod +x "$old"
  if _capbox_bwrap_version_ok "$old"; then
    echo "0.11.1 should fail" >&2
    exit 1
  fi
  [[ "$CAPBOX_BWRAP_VERSION_DETAIL" == *"0.12.0"* ]]
  ub="$policy_tmp/bwrap-ubuntu"
  printf '%s\n' '#!/bin/sh' 'echo bubblewrap 0.11.1-1ubuntu0.3' >"$ub"
  chmod +x "$ub"
  if _capbox_bwrap_version_ok "$ub"; then
    echo "reverted 0.11.1 distro string should fail" >&2
    exit 1
  fi
  okb="$policy_tmp/bwrap-ok"
  printf '%s\n' '#!/bin/sh' 'echo bubblewrap 0.12.0' >"$okb"
  chmod +x "$okb"
  _capbox_bwrap_version_ok "$okb"
  [[ "$CAPBOX_BWRAP_VERSION_DETAIL" == "0.12.0" ]]
  newb="$policy_tmp/bwrap-new"
  printf '%s\n' '#!/bin/sh' 'echo bubblewrap 0.13.1' >"$newb"
  chmod +x "$newb"
  _capbox_bwrap_version_ok "$newb"
  [[ "$CAPBOX_BWRAP_VERSION_DETAIL" == "0.13.1" ]]
  bad="$policy_tmp/bwrap-bad"
  printf '%s\n' '#!/bin/sh' 'echo no-version-here' >"$bad"
  chmod +x "$bad"
  if _capbox_bwrap_version_ok "$bad"; then
    echo "unparseable version should fail" >&2
    exit 1
  fi
  [[ "$CAPBOX_BWRAP_VERSION_DETAIL" == *"无法解析"* ]]
  saved_bwrap="${CAPBOX_BWRAP:-}"
  CAPBOX_BWRAP="$old"
  unset CAPBOX_ALLOW_OLD_BWRAP_ONCE || true
  CAPBOX_ALLOW_OLD_BWRAP=0
  rc=0
  build_bwrap_args oneshot /workspace >/dev/null || rc=$?
  [[ "$rc" -eq 6 ]]
  rc=0
  _daemon_bwrap_args daemon >/dev/null || rc=$?
  [[ "$rc" -eq 6 ]]

  suf="$policy_tmp/bwrap-suf"
  printf '%s\n' '#!/bin/sh' 'echo bubblewrap 0.11.2-1ubuntu1' >"$suf"
  chmod +x "$suf"
  if _capbox_bwrap_version_ok "$suf"; then
    echo "0.11.2-1ubuntu1 should fail" >&2
    exit 1
  fi
  [[ "$CAPBOX_BWRAP_VERSION" == "0.11.2" ]]

  (
    printf 'CAPBOX_ALLOW_OLD_BWRAP=0\n' >"$CAPBOX_DIR/config.env"
    CAPBOX_ALLOW_OLD_BWRAP=1
    load_config
    [[ "${CAPBOX_ALLOW_OLD_BWRAP:-}" == "0" ]]
    printf 'CAPBOX_ALLOW_OLD_BWRAP=1\n' >"$CAPBOX_DIR/config.env"
    CAPBOX_ALLOW_OLD_BWRAP=0
    load_config
    [[ "${CAPBOX_ALLOW_OLD_BWRAP:-}" == "1" ]]
  )

  CAPBOX_BWRAP="$old"
  printf 'CAPBOX_ALLOW_OLD_BWRAP=0\n' >"$CAPBOX_DIR/config.env"
  load_config
  CAPBOX_BWRAP="$old"
  CAPBOX_ALLOW_OLD_BWRAP=0
  CAPBOX_ALLOW_OLD_BWRAP_ONCE=1
  CAPBOX_BWRAP_BASELINE_CMD='exec -- id'
  rm -rf "$CAPBOX_DIR/logs"
  mkdir -p "$CAPBOX_DIR/logs"
  rc=0
  _capbox_enforce_bwrap_baseline || rc=$?
  [[ "$rc" -eq 0 ]]
  auditf="$CAPBOX_DIR/logs/audit.jsonl"
  grep -q '"event":"old_bwrap_bypass"' "$auditf"
  grep -q '"scope":"once"' "$auditf"
  grep -q '"version":"0.11.1"' "$auditf"
  grep -q 'exec -- id' "$auditf"
  if _capbox_bwrap_version_ok "$old"; then
    echo "once must not mark version ok" >&2
    exit 1
  fi
  unset CAPBOX_ALLOW_OLD_BWRAP_ONCE

  CAPBOX_ALLOW_OLD_BWRAP=1
  CAPBOX_BWRAP="$old"
  CAPBOX_BWRAP_BASELINE_CMD='exec -- true'
  rc=0
  _capbox_enforce_bwrap_baseline || rc=$?
  [[ "$rc" -eq 0 ]]
  grep -q '"scope":"persist"' "$auditf"
  if _capbox_bwrap_version_ok; then
    echo "persist must not mark version ok" >&2
    exit 1
  fi

  DOCTOR_FAILS=0
  DOCTOR_WARNS=0
  doc_out="$(_capbox_doctor_check_bwrap "$old"; printf 'FLAGS %s %s\n' "${CAPBOX_DOCTOR_BWRAP_BASELINE_FAIL}" "${CAPBOX_DOCTOR_BWRAP_LAUNCH_OK}")"
  [[ "$doc_out" == *"FAIL  bwrap 0.11.1 低于安全基线 0.12.0"* ]]
  [[ "$doc_out" != *"PASS  bwrap 版本"* ]]
  [[ "$doc_out" == *"FLAGS 1 1"* ]]
  CAPBOX_ALLOW_OLD_BWRAP=0
  unset CAPBOX_ALLOW_OLD_BWRAP_ONCE || true
  DOCTOR_FAILS=0
  DOCTOR_WARNS=0
  doc_out="$(_capbox_doctor_check_bwrap "$old"; printf 'FLAGS %s %s\n' "${CAPBOX_DOCTOR_BWRAP_BASELINE_FAIL}" "${CAPBOX_DOCTOR_BWRAP_LAUNCH_OK}")"
  [[ "$doc_out" == *"FAIL  bwrap 0.11.1 低于安全基线 0.12.0"* ]]
  [[ "$doc_out" == *"FLAGS 1 0"* ]]

  CAPBOX_SECURITY_PROFILE=compat
  CAPBOX_BWRAP="$old"
  rc=0
  _capbox_enforce_bwrap_baseline || rc=$?
  [[ "$rc" -eq 6 ]]

  eval "$(declare -f _config_set_real | sed '1s/^_config_set_real/config_set/')"
  printf 'CAPBOX_ALLOW_OLD_BWRAP=0\n' >"$CAPBOX_DIR/config.env"
  CAPBOX_ALLOW_OLD_BWRAP=0
  rc=0
  config_set ALLOW_OLD_BWRAP 1 || rc=$?
  [[ "$rc" -eq 2 ]]
  grep -qx 'CAPBOX_ALLOW_OLD_BWRAP=0' "$CAPBOX_DIR/config.env"
  CAPBOX_ALLOW_OLD_BWRAP_CONFIRM=1
  config_set ALLOW_OLD_BWRAP 1
  grep -q "CAPBOX_ALLOW_OLD_BWRAP='1'" "$CAPBOX_DIR/config.env"
  grep -q 'config set CAPBOX_ALLOW_OLD_BWRAP 1' "$auditf"
  rc=0
  config_set ALLOW_OLD_BWRAP 1 || rc=$?
  [[ "$rc" -eq 2 ]]
  CAPBOX_ALLOW_OLD_BWRAP_CONFIRM=1
  rc=0
  config_set ALLOW_OLD_BWRAP true || rc=$?
  [[ "$rc" -eq 2 ]]
  unset CAPBOX_ALLOW_OLD_BWRAP_CONFIRM

  printf 'CAPBOX_ALLOW_OLD_BWRAP=0\n' >"$CAPBOX_DIR/config.env"
  CAPBOX_ALLOW_OLD_BWRAP=0
  rm -rf "$CAPBOX_DIR/logs"
  ln -s /tmp "$CAPBOX_DIR/logs"
  CAPBOX_ALLOW_OLD_BWRAP_CONFIRM=1
  rc=0
  config_set ALLOW_OLD_BWRAP 1 || rc=$?
  [[ "$rc" -ne 0 ]]
  grep -q "CAPBOX_ALLOW_OLD_BWRAP='0'" "$CAPBOX_DIR/config.env"
  rm -f "$CAPBOX_DIR/logs"
  unset CAPBOX_ALLOW_OLD_BWRAP_CONFIRM

  cntf="$policy_tmp/bwrap-invocations"
  count="$policy_tmp/bwrap-count"
  printf '%s\n' '#!/bin/sh' "echo x >> '$cntf'" 'echo bubblewrap 0.13.1' >"$count"
  chmod +x "$count"
  rm -f "$cntf" "$CAPBOX_DIR/state/bwrap-version"
  _capbox_bwrap_version_ok "$count"
  _capbox_bwrap_version_ok "$count"
  [[ "$(wc -l <"$cntf")" -eq 1 ]]
  touch -d '2000-01-01 00:00:00' "$count"
  _capbox_bwrap_version_ok "$count"
  [[ "$(wc -l <"$cntf")" -eq 2 ]]
  [[ "$CAPBOX_BWRAP_VERSION_DETAIL" == "0.13.1" ]]

  CAPBOX_BWRAP="$saved_bwrap"
  CAPBOX_ALLOW_OLD_BWRAP=0
  unset CAPBOX_ALLOW_OLD_BWRAP_ONCE CAPBOX_ALLOW_OLD_BWRAP_CONFIRM CAPBOX_BWRAP_BASELINE_CMD || true
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
