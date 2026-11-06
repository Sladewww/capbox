# shellcheck shell=bash
# =============================================================================
# CapBox - rootfs.sh
# rootfs 生命周期：镜像定位/缓存/下载/解包、镜像源与代理注入、首次引导、init。
# 依赖 common.sh 已 source。
# =============================================================================

# ---------- 1. 发行版镜像表 ---------------------------------------------------

# 各发行版的固定版本与 tarball 名。校验和见 lib/rootfs-sha256.txt（官方发布文件）。
_capbox_alpine_version() { printf '3.20.3'; }
_capbox_ubuntu_version() { printf '24.04.3'; }

# x86_64 | aarch64。失败时返回 1，不猜测。
_capbox_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x86_64' ;;
    aarch64 | arm64) printf 'aarch64' ;;
    *)
      log_err "不支持的 CPU 架构: $(uname -m)（需要 x86_64 或 aarch64）"
      return 1
      ;;
  esac
}

# ubuntu tarball 用 amd64/arm64，不是 uname 的 x86_64/aarch64
_capbox_ubuntu_arch() {
  case "$(_capbox_arch)" in
    x86_64) printf 'amd64' ;;
    aarch64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

# _distro_tarball_name DISTRO  -> 缓存文件名
_distro_tarball_name() {
  local arch
  arch="$(_capbox_arch)" || return 1
  case "${1:-}" in
    alpine) printf 'alpine-minirootfs-%s-%s.tar.gz' "$(_capbox_alpine_version)" "$arch" ;;
    ubuntu) printf 'ubuntu-base-%s-base-%s.tar.gz' "$(_capbox_ubuntu_version)" "$(_capbox_ubuntu_arch)" ;;
    *) return 1 ;;
  esac
}

_distro_tarball_sha256() {
  local distro="${1:-}" arch key file line
  arch="$(_capbox_arch)" || return 1
  case "$distro" in
    alpine) key="alpine-${arch}" ;;
    ubuntu) key="ubuntu-${arch}" ;;
    *) return 1 ;;
  esac
  file="${CAPBOX_LIB_DIR:-}/rootfs-sha256.txt"
  if [[ ! -f "$file" ]]; then
    file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rootfs-sha256.txt"
  fi
  [[ -f "$file" ]] || {
    log_err "缺少 rootfs 校验和文件: $file"
    return 1
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "$key "*)
        printf '%s' "${line#"$key "}"
        return 0
        ;;
    esac
  done <"$file"
  log_err "rootfs-sha256.txt 没有 $key"
  return 1
}

_tarball_sha256_matches() {
  local f="${1:-}" expect="${2:-}" got
  [[ -n "$expect" && -s "$f" ]] || return 1
  if have_cmd sha256sum; then
    got="$(sha256sum "$f" | awk '{print $1}')"
  elif have_cmd shasum; then
    got="$(shasum -a 256 "$f" | awk '{print $1}')"
  else
    log_err "校验 rootfs 需要 sha256sum"
    return 1
  fi
  [[ "$got" == "$expect" ]]
}

# _distro_tarball_url DISTRO  -> 官方上游 URL（缓存未命中时才用）
_distro_tarball_url() {
  local arch name
  arch="$(_capbox_arch)" || return 1
  name="$(_distro_tarball_name "$1")" || return 1
  case "${1:-}" in
    alpine)
      printf 'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/%s/%s' "$arch" "$name"
      ;;
    ubuntu)
      printf 'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/%s' "$name"
      ;;
    *) return 1 ;;
  esac
}

# 备选下载源（按顺序尝试；先国内镜像）。每个源都要过 SHA256，失败就换下一个。
_distro_tarball_urls() {
  local d="${1:-}" name arch
  arch="$(_capbox_arch)" || return 1
  name="$(_distro_tarball_name "$d")" || return 1
  case "$d" in
    alpine)
      printf '%s\n' \
        "https://mirrors.aliyun.com/alpine/v3.20/releases/${arch}/$name" \
        "https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.20/releases/${arch}/$name" \
        "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/${arch}/$name"
      ;;
    ubuntu)
      printf '%s\n' \
        "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/$name" \
        "https://mirrors.ustc.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/$name" \
        "https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/$name"
      ;;
    *) return 1 ;;
  esac
}

