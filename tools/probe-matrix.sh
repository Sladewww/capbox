#!/usr/bin/env bash
# Run test/seccomp-compat.sh against several distros with rootless podman.
#
# Each container gets the pinned bubblewrap 0.13.1 when its distro package is
# older than 0.12.0, plus python3, Node.js, npm, Go and the apt simulation
# prerequisites. The repository is mounted read-only at /w. Containers are
# removed after the run unless --keep is passed.
#
# Usage: tools/probe-matrix.sh [--keep] [DISTRO ...]
#   DISTRO: ubuntu-22.04 ubuntu-24.04 ubuntu-26.04 alpine-3.22 (default: all)
#
# Environment:
#   CAPBOX_PROBE_WORK          scratch dir (default: $TMPDIR/capbox-probe-matrix)
#   CAPBOX_PROBE_ROOT          podman storage root (default: $WORK/root)
#   CAPBOX_PROBE_RUNTIME       podman runtime dir (default: $WORK/run)
#   CAPBOX_PROBE_APT_MIRROR    replace archive.ubuntu.com in container sources
#   CAPBOX_PROBE_APK_MIRROR    replace dl-cdn.alpinelinux.org in apk sources
#   CAPBOX_PROBE_GITHUB_PROXY  proxy passed to curl for the bubblewrap tarball
#
# aarch64 is not included: rootless podman needs binfmt/qemu registration on the
# host, which this script does not assume. Use the arm GitHub runner for that.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
repo=$PWD
keep=0
distros=()
for arg in "$@"; do
  case "$arg" in
    --keep) keep=1 ;;
    -h | --help) sed -n '2,24p' "$0"; exit 0 ;;
    *) distros+=("$arg") ;;
  esac
