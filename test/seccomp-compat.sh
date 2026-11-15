#!/usr/bin/env bash
# Standalone Linux host probe. Run with bwrap >= 0.12.0, outside a restricted outer sandbox.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
# Host binaries are used as workloads. The mount is read-only except for this fixture.
box=(bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / --proc /proc --dev /dev
  --bind "$work" "$work" --chdir "$work" --clearenv --setenv PATH "$PATH"
  --setenv HOME "$work" --setenv TMPDIR "$work" --setenv PROBE_SKIP_IPC "${CAPBOX_PROBE_SKIP_IPC:-0}")
python="$(command -v python3)"
cat > "$work/probe.py" <<'PY'
import ctypes
import errno
import os
import platform
import socket
import sys
import threading

expected = int(sys.argv[1])
raw = ctypes.CDLL(None, use_errno=True).syscall
if expected:
    # Invalid arguments avoid performing the operations.
    for nr, args in ((431, (-1, 0, 0, 0, 0)), (433, (-1, 0, -1))):
        assert raw(nr, *args) == -1 and ctypes.get_errno() == errno.EPERM, nr
status = dict(line.split(":", 1) for line in open("/proc/self/status"))
assert int(status["Seccomp_filters"]) == int(sys.argv[2]), status["Seccomp_filters"]
print(platform.machine(), "seccomp filters", status["Seccomp_filters"].strip(), flush=True)
assert raw(435, 0, 0) == -1
print("clone3 invalid-argument errno", ctypes.get_errno(), flush=True)

if os.environ["PROBE_SKIP_IPC"] != "1":
    with socket.socket(socket.AF_UNIX) as server, socket.socket(socket.AF_UNIX) as client:
        server.bind("test.sock")
        server.listen()
        thread = threading.Thread(target=client.connect, args=("test.sock",))
        thread.start()
        server.settimeout(5)
        conn, _ = server.accept()
        with conn:
            client.sendall(b"capbox")
            assert conn.recv(6) == b"capbox"
        thread.join()
    os.unlink("test.sock")
PY
cat > "$work/thread.go" <<'GO'
package main

import (
	"runtime"
	"sync"
)

func main() {
	var started, done sync.WaitGroup
	started.Add(4)
	done.Add(4)
	release := make(chan struct{})
	for i := 0; i < 4; i++ {
		go func() {
			defer done.Done()
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
			started.Done()
			<-release
		}()
	}
	started.Wait()
	close(release)
	done.Wait()
}
GO
cat > "$work/package.json" <<'JSON'
{"name":"capbox-seccomp-probe","version":"1.0.0","private":true}
JSON
outer="$(awk '/^Seccomp_filters:/ { print $2 }' /proc/self/status)"
[[ "$outer" =~ ^[0-9]+$ ]] || { echo "Cannot count seccomp filters" >&2; exit 1; }
for profile in compat untrusted strict; do
  echo "=== $profile ==="
  args=()
  filtered=0
  if [[ "$profile" != compat ]]; then
    "$python" lib/seccomp-gen.py --profile "$profile" --out "$work/$profile.bpf"
    args=(--disable-userns --seccomp 3)
    filtered=1
  fi
  if [[ "$profile" == compat ]]; then
    : > "$work/compat.bpf"
  fi
  "${box[@]}" "${args[@]}" -- /bin/sh -ec '
    "$1" probe.py "$2" "$3"
    node -e '\''const { Worker } = require("node:worker_threads"); new Worker("0", {eval: true}).on("exit", code => { if (code) process.exitCode = code })'\''
    npm install --offline --ignore-scripts --no-audit --no-fund --package-lock=false
    apt-get --simulate check
    if [ "$4" != 1 ]; then
      GOTOOLCHAIN=local GOPROXY=off go build -o ./thread-probe thread.go
      timeout 10 ./thread-probe
    fi
  ' probe "$python" "$filtered" "$((outer + filtered))" "${CAPBOX_PROBE_SKIP_GO:-0}" 3<"$work/$profile.bpf"
done

"${box[@]}" --unshare-pid -- /bin/sh -ec '
  if test -e /proc/self/fd/9; then
    echo "Inherited FD observed: Bubblewrap guest can see host FD 9"
  else
    echo "Host FD 9 not observed in Bubblewrap guest"
  fi
' 9</dev/null

printf 'invalid\n' > "$work/invalid.bpf"
if "${box[@]}" --seccomp 3 -- /bin/sh -c 'touch "$1/ran"' probe "$work" \
    3<"$work/invalid.bpf"; then
  echo "Malformed BPF unexpectedly accepted" >&2
  exit 1
fi
[[ ! -e "$work/ran" ]]
echo "Malformed BPF rejected before payload"

if [[ "${CAPBOX_PROBE_NETWORK:-1}" == 1 ]]; then
  "$python" - "${box[@]}" <<'PY'
import os
import socket
import subprocess
import sys

guest = """
import errno
import os
import socket
import sys

assert os.readlink('/proc/self/ns/net') != sys.argv[1]
assert [name for _, name in socket.if_nameindex()] == ['lo']
for fd in map(int, sys.argv[3:]):
    try:
        os.fstat(fd)
    except OSError as exc:
        assert exc.errno == errno.EBADF
    else:
        print(f'Inherited host FD observed in private netns: {fd}', flush=True)
with socket.socket() as connection:
    connection.settimeout(2)
    assert connection.connect_ex(('127.0.0.1', int(sys.argv[2]))) == errno.ECONNREFUSED
with socket.socket() as server, socket.socket() as client:
    server.bind(('127.0.0.1', 0))
    server.listen()
    client.settimeout(2)
    client.connect(server.getsockname())
    conn, _ = server.accept()
    conn.close()
with socket.socket() as connection:
    connection.settimeout(2)
    assert connection.connect_ex(('192.0.2.1', 443)) == errno.ENETUNREACH
"""
with socket.socket() as host_listener, open('/dev/null', 'rb') as host_file:
    host_listener.bind(('127.0.0.1', 0))
    host_listener.listen()
    fds = (host_listener.fileno(), host_file.fileno())
    subprocess.run(
        [*sys.argv[1:], '--unshare-net', '--', sys.executable, '-c', guest,
         os.readlink('/proc/self/ns/net'), str(host_listener.getsockname()[1]), *map(str, fds)],
        pass_fds=fds, check=True,
    )
print("Private netns and guest loopback verified; host TCP listener unreachable by address")
PY
fi
