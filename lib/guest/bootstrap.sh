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

MARKER=/etc/capbox-bootstrap.done
VERSION="${CAPBOX_VERSION:-0.3.0}"
DISTRO=""

say() { printf '[bootstrap] %s\n' "$*"; }
warn() { printf '[bootstrap] 提示: %s\n' "$*" >&2; }

# ---------- 1. 环境识别 -------------------------------------------------------

if [ -r /etc/alpine-release ]; then
  DISTRO="alpine"
elif [ -r /etc/os-release ]; then
  if grep -q '^ID=ubuntu' /etc/os-release 2>/dev/null; then
    DISTRO="ubuntu"
  fi
fi
[ -n "$DISTRO" ] || DISTRO="${CAPBOX_DISTRO:-未知}"

say "发行版: $DISTRO；uid=$(id -u 2>/dev/null || echo '?')；版本: $VERSION"

# ---------- 2. 基础目录 -------------------------------------------------------

for d in /root /tmp /run /var/tmp /workspace /etc/profile.d; do
  mkdir -p "$d" 2>/dev/null || warn "无法创建目录 $d"
done
chmod 1777 /tmp /var/tmp 2>/dev/null || true
chmod 0755 /root 2>/dev/null || true

# ---------- 3. /etc/hosts 与 hostname -----------------------------------------

if [ ! -s /etc/hosts ] || ! grep -q 'localhost' /etc/hosts 2>/dev/null; then
  {
    echo '127.0.0.1   localhost'
    echo '::1         localhost ip6-localhost ip6-loopback'
    echo '127.0.1.1   capbox'
  } >/etc/hosts 2>/dev/null || warn "无法写 /etc/hosts"
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
  warn "rootfs 内没有 CA 证书；https 源可能失败。capbox 已把宿主 /etc/ssl/certs 只读挂入，"
  warn "如需长期使用请装包：capbox pkg install ca-certificates"
fi

# ---------- 6. /dev /proc 可见性自检 -----------------------------------------

[ -e /proc/self/status ] || warn "/proc 不可用（异常）"
[ -w /dev ] || warn "/dev 不可写（异常）"

# ---------- 7. 能力自检（只报告，不失败） ------------------------------------

CAPEFF="$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status 2>/dev/null || echo '')"
if [ -n "$CAPEFF" ]; then
  say "CapEff=$CAPEFF（全量 capability 时非 0000000000000000）"
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
  warn "/etc/apk/repositories 为空；请运行 capbox init 或设置 CAPBOX_MIRROR"
fi

# ---------- 9. 落标记 ---------------------------------------------------------

{
  echo "version=$VERSION"
  echo "distro=$DISTRO"
  echo "bootstrapped_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
} >"$MARKER" 2>/dev/null || warn "无法写标记文件 $MARKER"

say "引导完成"
exit 0
