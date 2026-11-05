#!/usr/bin/env bash
# T20 — SKILL.md 可被发现：frontmatter 含 name: capbox 与 description，
#       且 .dsh/skills/capbox/SKILL.md 存在
set -u
CASE_TITLE="SKILL.md 可被发现：frontmatter 合规且 .dsh/skills/capbox/SKILL.md 存在"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"

skill="$CAPBOX_TEST_WS/.dsh/skills/capbox/SKILL.md"
if [ ! -f "$skill" ] && [ -f "$CAPBOX_DIR/skill/SKILL.md" ]; then
  # 仓库即安装 / 模板树：skill 在 CapBox 根下；.dsh 链接触为可选
  skill="$CAPBOX_DIR/skill/SKILL.md"
  _ok "SKILL.md 位于模板树 $skill（无 .dsh/skills 链接时回退）"
fi
assert_file_exists "$skill" "SKILL.md 可发现（.dsh/skills/capbox 或 CAPBOX_DIR/skill）"

if [ ! -f "$skill" ]; then
  case_finish
  exit 0
fi

# 契约 §7：frontmatter 含 name: capbox 与 description
head_block=$(sed -n '1,40p' "$skill")
if printf '%s' "$head_block" | head -n 1 | grep -qx -- '---'; then
  _ok "SKILL.md 以 '---' frontmatter 开头"
else
  _fail "SKILL.md 首行不是 '---'（frontmatter 缺失）" "首行: $(printf '%s' "$head_block" | head -n 1)"
fi

fm=$(printf '%s\n' "$head_block" | sed -n '2,/^---$/p')

if printf '%s' "$fm" | grep -qE '^name:[[:space:]]*capbox[[:space:]]*$'; then
  _ok "frontmatter 含 name: capbox"
else
  got=$(printf '%s' "$fm" | grep -E '^name:' | head -n 1)
  _fail "frontmatter 缺 'name: capbox'" "实际: ${got:-<无 name 行>}"
fi

desc_line=$(printf '%s' "$fm" | grep -E '^description:' | head -n 1)
if [ -n "$desc_line" ]; then
  _ok "frontmatter 含 description"
  # description 是唯一常驻上下文，必须足够长以覆盖触发场景
  dlen=$(printf '%s' "$desc_line" | sed 's/^description:[[:space:]]*//' | wc -c)
  assert_int_gt "$dlen" 40 "description 长度（应足以覆盖触发场景）"
else
  _fail "frontmatter 缺 'description'"
fi

# 检查 frontmatter 正确闭合
close=$(printf '%s\n' "$head_block" | sed -n '2,40p' | grep -n -- '^---$' | head -n 1)
if [ -n "$close" ]; then
  _ok "frontmatter 有闭合 '---'"
else
  _fail "frontmatter 未闭合（前 40 行内没有第二个 '---'）"
fi

# 正文非空且提到最关键的 die-with-parent 约束（契约 §7 + SKILL 的硬性要求）
body_lines=$(wc -l <"$skill")
assert_int_gt "$body_lines" 20 "SKILL.md 正文行数（应是可执行步骤，而不是空壳）"
if grep -qiE 'die-with-parent|background job|后台 ?job|run_in_background' "$skill"; then
  _ok "SKILL.md 提到常驻容器必须用后台 job（关键约束）"
else
  _fail "SKILL.md 未提到 die-with-parent / 后台 job 约束（这是最容易踩的坑）"
fi

# 可选：reference/ 渐进披露（契约 §7 未强制，缺失只记 KNOWN-ISSUE）
if [ -d "$CAPBOX_TEST_WS/.dsh/skills/capbox/reference" ]; then
  n=$(find "$CAPBOX_TEST_WS/.dsh/skills/capbox/reference" -type f | wc -l)
  _ok "reference/ 渐进披露目录存在（$n 个文件）"
else
  mark_known_issue "没有 .dsh/skills/capbox/reference/ 目录；契约 §7 只要求 SKILL.md 可发现，故不判 FAIL"
fi

# 备注：本用例前所有用例都在 .capbox/ 里跑；SKILL.md 可能后于测试套件完成
case_finish
exit 0
