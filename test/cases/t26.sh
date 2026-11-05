#!/usr/bin/env bash
# T26 — 全新工作区 init --distro ubuntu：派生路径须在首次引导前同步（离线）
#
# 回归真实缺陷：缺 config.env 时 _init_finalize 先 CAPBOX_DISTRO=$distro +
# config_save，随后 config_get 已相等而跳过 _capbox_derive_paths；
# run_bootstrap → exec_in_guest 仍用启动时缓存的 CAPBOX_ROOTFS（默认 alpine），
# 报「rootfs 不存在: .../os/alpine」。用本地 alpine rootfs/缓存改装的 stub，不访问网络。
set -u
CASE_TITLE="全新工作区 init --distro ubuntu：ROOTFS 派生路径时序（离线）"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖本用例（仅真 CLI 验收）"
  case_finish
  exit 0
fi

mkdir -p "$QA_TMP"
tmpws="$QA_TMP/t26-fresh-ws"
rm -rf "$tmpws"
mkdir -p "$tmpws"

# 离线 stub：复用本机 alpine rootfs 或缓存 tarball，改写成 ID=ubuntu
stage="$QA_TMP/t26-ubuntu-stage"
rm -rf "$stage"
mkdir -p "$stage"
alp_os="$CAPBOX_DIR/os/alpine"
alp_tar=$(ls -1 "$CAPBOX_DIR"/cache/alpine-minirootfs-*.tar.gz 2>/dev/null | head -n 1 || true)
if [ -d "$alp_os/bin" ]; then
  tar -C "$alp_os" -cf - . | tar -C "$stage" -xf -
elif [ -n "$alp_tar" ] && [ -s "$alp_tar" ]; then
  tar -C "$stage" -xzf "$alp_tar"
else
  skip_case "无本地 alpine rootfs/缓存，无法构造离线 ubuntu stub（先跑 T03 或准备 cache）"
  case_finish
  exit 0
fi
rm -f "$stage/etc/os-release" "$stage/etc/alpine-release"
printf 'ID=ubuntu\nNAME="Ubuntu"\nPRETTY_NAME="Ubuntu (offline stub)"\n' >"$stage/etc/os-release"
tarball="$QA_TMP/t26-ubuntu-stub.tar.gz"
tar -C "$stage" -czf "$tarball" .
if [ ! -e "$stage/bin/sh" ] && [ ! -L "$stage/bin/sh" ]; then
  _fail "离线 stub 缺少 /bin/sh"
  case_finish
  exit 0
fi

run_cmd "$CAPBOX_BIN" --root "$tmpws" init --distro ubuntu --from "$tarball"
assert_rc 0 "全新工作区 init --distro ubuntu 退出码"

combined="${RUN_STDOUT}${RUN_STDERR}"
if printf '%s' "$combined" | grep -E 'rootfs 不存在: .*/os/alpine' >/dev/null 2>&1; then
  _fail "首次引导仍引用 alpine rootfs（派生路径未同步）" \
    "输出摘要: $(_short "$combined" 6)"
else
  _ok "首次引导未错误引用 os/alpine"
fi

assert_file_exists "$tmpws/.capbox/config.env" "config.env 已生成"
cfg_d=$(sed -n 's/^[[:space:]]*CAPBOX_DISTRO=//p' "$tmpws/.capbox/config.env" | tail -n 1)
cfg_d=$(printf '%s' "$cfg_d" | sed -e "s/^['\"]//" -e "s/['\"]$//")
assert_eq "ubuntu" "$cfg_d" "config.env CAPBOX_DISTRO=ubuntu"
ub_rf="$tmpws/.capbox/os/ubuntu"
if rootfs_path_exists "$ub_rf/bin/sh" "$ub_rf"; then
  _ok "ubuntu rootfs /bin/sh 存在"
else
  _fail "ubuntu rootfs 缺少 /bin/sh（含绝对符号链接语义）"
fi

if [ -e "$tmpws/.capbox/os/alpine" ]; then
  _fail "不应创建 alpine rootfs（本次只 init ubuntu）"
else
  _ok "未创建多余的 alpine rootfs"
fi

if printf '%s' "$combined" | grep -q '首次引导完成'; then
  _ok "首次引导完成"
elif printf '%s' "$combined" | grep -q '运行首次引导'; then
  _ok "已发起首次引导"
else
  mark_known_issue "输出中未见首次引导日志；路径时序断言仍有效"
fi

run_cmd "$CAPBOX_BIN" --root "$tmpws" exec -- sh -c 'grep ^ID= /etc/os-release'
assert_rc 0 "init 后 exec 退出码"
assert_stdout_eq "ID=ubuntu" "init 后 exec 进入 ubuntu"

case_finish
exit 0
