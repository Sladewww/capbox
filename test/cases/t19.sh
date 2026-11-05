#!/usr/bin/env bash
# T19 — ubuntu 发行版：init --distro ubuntu + exec -- apt-get -v
# 慢（30MB rootfs + 解包），默认 SKIP；CAPBOX_TEST_SLOW=1 才跑。
#
# 关键设计：契约 §7 的意图是「ubuntu rootfs 能初始化、能进容器跑 apt-get」。
# 本用例分两段验证，一段按契约字面、一段做排除法：
#   1) 契约字面：`init --distro ubuntu` 之后直接 `exec -- apt-get -v` 必须成功。
#      这条曾经捕获过一个真实缺陷（init 的幂等早退分支没同步 CAPBOX_DISTRO，
#      导致 exec 仍进 alpine 容器 → apt-get 127）；主模块 后来把 config_set
#      挪进 _init_finalize 修掉了，现在两条路径都覆盖。断言保持契约字面不变，
#      回归时会重新抓到。
#   2) 排除法：显式 CAPBOX_DISTRO=ubuntu 验证 ubuntu rootfs 本体可用。
#      这样一旦 1) 失败，能立刻区分「发行版切换状态没同步」vs「ubuntu 容器本身坏了」。
set -u
CASE_TITLE="ubuntu 发行版：init --distro ubuntu + apt-get -v（慢，需 CAPBOX_TEST_SLOW=1）"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

# 门控优先：默认 SKIP。T19 不依赖已有 rootfs（它自己 init ubuntu），
# 所以这里不调用 require_rootfs（否则会在没 init 的机器上多记一条 FAIL）。
if [ "${CAPBOX_TEST_SLOW:-0}" != "1" ]; then
  skip_case "ubuntu 用例较慢（需下载/解包 30MB），默认跳过；设 CAPBOX_TEST_SLOW=1 执行"
  printf '      %s手动执行：%s CAPBOX_TEST_SLOW=1 %s T19\n' \
    "$C_DIM" "$C_RST" "$CAPBOX_TEST_DIR/run.sh"
  case_finish
  exit 0
fi

orig_distro=$(config_distro)
rf="$CAPBOX_DIR/os/ubuntu"

# --------------------------- 1) init ubuntu ---------------------------
run_cmd "$CAPBOX_BIN" init --distro ubuntu
assert_rc 0 "init --distro ubuntu 退出码"
assert_rootfs_has ubuntu "/bin/sh" "ubuntu rootfs /bin/sh"
assert_file_exists "$CAPBOX_DIR/run" "run 目录存在"
assert_rootfs_has ubuntu "/usr/bin/apt-get" "ubuntu 内 apt-get 存在"

