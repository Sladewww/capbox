#!/usr/bin/env bash
# T34 — 审计 JSONL + 服务 ready/stop
set -u
CASE_TITLE="audit JSONL 与 service ready"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖"
  case_finish; exit 0
fi
require_rootfs

run_cmd "$CAPBOX_BIN" audit path
assert_rc 0 "audit path"

run_cmd "$CAPBOX_BIN" exec --timeout 15 -- echo audit-t34
assert_rc 0 "exec for audit"
run_cmd "$CAPBOX_BIN" audit tail 20
assert_rc 0 "audit tail"
assert_out_matches '"kind":"exec"' "审计含 exec 事件"

run_cmd "$CAPBOX_BIN" exec --timeout 15 -- sh -c 'echo password=supersecret'
assert_rc 0 "含 password 的命令"
run_cmd "$CAPBOX_BIN" audit tail 5
assert_out_not_matches 'supersecret' "审计不泄露 secret 原文"

mkdir -p "$CAPBOX_DIR/services"
cat >"$CAPBOX_DIR/services/t34ready.env" <<'E'
CMD='sh -c "while true; do sleep 3600; done"'
READY_CMD='true'
STOP_TIMEOUT=3
RESTART=no
E
run_cmd "$CAPBOX_BIN" service start t34ready
assert_rc 0 "service start with READY_CMD"
run_cmd "$CAPBOX_BIN" service status t34ready
assert_rc 0 "service status"
assert_stdout_matches 'state=running' "running"
run_cmd "$CAPBOX_BIN" service stop t34ready
assert_rc 0 "service stop"
rm -f "$CAPBOX_DIR/services/t34ready.env"

case_finish
exit 0
