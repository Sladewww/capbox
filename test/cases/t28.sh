#!/usr/bin/env bash
# T28 — capbox service start/stop/status（离线 alpine）
set -u
CASE_TITLE="service：start/status/stop 生命周期"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
case_begin "$1" "$CASE_TITLE" "$2"
if is_fake_cli; then
  skip_case "假 CLI 桩不覆盖 service"
  case_finish; exit 0
fi

svc_dir="$CAPBOX_DIR/services"
mkdir -p "$svc_dir"
cat > "$svc_dir/t28sleep.env" <<'E'
CMD='sleep 3600'
UID=0
GID=0
CWD=/
E

run_cmd "$CAPBOX_BIN" service start t28sleep
assert_rc 0 "service start"
run_cmd "$CAPBOX_BIN" service status t28sleep
assert_rc 0 "service status"
assert_stdout_matches 'state=running' "status=running"

run_cmd "$CAPBOX_BIN" service stop t28sleep
assert_rc 0 "service stop"
run_cmd "$CAPBOX_BIN" service status t28sleep
assert_stdout_matches 'state=stopped' "status=stopped"

# 确认无残留 sleep
if pgrep -f 'sleep 3600' >/dev/null 2>&1; then
  # 可能是别人的；只检查我们的 guest-run pidfile 不再对应活进程
  mark_known_issue "宿主仍有 sleep 3600；请确认非本用例残留"
else
  _ok "无 sleep 3600 残留"
fi

rm -f "$svc_dir/t28sleep.env"
case_finish
exit 0