# --------------------------- 2) 镜像源（契约 §6）---------------------------
# 契约 §6 写的是 etc/apt/sources.list；ubuntu-base 24.04 默认用 deb822 的
# sources.list.d/*.sources，CLI 选择了后者。两者功能等价，因此：
# 只要「有 tuna 源」就算通过，落点与契约字面不一致则记 KNOWN-ISSUE。
mirror_ok=0
for f in "$rf/etc/apt/sources.list" "$rf"/etc/apt/sources.list.d/*.sources; do
  [ -f "$f" ] || continue
  if grep -q 'tuna' "$f" 2>/dev/null; then
    _ok "apt 镜像源已注入且含 tuna（$f）"
    mirror_ok=1
    break
  fi
done
if [ "$mirror_ok" = "0" ]; then
  _fail "找不到含 tuna 的 apt 源文件（契约 §6 要求注入镜像源）" \
    "已检查: $rf/etc/apt/sources.list 与 $rf/etc/apt/sources.list.d/*.sources"
fi
if [ ! -f "$rf/etc/apt/sources.list" ]; then
  mark_known_issue "契约 §6 规定写 os/<d>/etc/apt/sources.list；实际写的是 sources.list.d/*.sources（deb822 格式，功能等价，契约文档需更新）"
fi

# 契约 §6/§0 坑 8：必须写 apt.conf.d/99capbox 且含 Acquire::Sandbox::User "root"
aptconf="$rf/etc/apt/apt.conf.d/99capbox"
if [ -f "$aptconf" ]; then
  _ok "存在 apt.conf.d/99capbox"
  assert_file_contains "$aptconf" "Acquire::Sandbox::User" "含 Acquire::Sandbox::User"
  assert_file_contains "$aptconf" "root" "Sandbox User 设为 root（契约 §0 坑 8）"
else
  _fail "缺少 $aptconf（契约 §6 明确要求）"
fi

# --------------------------- 3) 契约字面：init 后直接 exec ---------------------------
# 契约期望 init --distro ubuntu 之后，当前发行版就是 ubuntu（契约 §2：init 写 config）
run_cmd "$CAPBOX_BIN" exec -- sh -c 'cat /etc/os-release 2>/dev/null | grep -E "^(ID|NAME)=" | head -2'
if printf '%s' "$RUN_STDOUT" | grep -qi 'ubuntu'; then
  _ok "init --distro ubuntu 后 exec 进入的是 ubuntu 容器"
  assert_rc 0 "exec /etc/os-release 退出码"
else
  _fail "init --distro ubuntu 后 exec 仍进入其它发行版（实际：$(_short "$RUN_STDOUT" 2)）" \
    "契约 §2：init 应把 CAPBOX_DISTRO 写入 config；当前 config.env 仍是 $(config_distro)"
  mark_known_issue "init --distro D 之后当前发行版未同步（config.env=$(config_distro)，容器内却是 $(_short "$RUN_STDOUT" 2)）。历史上这是 init 幂等早退分支漏掉 config_set DISTRO 导致，已修；若再次出现请检查 _init_finalize 的同步逻辑"
fi

run_cmd "$CAPBOX_BIN" exec -- apt-get -v
assert_rc 0 "ubuntu 内 apt-get -v 退出码（契约 §7 T19）"
assert_stdout_contains "apt" "apt-get -v 输出含 apt"

# --------------------------- 4) 排除法：ubuntu rootfs 本身是否可用 ---------------------------
# 显式指定 CAPBOX_DISTRO=ubuntu，绕过上面的状态切换缺陷，验证 ubuntu 容器本体可用。
printf '  %s—— 用 CAPBOX_DISTRO=ubuntu 显式验证 ubuntu rootfs 本体 ——%s\n' "$C_DIM" "$C_RST"
export CAPBOX_DISTRO=ubuntu
run_cmd "$CAPBOX_BIN" exec -- sh -c 'grep ^ID= /etc/os-release'
assert_stdout_eq 'ID=ubuntu' "显式指定后容器内是 ubuntu"
run_cmd "$CAPBOX_BIN" exec -- apt-get -v
assert_rc 0 "ubuntu 内 apt-get -v 退出码"
assert_stdout_contains "apt" "apt-get -v 输出含 apt"

run_cmd "$CAPBOX_BIN" exec -- id -u
assert_stdout_eq "0" "ubuntu 容器内 uid=0"

# 契约 §0：userns 全权限，故 ubuntu 也应能 mount
run_cmd "$CAPBOX_BIN" exec -- sh -c 'mkdir -p /mnt && mount -t tmpfs none /mnt && echo ubuntu-mount-ok'
assert_rc 0 "ubuntu 容器内 mount tmpfs"
assert_stdout_contains "ubuntu-mount-ok" "ubuntu 全权限证明"

# apt update（tuna http 源，契约 §6 选 http 避免精简镜像缺 CA）
run_cmd "$CAPBOX_BIN" exec --timeout 300 -- apt-get -o APT::Sandbox::User=root update
assert_rc 0 "ubuntu apt-get update 退出码"
assert_out_not_matches '^(E|Err):' "apt update 无错误行"

# --------------------------- 5) 收尾：恢复 distro 配置 ---------------------------
unset CAPBOX_DISTRO
if [ "$orig_distro" != "ubuntu" ] && [ -n "$orig_distro" ]; then
  printf '  %s恢复 distro 配置为 %s%s\n' "$C_DIM" "$orig_distro" "$C_RST"
  run_cmd "$CAPBOX_BIN" config set CAPBOX_DISTRO "$orig_distro"
  if [ "$RUN_RC" != "0" ]; then
    mark_known_issue "T19 结束后无法用 config set 恢复 CAPBOX_DISTRO=$orig_distro（rc=$RUN_RC），后续用例可能受影响"
  fi
fi

case_finish
exit 0
