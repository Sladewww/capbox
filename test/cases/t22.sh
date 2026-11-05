#!/usr/bin/env bash
# T22 — 会话无 .capbox 时 bootstrap 从模板脚手架（无网络）
set -u
CASE_TITLE="无 .capbox 时 bootstrap 自动脚手架"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖本用例（仅真 CLI 验收）"
  case_finish
  exit 0
fi
mkdir -p "$QA_TMP"

tmpws="$QA_TMP/t22-project"
rm -rf "$tmpws"
mkdir -p "$tmpws"

# 1) version 不应误建空 .capbox
run_cmd bash -c "cd $(printf %q "$tmpws") && $(printf %q "$CAPBOX_BIN") version"
assert_rc 0 "在空项目里 version 退出 0"
if [ -e "$tmpws/.capbox" ]; then
  _fail "version 不应创建 .capbox"
else
  _ok "version 未创建 .capbox"
fi

# 2) bootstrap 脚手架
run_cmd bash -c "cd $(printf %q "$tmpws") && $(printf %q "$CAPBOX_BIN") bootstrap"
assert_rc 0 "bootstrap 退出 0"
assert_file_exists "$tmpws/.capbox/bin/capbox" "生成了 .capbox/bin/capbox"
assert_file_exists "$tmpws/.capbox/lib/common.sh" "生成了 .capbox/lib/common.sh"
if [ -d "$CAPBOX_DIR/skill" ]; then
  assert_file_exists "$tmpws/.capbox/skill/SKILL.md" "skill/SKILL.md 已脚手架"
fi

# 3) 不得从模板拷入 config.env / cache 文件 / rootfs
assert_file_absent "$tmpws/.capbox/config.env" "未复制 config.env"
if [ -d "$tmpws/.capbox/cache" ]; then
  n=$(find "$tmpws/.capbox/cache" -type f 2>/dev/null | wc -l)
  if [ "$n" -gt 0 ]; then
    _fail "bootstrap 不应复制 cache 内文件（找到 $n 个）"
  else
    _ok "cache 无复制文件"
  fi
else
  _ok "无 cache 文件"
fi
if [ -d "$tmpws/.capbox/os" ] && find "$tmpws/.capbox/os" -mindepth 2 -type f 2>/dev/null | grep -q .; then
  _fail "bootstrap 不应复制 rootfs(os/) 内容"
else
  _ok "未复制 os/ rootfs 内容"
fi

# 4) 幂等
run_cmd bash -c "cd $(printf %q "$tmpws") && $(printf %q "$CAPBOX_BIN") bootstrap"
assert_rc 0 "二次 bootstrap 幂等"
assert_file_exists "$tmpws/.capbox/bin/capbox" "二次后 bin 仍在"

# 5) --root 指向空工作区
tmpws2="$QA_TMP/t22-root"
rm -rf "$tmpws2"
mkdir -p "$tmpws2"
run_cmd "$CAPBOX_BIN" --root "$tmpws2" bootstrap
assert_rc 0 "--root bootstrap 退出 0"
assert_file_exists "$tmpws2/.capbox/lib/common.sh" "--root 下生成 lib"

# 6) help 含 bootstrap
run_cmd "$CAPBOX_BIN" --help
assert_out_contains "bootstrap" "--help 列出 bootstrap"

case_finish
exit 0