done
(( ${#distros[@]} )) || distros=(ubuntu-22.04 ubuntu-24.04 ubuntu-26.04 alpine-3.22)

command -v podman >/dev/null 2>&1 || {
  echo "podman is required for the local distro matrix" >&2
  exit 2
}

work=${CAPBOX_PROBE_WORK:-${TMPDIR:-/tmp}/capbox-probe-matrix}
mkdir -p -- "$work/logs"
runtime=${CAPBOX_PROBE_RUNTIME:-$work/run}
mkdir -p -- "$runtime"
chmod 700 "$runtime"
export XDG_RUNTIME_DIR="$runtime"
podman_cmd=(podman --root "${CAPBOX_PROBE_ROOT:-$work/root}" --runroot "$runtime"
  --storage-driver vfs --cgroup-manager cgroupfs)
"${podman_cmd[@]}" info >/dev/null

env_flags=()
[[ -n "${CAPBOX_PROBE_APT_MIRROR:-}" ]] && env_flags+=(-e "CAPBOX_PROBE_APT_MIRROR=$CAPBOX_PROBE_APT_MIRROR")
[[ -n "${CAPBOX_PROBE_APK_MIRROR:-}" ]] && env_flags+=(-e "CAPBOX_PROBE_APK_MIRROR=$CAPBOX_PROBE_APK_MIRROR")
[[ -n "${CAPBOX_PROBE_GITHUB_PROXY:-}" ]] && env_flags+=(-e "CAPBOX_PROBE_GITHUB_PROXY=$CAPBOX_PROBE_GITHUB_PROXY")

# Distro selection: image, setup shell, and setup script (stdin).
container_base=(--network host --privileged --security-opt seccomp=unconfined
  -v "$repo:/w:ro")

run_setup() {
  local name=$1 shell=$2
  "${podman_cmd[@]}" exec -i "${env_flags[@]}" "$name" "$shell" -s
}

log_tail() {
  local log=$1
  echo "--- last lines of $log ---" >&2
  tail -n 20 "$log" >&2 || true
}

results=()
failures=0
for spec in "${distros[@]}"; do
  case "$spec" in
    ubuntu-2*.04) image="ubuntu:${spec#ubuntu-}"; setup_shell=bash ;;
    alpine-*) image="alpine:${spec#alpine-}"; setup_shell=sh ;;
    *)
      echo "unknown distro spec: $spec" >&2
      failures=$((failures + 1))
      results+=("$spec UNKNOWN")
      continue
      ;;
  esac
  slug=${spec//[^a-zA-Z0-9_-]/_}
  name="capbox-probe-$slug"
  log="$work/logs/$slug.log"
  echo "=== $spec ($image) ==="
  "${podman_cmd[@]}" rm -f "$name" >/dev/null 2>&1 || true
  if ! "${podman_cmd[@]}" run -d --name "$name" "${container_base[@]}" \
    "$image" sleep infinity >/dev/null; then
    echo "SKIP $spec: podman could not start $image (rootless storage/network setup?)" >&2
    results+=("$spec SKIP")
    failures=$((failures + 1))
    continue
  fi
  if [[ "$image" == ubuntu:* ]]; then
    if ! run_setup "$name" "$setup_shell" <<'EOS' >"$log" 2>&1
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if [[ -n "${CAPBOX_PROBE_APT_MIRROR:-}" ]]; then
  sed -i "s#http://archive.ubuntu.com/ubuntu#${CAPBOX_PROBE_APT_MIRROR}#g; s#http://security.ubuntu.com/ubuntu#${CAPBOX_PROBE_APT_MIRROR}#g" \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
fi
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY
APT=(apt-get -o Acquire::ForceIPv4=true)
"${APT[@]}" update -qq
"${APT[@]}" install -y -qq bubblewrap curl xz-utils tar meson ninja-build \
  gcc libc6-dev pkg-config libcap-dev python3 libseccomp2 nodejs npm golang-go ca-certificates
ver="$(bwrap --version 2>/dev/null | head -n1 || true)"
maj=0; min=0
if [[ "$ver" =~ ^bubblewrap\ ([0-9]+)\.([0-9]+) ]]; then
  maj=$((10#${BASH_REMATCH[1]})); min=$((10#${BASH_REMATCH[2]}))
fi
if (( maj == 0 && min < 12 )); then
  echo "distro bwrap ${ver:-missing} is below 0.12.0; building pinned 0.13.1"
  build=/tmp/bubblewrap-build
  rm -rf "$build"; mkdir -p "$build"
  tarball="$build/bubblewrap-0.13.1.tar.xz"
  curl_args=(-4 -fsSL --retry 3 --connect-timeout 15 --max-time 240)
  [[ -n "${CAPBOX_PROBE_GITHUB_PROXY:-}" ]] && curl_args+=(-x "$CAPBOX_PROBE_GITHUB_PROXY")
  curl "${curl_args[@]}" -o "$tarball" \
    https://github.com/containers/bubblewrap/releases/download/v0.13.1/bubblewrap-0.13.1.tar.xz
  echo "0e85c8702248b8dd64144f594147553650cdd0e4c951690345faace79c217c4d  $tarball" | sha256sum -c -
  tar -xJf "$tarball" -C "$build"
  meson setup "$build/bubblewrap-0.13.1/build" "$build/bubblewrap-0.13.1" -Dselinux=disabled >/dev/null
  ninja -C "$build/bubblewrap-0.13.1/build" bwrap >/dev/null
  install -m 0755 "$build/bubblewrap-0.13.1/build/bwrap" /usr/local/bin/bwrap
fi
echo "bwrap: $(command -v bwrap) $(bwrap --version)"
EOS
    then
      log_tail "$log"
      results+=("$spec SETUP-FAIL")
      failures=$((failures + 1))
      [[ "$keep" == 1 ]] || "${podman_cmd[@]}" rm -f "$name" >/dev/null 2>&1 || true
      continue
    fi
  else
    if ! "${podman_cmd[@]}" exec -i "${env_flags[@]}" "$name" sh -s <<'EOS' >"$log" 2>&1
set -eu
if [ -n "${CAPBOX_PROBE_APK_MIRROR:-}" ]; then
  sed -i "s#dl-cdn.alpinelinux.org#${CAPBOX_PROBE_APK_MIRROR}#g" /etc/apk/repositories
fi
apk update -q
apk add --no-cache -q bash
EOS
    then
      log_tail "$log"
      results+=("$spec SETUP-FAIL")
      failures=$((failures + 1))
      [[ "$keep" == 1 ]] || "${podman_cmd[@]}" rm -f "$name" >/dev/null 2>&1 || true
      continue
    fi
    if ! run_setup "$name" bash <<'EOS' >>"$log" 2>&1
set -euo pipefail
apk add --no-cache -q bubblewrap libseccomp python3 nodejs npm go \
  build-base meson ninja libcap-dev curl tar xz ca-certificates
ver="$(bwrap --version 2>/dev/null | head -n1 || true)"
maj=0; min=0
if [[ "$ver" =~ ^bubblewrap\ ([0-9]+)\.([0-9]+) ]]; then
  maj=$((10#${BASH_REMATCH[1]})); min=$((10#${BASH_REMATCH[2]}))
fi
if (( maj == 0 && min < 12 )); then
  echo "distro bwrap ${ver:-missing} is below 0.12.0; building pinned 0.13.1"
  build=/tmp/bubblewrap-build
  rm -rf "$build"; mkdir -p "$build"
  tarball="$build/bubblewrap-0.13.1.tar.xz"
  curl_args=(-4 -fsSL --retry 3 --connect-timeout 15 --max-time 240)
  [[ -n "${CAPBOX_PROBE_GITHUB_PROXY:-}" ]] && curl_args+=(-x "$CAPBOX_PROBE_GITHUB_PROXY")
  curl "${curl_args[@]}" -o "$tarball" \
    https://github.com/containers/bubblewrap/releases/download/v0.13.1/bubblewrap-0.13.1.tar.xz
  echo "0e85c8702248b8dd64144f594147553650cdd0e4c951690345faace79c217c4d  $tarball" | sha256sum -c -
  tar -xJf "$tarball" -C "$build"
  meson setup "$build/bubblewrap-0.13.1/build" "$build/bubblewrap-0.13.1" -Dselinux=disabled >/dev/null
  ninja -C "$build/bubblewrap-0.13.1/build" bwrap >/dev/null
  install -m 0755 "$build/bubblewrap-0.13.1/build/bwrap" /usr/local/bin/bwrap
fi
echo "bwrap: $(command -v bwrap) $(bwrap --version)"
EOS
    then
      log_tail "$log"
      results+=("$spec SETUP-FAIL")
      failures=$((failures + 1))
      [[ "$keep" == 1 ]] || "${podman_cmd[@]}" rm -f "$name" >/dev/null 2>&1 || true
      continue
    fi
  fi
  if "${podman_cmd[@]}" exec "$name" bash -lc 'cd /w && bash test/seccomp-compat.sh' \
    >>"$log" 2>&1; then
    echo "PASS $spec"
    results+=("$spec PASS")
  else
    echo "FAIL $spec" >&2
    log_tail "$log"
    results+=("$spec FAIL")
    failures=$((failures + 1))
  fi
  [[ "$keep" == 1 ]] || "${podman_cmd[@]}" rm -f "$name" >/dev/null 2>&1 || true
done

echo
echo "=== matrix summary (logs: $work/logs) ==="
printf '%s\n' "${results[@]}"
(( failures == 0 )) || {
  echo "failed: $failures" >&2
  exit 1
}