# ---------- 2. 下载与解包 -----------------------------------------------------

# 校验 tarball：gzip 完整性 + 体积下限 + 官方 SHA256（有钉扎时）
_tarball_ok() {
  local f="${1:-}" distro="${2:-}"
  [[ -s "$f" ]] || return 1
  local sz
  sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  (( sz > 100000 )) || return 1
  gzip -t "$f" >/dev/null 2>&1 || return 1
  if [[ -n "$distro" ]]; then
    local expect
    expect="$(_distro_tarball_sha256 "$distro")" || return 1
    _tarball_sha256_matches "$f" "$expect" || return 1
  fi
  return 0
}

# fetch_tarball DISTRO [--url URL] [--force]
# 命中 cache/ 直接复用；否则按备选源下载。输出最终 tarball 路径到 stdout。
fetch_tarball() {
  local distro="${1:-alpine}"
  [[ $# -gt 0 ]] && shift
  local url="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url)
        url="${2:-}"
        shift 2 || shift
        ;;
      --force)
        force=1
        shift
        ;;
      *) shift ;;
    esac
  done

  local name
  name="$(_distro_tarball_name "$distro")" || die 1 "不支持的发行版: $distro（支持: ${CAPBOX_SUPPORTED_DISTROS[*]}）"
  local dst="$CAPBOX_CACHE_DIR/$name"
  mkdir -p "$CAPBOX_CACHE_DIR" || die 1 "无法创建缓存目录: $CAPBOX_CACHE_DIR"

  # 1) 缓存命中
  if (( force == 0 )) && _tarball_ok "$dst" "$distro"; then
    log_info "使用已缓存镜像: $dst"
    printf '%s\n' "$dst"
    return 0
  fi
  if [[ -e "$dst" ]] && ! _tarball_ok "$dst" "$distro"; then
    log_warn "缓存镜像未通过 SHA256，重新下载: $dst"
    rm -f -- "$dst"
  fi
  if (( force == 1 )) && [[ -e "$dst" ]]; then
    log_info "强制重新下载，删除旧缓存: $dst"
    rm -f -- "$dst"
  fi

  # 2) 下载
  need_cmd curl "下载 rootfs 需要 curl"
  local tmp="$dst.part.$RANDOM"
  local -a urls=()
  if [[ -n "$url" ]]; then
    urls=("$url")
  else
    mapfile -t urls < <(_distro_tarball_urls "$distro")
    # 额外：若用户自定义了镜像根，优先尝试拼接
    local root
    root="$(mirror_url_for "$distro")"
    if [[ -n "$root" && "$distro" == "ubuntu" ]]; then
      urls=("$root/../ubuntu-cdimage/ubuntu-base/releases/24.04/release/$name" "${urls[@]}")
    fi
  fi

  local u n=0 ok=0
  for u in "${urls[@]}"; do
    [[ -n "$u" ]] || continue
    n=$(( n + 1 ))
    log_info "下载 $distro rootfs（源 $n/${#urls[@]}）: $u"
    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 1800 \
      -o "$tmp" "$u" 2>/dev/null; then
      if _tarball_ok "$tmp" "$distro"; then
        mv -f -- "$tmp" "$dst"
        log_info "下载完成: $dst（$(human_bytes "$(stat -c %s "$dst" 2>/dev/null || echo 0)")，SHA256 已核对）"
        ok=1
        break
      fi
      log_warn "下载的文件未通过 gzip/SHA256 校验，尝试下一个源"
    else
      log_warn "下载失败: $u"
    fi
    rm -f -- "$tmp" 2>/dev/null || true
  done

  if (( ok == 0 )); then
    rm -f -- "$tmp" 2>/dev/null || true
    die 1 "所有镜像源都下载失败；可手动下载后放到 $dst，或用 --from <本地路径|URL>"
  fi
  printf '%s\n' "$dst"
  return 0
}

