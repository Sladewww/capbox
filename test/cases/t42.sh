#!/usr/bin/env bash
# T42 — capbox shell 无 tty 时从 stdin 读脚本（管道与重定向）
set -u
CASE_TITLE="shell 无 tty：管道与 <file 执行 stdin"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖"
  case_finish; exit 0
fi
require_rootfs

pipe_script="$QA_TMP/pipe-input.sh"
redir_script="$QA_TMP/redir-input.sh"
printf 'id -u\nuname -m\necho SHELL_PIPE_OK\n' >|"$pipe_script"
printf 'id -u\necho SHELL_REDIR_OK\n' >|"$redir_script"

# --- 管道：cat file | capbox shell ---
run_cmd bash -c "cat -- $(printf '%q' "$pipe_script") | $(printf '%q' "$CAPBOX_BIN") shell"
assert_rc 0 "pipe shell 退出码"
assert_stdout_matches $'^0\n' "pipe shell 输出 id -u → 0"
assert_stdout_matches 'SHELL_PIPE_OK' "pipe shell 执行 stdin 末行"

# --- 文件重定向：capbox shell < file ---
run_cmd bash -c "$(printf '%q' "$CAPBOX_BIN") shell < $(printf '%q' "$redir_script")"
assert_rc 0 "redir shell 退出码"
assert_stdout_matches $'^0\n' "redir shell 输出 id -u → 0"
assert_stdout_matches 'SHELL_REDIR_OK' "redir shell 执行 stdin"

# --- 若宿主可 multi idmap：回归后台启动吞 stdin（#40）---
set +e
probe_out=$(CAPBOX_IDMAP=on "$CAPBOX_BIN" doctor 2>&1)
set -e
if printf '%s' "$probe_out" | grep -qE 'UID 映射 multi|uid_map=0:'; then
  run_cmd env CAPBOX_IDMAP=on bash -c "cat -- $(printf '%q' "$pipe_script") | $(printf '%q' "$CAPBOX_BIN") shell"
  assert_rc 0 "idmap=on pipe shell 退出码"
  assert_stdout_matches $'^0\n' "idmap=on pipe 仍输出 id -u"
  assert_stdout_matches 'SHELL_PIPE_OK' "idmap=on 不吞 stdin"
  run_cmd env CAPBOX_IDMAP=on bash -c "$(printf '%q' "$CAPBOX_BIN") shell < $(printf '%q' "$redir_script")"
  assert_rc 0 "idmap=on redir shell 退出码"
  assert_stdout_matches 'SHELL_REDIR_OK' "idmap=on redir 不吞 stdin"
else
  _ok "宿主无 multi idmap（跳过 IDMAP=on 吞 stdin 回归）"
fi

case_finish
exit 0
