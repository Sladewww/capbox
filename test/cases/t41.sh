#!/usr/bin/env bash
# T41 — Landlock：strict 默认开启，挂载之后限制 VFS，允许列表之外的绑定不可读。
set -u
CASE_TITLE="Landlock：默认档位、helper，以及允许列表之外的路径"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖 Landlock / bwrap 实路径"
  case_finish
  exit 0
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
policy_tmp="$(mktemp -d)"

set +e
(
  set -euo pipefail
  export CAPBOX_DIR="$policy_tmp/cb"
  export CAPBOX_WORKSPACE="$policy_tmp"
  mkdir -p "$CAPBOX_DIR"
  unset CAPBOX_LANDLOCK CAPBOX_DISK_MAX || true
  # shellcheck disable=SC1091
  . "$REPO/lib/common.sh"
  # shellcheck disable=SC1091
  . "$REPO/lib/security.sh"
  # shellcheck disable=SC1091
  . "$REPO/lib/fsguard.sh"
  # shellcheck disable=SC1091
  . "$REPO/lib/landlock.sh"
  # /bin/sh -> /bin/busybox 是容器内绝对链接，宿主 [[ -x ]] 会跟到宿主路径。
  CAPBOX_ROOTFS="$REPO/os/alpine"
  rootfs_ready_at "$CAPBOX_ROOTFS" || { echo "缺少 alpine rootfs: $CAPBOX_ROOTFS" >&2; exit 1; }

  CAPBOX_SECURITY_PROFILE=compat
  CAPBOX_LANDLOCK=
  _landlock_enabled && { echo "compat 未设置不应启用" >&2; exit 1; }

  CAPBOX_SECURITY_PROFILE=untrusted
  _landlock_enabled && { echo "untrusted 未设置不应启用" >&2; exit 1; }

  CAPBOX_SECURITY_PROFILE=strict
  _landlock_enabled || { echo "strict 未设置应启用" >&2; exit 1; }

  CAPBOX_LANDLOCK=off
  if _landlock_enabled; then
    echo "显式 off 应覆盖 strict" >&2
    exit 1
  fi

  CAPBOX_LANDLOCK=maybe
  rc=0
  _landlock_enabled || rc=$?
  [[ "$rc" -eq 2 ]]

  CAPBOX_LANDLOCK=on
  CAPBOX_SECURITY_PROFILE=compat
  _landlock_enabled || { echo "显式 on 应启用" >&2; exit 1; }

  rc=0
  config_set LANDLOCK weird || rc=$?
  [[ "$rc" -eq 2 ]]
  [[ ! -f "$CAPBOX_DIR/config.env" || "$(grep -c LANDLOCK "$CAPBOX_DIR/config.env" || true)" -eq 0 ]]

  helper="$(_landlock_ensure_helper)"
  [[ -x "$helper" && ! -L "$helper" ]]
  abi="$("$helper" --probe)"
  [[ "$abi" =~ ^[0-9]+$ && "$abi" -ge 1 ]]

  rules="$(_landlock_write_rules)"
  grep -qx 'rw /workspace' "$rules"
  grep -qx 'rw /tmp' "$rules"
  grep -qx 'ro /bin' "$rules" || grep -qx 'rw /bin' "$rules"

  CAPBOX_ROOTFS_RO=1
  CAPBOX_FS_OVERLAY_ACTIVE=0
  rules="$(_landlock_write_rules)"
  grep -qx 'ro /bin' "$rules"
  CAPBOX_FS_OVERLAY_ACTIVE=1
  rules="$(_landlock_write_rules)"
  grep -qx 'rw /bin' "$rules"
  CAPBOX_FS_OVERLAY_ACTIVE=0
  rules="$(_landlock_write_rules)"
  grep -qx 'ro /etc' "$rules"

  cmd=(/usr/sbin/bwrap --bind / / -- /bin/true)
  _landlock_apply_argv cmd
  printf '%s\n' "${cmd[@]}" | grep -qx '/run/capbox-landlock'
  printf '%s\n' "${cmd[@]}" | grep -qx -- '--rules'
  # /sys 在规则里被跳过，也没有单独的 rw 行，用来放允许列表之外的绑定。
  grep -qE '^(ro|rw) /sys$' "$rules" && { echo "规则不应覆盖 /sys" >&2; exit 1; }

  # 允许列表之外的绑定不可读；/etc 只读规则挡住对 rootfs 的写。
  # helper 绑在 tmpfs /run 上，避免 bwrap 在可写 rootfs 里创建挂载点。
  base="$policy_tmp/ll"
  mkdir -p "$base/ws" "$base/secret"
  echo visible >"$base/ws/a"
  echo HIDDEN_SECRET >"$base/secret/s"
  rootfs_ready_at "$CAPBOX_ROOTFS" && [[ -d "$CAPBOX_ROOTFS/etc" && -d "$CAPBOX_ROOTFS/sys" && -d "$CAPBOX_ROOTFS/run" ]]
  bwrap="$(command -v bwrap)"
  out="$("$bwrap" --unshare-user --unshare-pid --die-with-parent \
    --bind "$CAPBOX_ROOTFS" / \
    --bind "$base/ws" /workspace \
    --tmpfs /tmp --proc /proc --dev /dev --tmpfs /run \
    --ro-bind "$base/secret" /sys \
    --ro-bind "$helper" /run/capbox-landlock \
    --ro-bind "$rules" /run/capbox-landlock.rules \
    -- /run/capbox-landlock --rules /run/capbox-landlock.rules -- \
    /bin/sh -c 'echo WS:$(cat /workspace/a); echo HIDDEN:$(cat /sys/s 2>&1); echo x >> /etc/capbox-t41-landlock && echo WROTE_ETC || echo DENY_ETC; echo y >> /workspace/b && echo WROTE_WS || echo DENY_WS')"
  printf '%s\n' "$out" | grep -q 'WS:visible'
  printf '%s\n' "$out" | grep -q 'HIDDEN:'
  printf '%s\n' "$out" | grep -q 'HIDDEN_SECRET' && { echo "允许列表之外的绑定仍可读: $out" >&2; exit 1; }
  printf '%s\n' "$out" | grep -q 'DENY_ETC'
  printf '%s\n' "$out" | grep -q 'WROTE_WS'
  printf '%s\n' "$out" | grep -q 'WROTE_ETC' && { echo "rootfs 写未被拒绝: $out" >&2; exit 1; }
  [[ ! -f "$CAPBOX_ROOTFS/etc/capbox-t41-landlock" ]]
  [[ ! -e "$CAPBOX_ROOTFS/run/capbox-landlock" ]]
  [[ ! -e "$CAPBOX_ROOTFS/usr/bin/capbox-landlock" ]]
  [[ -f "$base/ws/b" ]]
) >"$policy_tmp/out" 2>"$policy_tmp/err"
policy_rc=$?
set +e
if [[ "$policy_rc" -ne 0 ]]; then
  _fail "Landlock 策略与 helper 检查失败" "rc=$policy_rc" "$(tail -n 40 "$policy_tmp/err" 2>/dev/null || true)"
