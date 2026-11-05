#!/usr/bin/env bash
# T21 — 安全边界：cp 穿越拒绝、config.env 不 source、--root 切换工作区
set -u
CASE_TITLE="安全边界：cp 穿越 / config 白名单 / --root"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖本用例（仅真 CLI 验收）"
  case_finish
  exit 0
fi
mkdir -p "$QA_TMP"

# ---- 1) config.env 白名单：恶意行不得被执行 ----
pwn="$QA_TMP/t21-pwned"
rm -f "$pwn"
cfg_bak=""
if [ -f "$CAPBOX_DIR/config.env" ]; then
  cfg_bak="$QA_TMP/t21-config.bak"
  if cp -a "$CAPBOX_DIR/config.env" "$cfg_bak" 2>/dev/null; then
    :
  else
    cfg_bak=""
  fi
fi
{
  printf "CAPBOX_DISTRO='alpine'\n"
  printf "CAPBOX_HOSTNAME='t21host'\n"
  # 若被 source，会创建 pwn 文件
  printf '$(touch %s)\n' "$pwn"
  printf "CAPBOX_NET='host'; touch %s\n" "$pwn"
} >"$CAPBOX_DIR/config.env"

run_cmd "$CAPBOX_BIN" config get CAPBOX_HOSTNAME
assert_rc 0 "白名单配置可读"
assert_stdout_eq "t21host" "HOSTNAME 来自白名单解析"
if [ -e "$pwn" ]; then
  _fail "config.env 中的 shell 片段被执行（应只做 KEY=value 白名单解析）"
else
  _ok "config.env 恶意 shell 未被执行"
fi
# 恢复
if [ -n "$cfg_bak" ]; then
  mv -f "$cfg_bak" "$CAPBOX_DIR/config.env"
else
  rm -f "$CAPBOX_DIR/config.env"
fi

# ---- 2) --root 真正切换工作区 ----
tmpws="$QA_TMP/t21-root-ws"
rm -rf "$tmpws"
mkdir -p "$tmpws/.capbox"
# 最小可加载树：复用当前 lib/bin（symlink），避免复制大文件
ln -s "$CAPBOX_DIR/bin" "$tmpws/.capbox/bin"
ln -s "$CAPBOX_DIR/lib" "$tmpws/.capbox/lib"
printf "CAPBOX_DISTRO='alpine'\n" >"$tmpws/.capbox/config.env"

run_cmd "$CAPBOX_BIN" --root "$tmpws" status
assert_rc 0 "--root status 退出码"
# 人读 status 含工作区行
if printf '%s' "$RUN_STDOUT$RUN_STDERR" | grep -F "$tmpws" >/dev/null 2>&1; then
  _ok "--root 后 status 报告新工作区"
else
  # JSON 路径
  run_cmd "$CAPBOX_BIN" --root "$tmpws" status --json
  if printf '%s' "$RUN_STDOUT" | grep -F "$tmpws" >/dev/null 2>&1; then
    _ok "--root 后 status --json 含新工作区"
  else
    _fail "--root 未切换工作区（输出中找不到 $tmpws）"
  fi
fi

# ---- 3) cp guest 路径穿越必须拒绝 ----
# 不调用 require_rootfs（它会直接 _fail）；无 rootfs 时跳过本段
if rootfs_ready "$(config_distro)"; then
  leak="$QA_TMP/t21-leak"
  rm -f "$leak"
  # 尝试逃出 os/<distro>/ 到宿主
  run_cmd "$CAPBOX_BIN" cp "guest:/../../../../../../../../etc/passwd" "host:$leak"
  if [ "$RUN_RC" = "0" ]; then
    _fail "cp 穿越应失败，却返回 0"
  else
    _ok "cp 穿越被拒绝 (rc=$RUN_RC)"
  fi
  if [ -e "$leak" ]; then
    _fail "cp 穿越仍写出了宿主文件 $leak"
    rm -f "$leak"
  else
    _ok "cp 穿越未在宿主落盘"
  fi
  # 对照：合法 guest 路径仍可用（写一个小文件再 cp 出）
  token="t21-$RANDOM"
  run_cmd "$CAPBOX_BIN" exec -- sh -c "printf '%s\\n' '$token' > /root/t21.txt"
  if [ "$RUN_RC" = "0" ]; then
    run_cmd "$CAPBOX_BIN" cp "guest:/root/t21.txt" "host:$QA_TMP/t21-ok.txt"
    assert_rc 0 "合法 guest cp 仍成功"
    if [ -f "$QA_TMP/t21-ok.txt" ]; then
      assert_eq "$token" "$(cat "$QA_TMP/t21-ok.txt")" "合法 cp 内容一致"
    fi
  else
    mark_known_issue "exec 写文件失败，跳过合法 cp 对照（rc=$RUN_RC）"
  fi
else
  mark_known_issue "无 rootfs，跳过 cp 穿越断言（先跑 T03 / init）"
fi

case_finish
exit 0