# extract_rootfs TARBALL DESTDIR
# 解包到空目录；先解到临时目录再原子替换，避免半成品 rootfs。
extract_rootfs() {
  local tarball="${1:-}"
  local dest="${2:-$CAPBOX_ROOTFS}"
  [[ -s "$tarball" ]] || die 1 "tarball 不存在: $tarball"
  need_cmd tar "解包 rootfs 需要 tar"

  local parent
  parent="$(dirname "$dest")"
  mkdir -p "$parent" || die 1 "无法创建目录: $parent"

  local stage="$parent/.stage-${CAPBOX_DISTRO:-x}-$$"
  rm -rf -- "$stage" 2>/dev/null || true
  mkdir -p "$stage" || die 1 "无法创建暂存目录: $stage"

  log_info "解包 rootfs 到 $dest"
  local rc=0
  tar xzf "$tarball" -C "$stage" --numeric-owner 2>/dev/null
  rc=$?
  # 少数实现/包不支持 --numeric-owner，重试一次
  if (( rc != 0 )); then
    log_debug "tar --numeric-owner 失败（rc=$rc），改用普通模式重试"
    tar xzf "$tarball" -C "$stage" 2>/dev/null
    rc=$?
  fi
  if (( rc != 0 )) || [[ ! -d "$stage" ]]; then
    rm -rf -- "$stage" 2>/dev/null || true
    die 1 "解包失败: $tarball"
  fi
  if ! rootfs_ready_at "$stage"; then
    rm -rf -- "$stage" 2>/dev/null || true
    die 1 "解包结果不含 /bin/sh，镜像可能不完整: $tarball"
  fi

  # 原子替换
  if [[ -e "$dest" ]]; then
    local old="$parent/.old-${CAPBOX_DISTRO:-x}-$$"
    rm -rf -- "$old" 2>/dev/null || true
    mv -- "$dest" "$old" || {
      rm -rf -- "$stage" 2>/dev/null || true
      die 1 "无法替换已存在的 rootfs: $dest"
    }
    mv -- "$stage" "$dest" || die 1 "无法放置 rootfs: $dest"
    rm -rf -- "$old" 2>/dev/null || true
  else
    mv -- "$stage" "$dest" || die 1 "无法放置 rootfs: $dest"
  fi

  log_info "rootfs 就绪: $dest"
  return 0
}

# ---------- 3. 镜像源注入 -----------------------------------------------------

