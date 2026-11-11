#!/bin/sh
# =============================================================================
# CapBox - guest/bootstrap.sh
# 在容器内（一次性的 bwrap 容器，uid 0）执行首次引导。POSIX sh，幂等，可重复运行。
#
# 调用方式（由 capbox init 自动执行）：
#   sh /workspace/.capbox/lib/guest/bootstrap.sh
#
# 设计原则：
#   * 绝不因为某项可选项失败而整体退出（userns 下 chown 报 EINVAL 属正常）。
#   * 只做在 rootfs 内持久生效的事，不改工作区文件。
#   * 反复运行安全；已有产物则跳过。
# =============================================================================

set -u

# 文案由宿主 run_bootstrap 经环境变量注入（已翻译，已按 POSIX 引号转义）。
# 本脚本在 guest 内运行：不得 source 目录，也不得调用 i18n_*。
MARKER=/etc/capbox-bootstrap.done
VERSION="${CAPBOX_VERSION:-0.4.2}"
DISTRO=""

say() { printf '[bootstrap] %s\n' "$*"; }
warn() { printf '[bootstrap] %s %s\n' "${CAPBOX_BOOTSTRAP_WARN_PREFIX:-hint:}" "$*" >&2; }
_bootstrap_fmt() {
  # $1 = 已翻译的 printf 格式；其余为参数。格式来自宿主，不含用户输入。
  _fmt=$1
  shift
  # shellcheck disable=SC2059
  printf "$_fmt" "$@"
}

# ---------- 1. 环境识别 -------------------------------------------------------

if [ -r /etc/alpine-release ]; then
  DISTRO="alpine"
elif [ -r /etc/os-release ]; then
  if grep -q '^ID=ubuntu' /etc/os-release 2>/dev/null; then
    DISTRO="ubuntu"
  fi
fi
[ -n "$DISTRO" ] || DISTRO="${CAPBOX_DISTRO:-${CAPBOX_BOOTSTRAP_UNKNOWN:-unknown}}"

say "$(_bootstrap_fmt "${CAPBOX_BOOTSTRAP_BANNER:-distro: %s; uid=%s; version: %s}" "$DISTRO" "$(id -u 2>/dev/null || echo '?')" "$VERSION")"

# ---------- 2. 基础目录 -------------------------------------------------------

for d in /root /tmp /run /var/tmp /workspace /etc/profile.d; do
  mkdir -p "$d" 2>/dev/null || warn "$(_bootstrap_fmt "${CAPBOX_BOOTSTRAP_CANNOT_CREATE_DIR:-cannot create directory %s}" "$d")"
done
chmod 1777 /tmp /var/tmp 2>/dev/null || true
chmod 0755 /root 2>/dev/null || true

# ---------- 3. /etc/hosts 与 hostname -----------------------------------------

if [ ! -s /etc/hosts ] || ! grep -q 'localhost' /etc/hosts 2>/dev/null; then
  {
    echo '127.0.0.1   localhost'
    echo '::1         localhost ip6-localhost ip6-loopback'
    echo '127.0.1.1   capbox'
  } >/etc/hosts 2>/dev/null || warn "${CAPBOX_BOOTSTRAP_CANNOT_WRITE_HOSTS:-cannot write /etc/hosts}"
fi

printf 'capbox\n' >/etc/hostname 2>/dev/null || true

# ---------- 4. 交互便利：profile.d 片段 ---------------------------------------

cat >/etc/profile.d/capbox-env.sh 2>/dev/null <<'PROFILE'
# CapBox 生成：容器内默认环境
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME="${HOME:-/root}"
if [ -d /workspace ]; then
  # 便捷变量，方便脚本定位宿主工作区
  export CAPBOX_WORKSPACE=/workspace
fi
# 精简镜像常缺 UTF-8 locale，避免 perl/git 等抱怨
export LC_ALL="${LC_ALL:-C.UTF-8}"
PROFILE

# ---------- 5. CA 证书探测（只提示，不装包） ----------------------------------

if [ ! -e /etc/ssl/certs/ca-certificates.crt ] && [ -z "$(ls -A /etc/ssl/certs 2>/dev/null)" ]; then
  warn "${CAPBOX_BOOTSTRAP_NO_CA_CERTS:-no CA certificates in the rootfs; https sources may fail. capbox already bind-mounted the host /etc/ssl/certs read-only,}"
  warn "${CAPBOX_BOOTSTRAP_INSTALL_CA_CERTS:-for lasting use, install the package: capbox pkg install ca-certificates}"
fi

# ---------- 6. /dev /proc 可见性自检 -----------------------------------------

[ -e /proc/self/status ] || warn "${CAPBOX_BOOTSTRAP_PROC_UNAVAILABLE:-/proc is unavailable (unexpected)}"
[ -w /dev ] || warn "${CAPBOX_BOOTSTRAP_DEV_NOT_WRITABLE:-/dev is not writable (unexpected)}"

# ---------- 7. 能力自检（只报告，不失败） ------------------------------------

CAPEFF="$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status 2>/dev/null || echo '')"
if [ -n "$CAPEFF" ]; then
  say "$(_bootstrap_fmt "${CAPBOX_BOOTSTRAP_CAPEFF:-CapEff=%s (not 0000000000000000 when capabilities are complete)}" "$CAPEFF")"
fi

# ---------- 8. 发行版特定收尾 -------------------------------------------------

# 让 apt 在 userns 里可用（若 apt 存在但配置缺失，由 capbox init 注入，这里只兜底）
if [ "$DISTRO" = "ubuntu" ] && [ -d /etc/apt/apt.conf.d ]; then
  if [ ! -f /etc/apt/apt.conf.d/99capbox ]; then
    {
      echo 'Acquire::Sandbox::User "root";'
      echo 'Acquire::Retries "3";'
    } >/etc/apt/apt.conf.d/99capbox 2>/dev/null || true
  fi
fi

# alpine 的 apk 源若为空，提示（实际注入由宿主侧完成）
if [ "$DISTRO" = "alpine" ] && [ ! -s /etc/apk/repositories ]; then
  warn "${CAPBOX_BOOTSTRAP_EMPTY_APK_REPOS:-/etc/apk/repositories is empty; run capbox init or set CAPBOX_MIRROR}"
fi

# ---------- 9. 落标记 ---------------------------------------------------------

{
  echo "version=$VERSION"
  echo "distro=$DISTRO"
  echo "bootstrapped_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
} >"$MARKER" 2>/dev/null || warn "$(_bootstrap_fmt "${CAPBOX_BOOTSTRAP_CANNOT_WRITE_MARKER:-cannot write marker file %s}" "$MARKER")"

say "${CAPBOX_BOOTSTRAP_COMPLETE:-bootstrap complete}"
exit 0