else
  _ok "档位默认、规则和允许列表之外的路径"
fi

require_rootfs || { rm -rf "$policy_tmp"; case_finish; exit 0; }

run_cmd env CAPBOX_LANDLOCK=on "$CAPBOX_BIN" exec -- /bin/true
assert_rc 0 "LANDLOCK=on 时 /bin/true 成功"

run_cmd env CAPBOX_LANDLOCK=on "$CAPBOX_BIN" exec -- /bin/sh -c 'echo t41-ok > /workspace/.capbox-t41-landlock && cat /workspace/.capbox-t41-landlock'
assert_rc 0 "LANDLOCK=on 时可以写 /workspace"
assert_stdout_contains "t41-ok" "工作区写入可见"
rm -f "${CAPBOX_TEST_WS}/.capbox-t41-landlock"
if [[ -e "$REPO/os/alpine/usr/bin/capbox-landlock" || -e "$REPO/os/alpine/usr/bin/capbox-landlock.rules" || -e "$REPO/os/alpine/run/capbox-landlock" ]]; then
  _fail "LANDLOCK=on 在 rootfs 留下挂载点"
else
  _ok "LANDLOCK=on 没有在 rootfs 留下挂载点"
fi

run_cmd env CAPBOX_LANDLOCK=maybe "$CAPBOX_BIN" exec -- /bin/true
assert_rc 2 "非法 CAPBOX_LANDLOCK 拒绝启动"

rm -rf "$policy_tmp"
case_finish