# 逐级创建目录，遇到符号链接就停。不使用 mkdir -p（它会跟着链接走）。
_rootfs_prepare_parent() {
  local parent="${1:-}"
  [[ "$parent" == /* ]] || return 1
  local IFS=/
  local -a parts=()
  read -r -a parts <<< "${parent#/}"
  local cur="" p
  for p in "${parts[@]}"; do
    [[ -n "$p" && "$p" != "." && "$p" != ".." ]] || {
      log_err "拒绝 rootfs 路径中的 . 或 ..: $parent"
      return 1
    }
    cur="${cur}/${p}"
    if [[ -L "$cur" ]]; then
      log_err "拒绝跟随符号链接: $cur"
      return 1
    fi
    if [[ -d "$cur" ]]; then
      continue
    fi
    if [[ -e "$cur" ]]; then
      log_err "路径组件不是目录: $cur"
      return 1
    fi
    mkdir -- "$cur" || return 1
    if [[ -L "$cur" || ! -d "$cur" ]]; then
      log_err "拒绝跟随符号链接: $cur"
      return 1
    fi
  done
  [[ -d "$parent" && ! -L "$parent" ]] || return 1
}

# 从 stdin 写文件。祖先里的符号链接直接失败。
# mv -T 替换最后一级符号链接，不会把内容写进链接目标。
_rootfs_write_file() {
  local dest="${1:-}"
  [[ "$dest" == /* ]] || {
    log_err "拒绝相对 rootfs 路径: ${dest:-<empty>}"
    return 1
  }
  local parent base tmp
  parent="$(dirname -- "$dest")"
  base="$(basename -- "$dest")"
  [[ -n "$base" && "$base" != "." && "$base" != ".." ]] || return 1
  _rootfs_prepare_parent "$parent" || return 1
  if [[ -d "$dest" && ! -L "$dest" ]]; then
    log_err "拒绝把文件写入目录: $dest"
    return 1
  fi
  tmp="$(mktemp "$parent/.capbox-write.XXXXXX")" || return 1
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [[ -L "$tmp" || ! -f "$tmp" ]]; then
    rm -f -- "$tmp"
    log_err "拒绝跟随符号链接写入: $dest"
    return 1
  fi
  if ! mv -T -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# inject_mirrors [DISTRO]
# 按契约 §6 写入 apk/apt 源与 apt 修正项；CAPBOX_MIRROR=none 直接返回。
inject_mirrors() {
  local distro="${1:-$CAPBOX_DISTRO}"
  local rootfs="$CAPBOX_DIR/os/$distro"

  if [[ "${CAPBOX_MIRROR:-cn}" == "none" ]]; then
    log_info "CAPBOX_MIRROR=none，跳过镜像源注入"
    return 0
  fi
  [[ -d "$rootfs" ]] || {
    log_warn "rootfs 不存在，跳过镜像源注入: $rootfs"
    return 0
  }

  local url
  url="$(_http_safe_url "$distro" "$(mirror_url_for "$distro")")"
  if [[ -z "$url" ]]; then
    log_warn "镜像源 URL 为空，跳过注入（检查 CAPBOX_MIRROR_${distro^^}）"
    return 0
  fi

  case "$distro" in
    alpine)
      {
        printf '%s/v3.20/main\n' "$url"
        printf '%s/v3.20/community\n' "$url"
      } | _rootfs_write_file "$rootfs/etc/apk/repositories" || return 1
      log_info "已写入 apk 镜像源: $url/v3.20/{main,community}"
      ;;
    ubuntu)
      local suite="noble"

      # Ubuntu 24.04 起默认用 deb822 格式的 sources.list.d/ubuntu.sources，
      # 它与 sources.list 同时生效（会重复请求且官方地址优先级更高）。
      # 策略：若存在 deb822 文件则直接改写它并删除 sources.list；否则写 sources.list。
      local deb822="$rootfs/etc/apt/sources.list.d/ubuntu.sources"
      if [[ -f "$deb822" || -L "$deb822" ]]; then
        {
          printf '# CapBox 生成，请勿手工修改（用 capbox config set CAPBOX_MIRROR_UBUNTU 覆盖）\n'
          printf 'Types: deb\n'
          printf 'URIs: %s\n' "$url"
          printf 'Suites: %s %s-updates %s-backports\n' "$suite" "$suite" "$suite"
          printf 'Components: main restricted universe multiverse\n'
          printf 'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n'
          printf '\n'
          printf 'Types: deb\n'
          printf 'URIs: %s\n' "$url"
          printf 'Suites: %s-security\n' "$suite"
          printf 'Components: main restricted universe multiverse\n'
          printf 'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n'
        } | _rootfs_write_file "$deb822" || return 1
        # 避免 sources.list 与 deb822 重复
        if [[ -e "$rootfs/etc/apt/sources.list" || -L "$rootfs/etc/apt/sources.list" ]]; then
          rm -f -- "$rootfs/etc/apt/sources.list" 2>/dev/null || true
        fi
      else
        {
          printf '# CapBox 生成，请勿手工修改（用 capbox config set CAPBOX_MIRROR_UBUNTU 覆盖）\n'
          printf 'deb %s %s main restricted universe multiverse\n' "$url" "$suite"
          printf 'deb %s %s-updates main restricted universe multiverse\n' "$url" "$suite"
          printf 'deb %s %s-backports main restricted universe multiverse\n' "$url" "$suite"
          printf 'deb %s %s-security main restricted universe multiverse\n' "$url" "$suite"
        } | _rootfs_write_file "$rootfs/etc/apt/sources.list" || return 1
      fi

      {
        printf '// CapBox 生成：apt 在 userns 沙箱内必须以 root 身份下载（坑 8）\n'
        printf 'Acquire::Sandbox::User "root";\n'
        printf 'Acquire::Retries "3";\n'
        if [[ -n "${CAPBOX_PROXY:-}" ]]; then
          case "$CAPBOX_PROXY" in
            http://* | https://*)
              printf 'Acquire::http::Proxy "%s";\n' "$CAPBOX_PROXY"
              printf 'Acquire::https::Proxy "%s";\n' "$CAPBOX_PROXY"
              ;;
          esac
        fi
      } | _rootfs_write_file "$rootfs/etc/apt/apt.conf.d/99capbox" || return 1

      # 精简镜像没有 apt 用的 keyring 目录时补上，否则 apt update 会抱怨
      _rootfs_prepare_parent "$rootfs/etc/apt/trusted.gpg.d" 2>/dev/null || true
      log_info "已写入 apt 镜像源: $url（suite=$suite）"
      ;;
    *)
      log_warn "未知发行版，跳过镜像源注入: $distro"
      ;;
  esac
  return 0
}

# ---------- 4. 代理注入（容器内配置文件） -------------------------------------

# inject_proxy_files [DISTRO]
# 把代理写进容器内的 profile.d / npm / pip 配置；失败不致命。
inject_proxy_files() {
  local distro="${1:-$CAPBOX_DISTRO}"
  local rootfs="$CAPBOX_DIR/os/$distro"
  [[ -d "$rootfs" ]] || return 0

  local prof="$rootfs/etc/profile.d/capbox-proxy.sh"

  if [[ -z "${CAPBOX_PROXY:-}" ]]; then
    if [[ -e "$prof" || -L "$prof" ]]; then
      rm -f -- "$prof" 2>/dev/null || true
    fi
    return 0
  fi

  local p="$CAPBOX_PROXY"
  local np="localhost,127.0.0.1,::1,*.local"
  {
    printf '# CapBox 生成：容器内代理环境变量\n'
    printf 'export http_proxy=%s\n' "$(_shq "$p")"
    printf 'export https_proxy=%s\n' "$(_shq "$p")"
    printf 'export all_proxy=%s\n' "$(_shq "$p")"
    printf 'export no_proxy=%s\n' "$(_shq "$np")"
    printf 'export HTTP_PROXY=%s\n' "$(_shq "$p")"
    printf 'export HTTPS_PROXY=%s\n' "$(_shq "$p")"
    printf 'export ALL_PROXY=%s\n' "$(_shq "$p")"
    printf 'export NO_PROXY=%s\n' "$(_shq "$np")"
  } | _rootfs_write_file "$prof" || return 1

  # npm（root 用户）
  local npmrc="$rootfs/root/.npmrc"
  {
    printf 'proxy=%s\n' "$p"
    printf 'https-proxy=%s\n' "$p"
  } | _rootfs_write_file "$npmrc" || return 1

  # pip
  local pipconf="$rootfs/etc/pip.conf"
  {
    printf '[global]\n'
    printf 'proxy = %s\n' "$p"
  } | _rootfs_write_file "$pipconf" || return 1

  log_debug "已注入代理文件: $prof"
  return 0
}

# ---------- 5. 首次引导 -------------------------------------------------------

# run_bootstrap [DISTRO]
# 在容器内用一次性容器跑 lib/guest/bootstrap.sh；失败只告警（rootfs 仍可用）。
run_bootstrap() {
  local distro="${1:-$CAPBOX_DISTRO}"
  local rootfs="$CAPBOX_DIR/os/$distro"
  local script="$CAPBOX_GUEST_DIR/bootstrap.sh"

  [[ -f "$script" ]] || {
    log_debug "无 bootstrap.sh，跳过首次引导"
    return 0
  }
  rootfs_ready_at "$rootfs" || {
    log_warn "rootfs 不可执行，跳过首次引导"
    return 0
  }

  log_info "运行首次引导（bootstrap）"
  # bootstrap 通过 /workspace（宿主工作区的 bind 挂载点）可见，避免把脚本往 rootfs 里塞。
  # 路径必须相对工作区推导，不能写死 .capbox —— 目录名由用户决定，
  # 仓库也可能直接放进项目根目录（此时 CAPBOX_DIR == CAPBOX_WORKSPACE）。
  local guest_root guest_script
  guest_root="$(_guest_workspace_path "$CAPBOX_DIR")"
  guest_script="$guest_root/lib/guest/bootstrap.sh"
  local rc=0
  exec_in_guest "sh $(_shq "$guest_script")" /workspace 300
  rc=$?
  if (( rc != 0 )); then
    log_warn "bootstrap 返回 $rc（不致命，rootfs 仍可使用）"
  else
    log_info "首次引导完成"
  fi
  return 0
}

# ---------- 6. init -----------------------------------------------------------

cmd_init() {
  local distro="$CAPBOX_DISTRO"
  local force=0
  local from=""
  local agent=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --distro)
        distro="${2:-}"
        shift 2 || shift
        ;;
      --distro=*)
        distro="${1#*=}"
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      --agent)
        agent=1
        shift
        ;;
      --from)
        from="${2:-}"
        shift 2 || shift
        ;;
      --from=*)
        from="${1#*=}"
        shift
        ;;
      -h | --help)
        cat <<'EOF'
用法: capbox init [--distro alpine|ubuntu] [--force] [--from URL|本地路径] [--agent]

  若当前工作区还没有完整的 .capbox/，会先从已安装的 CapBox 模板脚手架
  bin/、lib/、skill/ 到 $PWD/.capbox（不覆盖已有文件，不复制 cache/os/run）。

  --distro D   选择发行版（默认取 CAPBOX_DISTRO，初始 alpine）
  --force      忽略缓存重新下载，并覆盖已有 rootfs
  --from P     指定镜像来源：http(s) URL 或本地 tarball 路径
  --agent      给 coding agent 的预设：SECURITY_PROFILE=untrusted，NET=none
               pkg install / pkg update 仍出网。其它出网在当次命令声明：
               exec|shell|up --net restricted（需 CAPBOX_NET_ALLOW）或 --net open
EOF
        return 0
        ;;
      *)
        die 2 "init: 未知选项 $1"
        ;;
    esac
  done

  case "$distro" in
    alpine | ubuntu) ;;
    *) die 2 "不支持的发行版: $distro（支持: alpine / ubuntu）" ;;
  esac

  # 先脚手架项目 .capbox（无模板 / 危险工作区时失败）
  if declare -F capbox_scaffold_project >/dev/null 2>&1; then
    capbox_scaffold_project || return 1
  fi

  need_cmd tar
  with_lock init -- _do_init "$distro" "$force" "$from" "$agent"
}

# 仅脚手架：把 CLI 模板的 bin/lib/skill 填进当前工作区 .capbox，不下载 rootfs
cmd_bootstrap() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        cat <<'EOF'
用法: capbox bootstrap

  在当前工作区创建/补齐 .capbox/（从已安装模板复制 bin、lib、skill）。
  不下载 rootfs；随后请运行 capbox init。
EOF
        return 0
        ;;
      *)
        die 2 "bootstrap: 未知选项 $1"
        ;;
    esac
  done
  if declare -F capbox_scaffold_project >/dev/null 2>&1; then
    capbox_scaffold_project || return 1
  else
    die 1 "scaffold 实现不可用"
  fi
  log_info "下一步: capbox init --distro ${CAPBOX_DISTRO:-alpine}"
  return 0
}

_apply_agent_preset() {
  config_set SECURITY_PROFILE untrusted || return $?
  config_set NET none || return $?
  log_info "agent 预设: CAPBOX_SECURITY_PROFILE=untrusted CAPBOX_NET=none"
  log_info "untrusted 会遮盖工作区内的 .ssh .gnupg .aws .azure .kube .docker"
  log_info "pkg install 与 pkg update 会出网。其它命令默认无网络"
  log_info "当次要出网: capbox exec --net restricted -- CMD（需先写 CAPBOX_NET_ALLOW）或 --net open"
  log_info "allowlist：example.com 只放行该主机的 80/443；子域写 *.example.com；任意端口加 :* （例 github.com:22）"
}

# 显式 --from：gzip 必须有效。和官方钉扎一致则记录；不一致只警告。
_tarball_accept_explicit() {
  local f="${1:-}" distro="${2:-}" expect
  _tarball_ok "$f" || return 1
  expect="$(_distro_tarball_sha256 "$distro" 2>/dev/null || true)"
  if [[ -n "$expect" ]] && _tarball_sha256_matches "$f" "$expect"; then
    log_info "显式 rootfs 与官方 SHA256 一致"
  else
    log_warn "显式 --from 的 tarball 与官方 SHA256 不一致，按你指定的来源接受（官方下载路径不会这样）"
  fi
  return 0
}

_do_init() {
  local distro="${1:-}"
  local force="${2:-0}"
  local from="${3:-}"
  local agent="${4:-0}"
  local rootfs="$CAPBOX_DIR/os/$distro"

  log_info "初始化 CapBox 发行版: $distro"

  # 已存在且不强制 -> 幂等直接返回
  if rootfs_ready_at "$rootfs" && (( force == 0 )); then
    log_info "rootfs 已存在，跳过下载与解包: $rootfs"
    _init_finalize "$distro" || return $?
    if [[ "$agent" == "1" ]]; then
      _apply_agent_preset || return $?
    fi
    return 0
  fi

  # 1) 取 tarball
  local tarball=""
  if [[ -n "$from" ]]; then
    case "$from" in
      http://* | https://*)
        log_info "从指定 URL 下载: $from"
        need_cmd curl "从 URL 初始化需要 curl"
        local name
        name="$(_distro_tarball_name "$distro")"
        mkdir -p "$CAPBOX_CACHE_DIR"
        local dst="$CAPBOX_CACHE_DIR/$name"
        if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 1800 -o "$dst.part" "$from"; then
          rm -f "$dst.part" 2>/dev/null || true
          die 1 "下载失败: $from"
        fi
        _tarball_accept_explicit "$dst.part" "$distro" || {
          rm -f "$dst.part" 2>/dev/null || true
          die 1 "下载的文件不是有效的 gzip tarball: $from"
        }
        mv -f "$dst.part" "$dst"
        tarball="$dst"
        ;;
      *)
        [[ -f "$from" ]] || die 1 "本地 tarball 不存在: $from"
        _tarball_accept_explicit "$from" "$distro" || die 1 "不是有效的 gzip tarball: $from"
        tarball="$(resolve_path "$from")"
        # 拷进缓存以便下次复用
        local name2
        name2="$(_distro_tarball_name "$distro")"
        cp -f -- "$tarball" "$CAPBOX_CACHE_DIR/$name2" 2>/dev/null || true
        ;;
    esac
  else
    tarball="$(fetch_tarball "$distro" $( ((force == 1)) && printf '%s' '--force' ))"
    [[ -n "$tarball" ]] || die 1 "无法获取 rootfs 镜像"
  fi

  # 2) 解包（force 时先删旧 rootfs）
  if (( force == 1 )) && [[ -d "$rootfs" ]]; then
    _safe_rm_rootfs "$rootfs" || die 1 "无法删除旧 rootfs"
  fi
  extract_rootfs "$tarball" "$rootfs"

  # 3) 补齐目录
  ensure_rootfs_dirs "$rootfs"

  # 4) 切换配置里的 distro —— 由 _init_finalize 统一处理，
  #    这样「首次解包」与「幂等早退」两条路径行为一致
  #    （曾经只在解包路径上切，导致 init --distro 切换后 exec 仍进旧发行版）
  _init_finalize "$distro" || return $?
  if [[ "$agent" == "1" ]]; then
    _apply_agent_preset || return $?
  fi
}

# 注入镜像源/代理 + 首次引导 + 收尾检查（幂等，重复调用安全）
_init_finalize() {
  local distro="${1:-$CAPBOX_DISTRO}"
  local rootfs="$CAPBOX_DIR/os/$distro"

  if ! rootfs_ready_at "$rootfs"; then
    die 1 "rootfs 不完整（缺可执行 /bin/sh）: $rootfs"
  fi

  # 幂等 init 也必须补齐 config.env（之前只有 distro 变化时才写文件）。
  # 已有文件保持用户配置；缺失时按当前生效值落盘。
  if [[ ! -f "$CAPBOX_DIR/config.env" ]]; then
    CAPBOX_DISTRO="$distro"
    config_save || return 1
  fi

  # 切换配置里的 distro：幂等路径与解包路径都必须经过这里，
  # 否则 `init --distro ubuntu` 会退出 0 但 config 仍停在旧发行版。
  if [[ "$(config_get DISTRO 2>/dev/null | tr -d '\n')" != "$distro" ]]; then
    config_set DISTRO "$distro" || true
  fi
  # 无论走「新建 config」还是「config_set」，都必须同步内存中的
  # CAPBOX_DISTRO 与派生路径。否则缺 config.env 时上面先把 DISTRO 写成
  # 目标值并 config_save，随后 config_get 已相等而跳过 derive，
  # run_bootstrap → exec_in_guest 仍使用启动时缓存的 CAPBOX_ROOTFS（默认 alpine）。
  CAPBOX_DISTRO="$distro"
  _capbox_derive_paths
  rootfs="$CAPBOX_ROOTFS"

  ensure_rootfs_dirs "$rootfs"
  refresh_resolv || true
  inject_mirrors "$distro" || log_warn "镜像源注入失败（可稍后重跑 capbox init）"
  inject_proxy_files "$distro" || log_warn "代理文件注入失败（未跟随符号链接写入）"

  # rootfs 内写一份内置版本标记，便于排查
  {
    printf 'CAPBOX_VERSION=%s\n' "$CAPBOX_VERSION"
    printf 'CAPBOX_DISTRO=%s\n' "$distro"
    printf 'CAPBOX_MIRROR=%s\n' "${CAPBOX_MIRROR:-cn}"
    printf 'INIT_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } | _rootfs_write_file "$rootfs/etc/capbox-release" || log_warn "无法写入 capbox-release"

  run_bootstrap "$distro" || true

  # 预构建数字 uid 降权 helper（BusyBox alpine 无 GNU setpriv/python 时必需）
  if declare -F _idmap_ensure_drop_priv_helper >/dev/null 2>&1; then
    _idmap_ensure_drop_priv_helper || log_warn "drop-priv helper 未就绪（${CAPBOX_IDMAP_DROP_HELPER_DETAIL:-unknown}）；exec --uid 可能失败"
  fi

  local bytes
  bytes="$(dir_bytes "$rootfs")"
  log_info "完成: $rootfs（$(human_bytes "$bytes")）"
  log_info "下一步: capbox exec -- id -u     # 应在容器内输出 0"
  return 0
}

# 供 bin/capbox 的命令表检查
declare -F cmd_init >/dev/null 2>&1
declare -F cmd_bootstrap >/dev/null 2>&1
