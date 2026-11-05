#!/usr/bin/env bash
# T24 — 声明式 recipe：KEY=value 安全解析 + apply 写配置
set -u
CASE_TITLE="recipe：安全 KEY=value 解析与 apply"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖 recipe"
  case_finish
  exit 0
fi

mkdir -p "$QA_TMP"
recipe="$QA_TMP/t24.recipe"
pwn="$QA_TMP/t24-pwned"
rm -f "$pwn"

# 恶意 recipe：不得被 source/eval
{
  printf '# t24 recipe\n'
  printf "DISTRO=alpine\n"
  printf "NET=open\n"
  printf "MEMORY_MAX=128M\n"
  printf "INIT=0\n"
  printf '$(touch %s)\n' "$pwn"
  printf "PACKAGES=\n"
} >"$recipe"

run_cmd "$CAPBOX_BIN" recipe show "$recipe"
assert_rc 0 "recipe show 退出 0"
assert_out_contains "MEMORY_MAX=128M" "show 含配方内容"

run_cmd "$CAPBOX_BIN" recipe apply "$recipe"
assert_rc 0 "recipe apply 退出 0"
if [ -e "$pwn" ]; then
  _fail "recipe 中的 shell 片段被执行（应只做 KEY=value 解析）"
else
  _ok "recipe 恶意 shell 未被执行"
fi

run_cmd "$CAPBOX_BIN" config get CAPBOX_MEMORY_MAX
assert_rc 0 "apply 后可读取 MEMORY_MAX"
assert_stdout_eq "128M" "MEMORY_MAX 已写入配置"

# 非法值
bad="$QA_TMP/t24-bad.recipe"
printf 'NET=bogus\nINIT=0\n' >"$bad"
run_cmd "$CAPBOX_BIN" recipe apply "$bad"
assert_rc 2 "非法 NET 的 recipe 被拒绝"

# help 列出 recipe
run_cmd "$CAPBOX_BIN" --help
assert_out_contains "recipe" "--help 列出 recipe"

case_finish
exit 0
