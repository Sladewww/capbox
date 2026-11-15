#!/usr/bin/env bash
# Run inside a fresh, user-owned systemd service with Delegate=yes.
set -euo pipefail
[[ $(id -u) != 0 ]]
relative="$(sed -n 's/^0:://p' /proc/self/cgroup)"
[[ -n "$relative" && "$relative" != / ]]
parent="/sys/fs/cgroup$relative"
mkdir "$parent/supervisor"
printf '%s\n' "$$" > "$parent/supervisor/cgroup.procs"
printf '+cpu +memory +pids\n' > "$parent/cgroup.subtree_control"
export CAPBOX_TEST_DELEGATED=1
export CAPBOX_TEST_ROOTFS="${CAPBOX_TEST_ROOTFS:-$PWD/os/alpine}"

python3 test/security/test_agent_workflows.py "$@"
if [[ $# == 0 ]]; then
  python3 test/security/test_task_checkpoint.py
  python3 test/security/test_envkit.py
fi
