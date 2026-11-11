# shellcheck shell=bash
# =============================================================================
# CapBox —— rootfs.sh（rootfs 生命周期）
# rootfs 生命周期：镜像定位/缓存/下载/解包、镜像源与代理注入、首次引导、init。
# 依赖 common.sh 已 source。
# =============================================================================

# ---------- 1. 发行版镜像表 ---------------------------------------------------

# 各发行版的固定版本与 tarball 名。校验和见 lib/rootfs-sha256.txt（官方发布文件）。
_capbox_alpine_version() { printf '3.24.4'; }
_capbox_ubuntu_version() { printf '24.04.3'; }

# x86_64 | aarch64。失败时返回 1，不猜测。
_capbox_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x86_64' ;;
    aarch64 | arm64) printf 'aarch64' ;;
    *)
      i18n_err rootfs.unsupported_cpu_architecture_x86_64_aarch64_required arch="$(uname -m)"
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
    i18n_err rootfs.missing_rootfs_checksum_file file="$file"
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
  i18n_err rootfs.rootfs_sha256_txt_has_no key="$key"
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
    i18n_err rootfs.verifying_rootfs_requires_sha256sum
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
      printf 'https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/%s/%s' "$arch" "$name"
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
        "https://mirrors.aliyun.com/alpine/v3.24/releases/${arch}/$name" \
        "https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.24/releases/${arch}/$name" \
        "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/${arch}/$name"
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

# fetch_tarball DISTRO [--url URL] [--force]：获取发行版 tarball
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
  name="$(_distro_tarball_name "$distro")" || i18n_die 1 rootfs.unsupported_distro_supported distro="$distro" distros="${CAPBOX_SUPPORTED_DISTROS[*]}"
  local dst="$CAPBOX_CACHE_DIR/$name"
  mkdir -p "$CAPBOX_CACHE_DIR" || i18n_die 1 rootfs.unable_create_cache_directory cache_dir="$CAPBOX_CACHE_DIR"

  # 1) 缓存命中
  if (( force == 0 )) && _tarball_ok "$dst" "$distro"; then
    i18n_info rootfs.using_cached_image dst="$dst"
    printf '%s\n' "$dst"
    return 0
  fi
  if [[ -e "$dst" ]] && ! _tarball_ok "$dst" "$distro"; then
    i18n_warn rootfs.cached_image_failed_sha256_re_downloading dst="$dst"
    rm -f -- "$dst"
  fi
  if (( force == 1 )) && [[ -e "$dst" ]]; then
    i18n_info rootfs.forcing_re_download_removing_old_cache dst="$dst"
    rm -f -- "$dst"
  fi

  # 2) 下载
  need_cmd curl rootfs.need_curl_to_download
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
    i18n_info rootfs.downloading_rootfs_source distro="$distro" n="$n" total="${#urls[@]}" u="$u"
    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 1800 \
      -o "$tmp" "$u" 2>/dev/null; then
      if _tarball_ok "$tmp" "$distro"; then
        mv -f -- "$tmp" "$dst"
        i18n_info rootfs.download_complete_sha256_checked dst="$dst" size="$(human_bytes "$(stat -c %s "$dst" 2>/dev/null || echo 0)")"
        ok=1
        break
      fi
      i18n_warn rootfs.downloaded_file_failed_gzip_sha256_checks_trying
    else
      i18n_warn rootfs.download_failed u="$u"
    fi
    rm -f -- "$tmp" 2>/dev/null || true
  done

  if (( ok == 0 )); then
    rm -f -- "$tmp" 2>/dev/null || true
    i18n_die 1 rootfs.all_image_mirrors_failed_you_can_download dst="$dst"
  fi
  printf '%s\n' "$dst"
  return 0
}

# extract_rootfs TARBALL DESTDIR：解包 rootfs
# 解包到空目录；先解到临时目录再原子替换，避免半成品 rootfs。
extract_rootfs() {
  local tarball="${1:-}"
  local dest="${2:-$CAPBOX_ROOTFS}"
  [[ -s "$tarball" ]] || i18n_die 1 rootfs.tarball_does_not_exist tarball="$tarball"
  need_cmd tar rootfs.need_tar_to_unpack

  local parent
  parent="$(dirname "$dest")"
  mkdir -p "$parent" || i18n_die 1 rootfs.unable_create_directory parent="$parent"

  local stage="$parent/.stage-${CAPBOX_DISTRO:-x}-$$"
  rm -rf -- "$stage" 2>/dev/null || true
  mkdir -p "$stage" || i18n_die 1 rootfs.unable_create_staging_directory stage="$stage"

  i18n_info rootfs.extracting_rootfs dest="$dest"
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
    i18n_die 1 rootfs.extract_failed tarball="$tarball"
  fi
  if ! rootfs_ready_at "$stage"; then
    rm -rf -- "$stage" 2>/dev/null || true
    i18n_die 1 rootfs.extract_result_has_no_bin_sh_image tarball="$tarball"
  fi

  # 原子替换
  if [[ -e "$dest" ]]; then
    local old="$parent/.old-${CAPBOX_DISTRO:-x}-$$"
    rm -rf -- "$old" 2>/dev/null || true
    mv -- "$dest" "$old" || {
      rm -rf -- "$stage" 2>/dev/null || true
      i18n_die 1 rootfs.unable_replace_existing_rootfs dest="$dest"
    }
    mv -- "$stage" "$dest" || i18n_die 1 rootfs.unable_put_rootfs_place dest="$dest"
    rm -rf -- "$old" 2>/dev/null || true
  else
    mv -- "$stage" "$dest" || i18n_die 1 rootfs.unable_put_rootfs_place dest="$dest"
  fi

  i18n_info rootfs.rootfs_ready dest="$dest"
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
      i18n_err rootfs.refusing_rootfs_path parent="$parent"
      return 1
    }
    cur="${cur}/${p}"
    if [[ -L "$cur" ]]; then
      i18n_err rootfs.refusing_follow_symlink cur="$cur"
      return 1
    fi
    if [[ -d "$cur" ]]; then
      continue
    fi
    if [[ -e "$cur" ]]; then
      i18n_err rootfs.path_component_not_directory cur="$cur"
      return 1
    fi
    mkdir -- "$cur" || return 1
    if [[ -L "$cur" || ! -d "$cur" ]]; then
      i18n_err rootfs.refusing_follow_symlink cur="$cur"
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
    i18n_err rootfs.refusing_relative_rootfs_path dest="${dest:-<empty>}"
    return 1
  }
  local parent base tmp
  parent="$(dirname -- "$dest")"
  base="$(basename -- "$dest")"
  [[ -n "$base" && "$base" != "." && "$base" != ".." ]] || return 1
  _rootfs_prepare_parent "$parent" || return 1
  if [[ -d "$dest" && ! -L "$dest" ]]; then
    i18n_err rootfs.refusing_write_file_onto_directory dest="$dest"
    return 1
  fi
  tmp="$(mktemp "$parent/.capbox-write.XXXXXX")" || return 1
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [[ -L "$tmp" || ! -f "$tmp" ]]; then
    rm -f -- "$tmp"
    i18n_err rootfs.refusing_follow_symlink_when_writing dest="$dest"
    return 1
  fi
  if ! mv -T -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# inject_mirrors [DISTRO]：注入镜像源
# 按契约 §6 写入 apk/apt 源与 apt 修正项；CAPBOX_MIRROR=none 直接返回。
inject_mirrors() {
  local distro="${1:-$CAPBOX_DISTRO}"
  local rootfs="$CAPBOX_DIR/os/$distro"

  if [[ "${CAPBOX_MIRROR:-cn}" == "none" ]]; then
    i18n_info rootfs.capbox_mirror_none_skipping_mirror_injection
    return 0
  fi
  [[ -d "$rootfs" ]] || {
    i18n_warn rootfs.rootfs_does_not_exist_skipping_mirror_injection rootfs="$rootfs"
    return 0
  }

  local url
  url="$(_http_safe_url "$distro" "$(mirror_url_for "$distro")")"
  if [[ -z "$url" ]]; then
    i18n_warn rootfs.mirror_url_empty_skipping_injection_check_capbox distro_uc="${distro^^}"
    return 0
  fi

  case "$distro" in
    alpine)
      {
        printf '%s/v3.24/main\n' "$url"
        printf '%s/v3.24/community\n' "$url"
      } | _rootfs_write_file "$rootfs/etc/apk/repositories" || return 1
      i18n_info rootfs.wrote_apk_repositories_v3_24 url="$url"
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
      i18n_info rootfs.wrote_apt_sources_suite url="$url" suite="$suite"
      ;;
    *)
      i18n_warn rootfs.unknown_distro_skipping_mirror_injection distro="$distro"
      ;;
  esac
  return 0
}

# ---------- 4. 代理注入（容器内配置文件） -------------------------------------

# inject_proxy_files [DISTRO]：注入容器内代理配置
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

  # pip 配置
  local pipconf="$rootfs/etc/pip.conf"
  {
    printf '[global]\n'
    printf 'proxy = %s\n' "$p"
  } | _rootfs_write_file "$pipconf" || return 1

  log_debug "已注入代理文件: $prof"
  return 0
}

# ---------- 5. 首次引导 -------------------------------------------------------

# run_bootstrap [DISTRO]：首次引导
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
    i18n_warn rootfs.rootfs_not_executable_skipping_first_boot
    return 0
  }

  i18n_info rootfs.running_first_boot_bootstrap
  # bootstrap 通过 /workspace（宿主工作区的 bind 挂载点）可见，避免把脚本往 rootfs 里塞。
  # 路径必须相对工作区推导，不能写死 .capbox —— 目录名由用户决定，
  # 仓库也可能直接放进项目根目录（此时 CAPBOX_DIR == CAPBOX_WORKSPACE）。
  local guest_root guest_script
  guest_root="$(_guest_workspace_path "$CAPBOX_DIR")"
  guest_script="$guest_root/lib/guest/bootstrap.sh"
  local rc=0
  exec_in_guest "CAPBOX_VERSION=$(_shq "$CAPBOX_VERSION") sh $(_shq "$guest_script")" /workspace 300
  rc=$?
  if (( rc != 0 )); then
    i18n_warn rootfs.bootstrap_returned_not_fatal_rootfs_still_usable rc="$rc"
  else
    i18n_info rootfs.first_boot_complete
  fi
  return 0
}

# ---------- 6. init（初始化 rootfs） ------------------------------------------

cmd_init() {
  local distro="$CAPBOX_DISTRO"
  local force=0
  local from=""
  local agent=0
  local trusted=0

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
      --trusted)
        trusted=1
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
        i18n_print help.init
        return 0
        ;;
      *)
        i18n_die 2 rootfs.init_unknown_option arg="$1"
        ;;
    esac
  done

  (( agent + trusted <= 1 )) || i18n_die 2 rootfs.agent_trusted_cannot_together

  case "$distro" in
    alpine | ubuntu) ;;
    *) i18n_die 2 rootfs.unsupported_distro_supported_alpine_ubuntu distro="$distro" ;;
  esac

  # 先脚手架项目 .capbox（无模板 / 危险工作区时失败）
  if declare -F capbox_scaffold_project >/dev/null 2>&1; then
    capbox_scaffold_project || return 1
  fi

  if (( trusted == 1 )); then
    config_apply SECURITY_PROFILE compat NET open IDMAP auto RESOURCES_MODE warn || return $?
  fi
  need_cmd tar
  local t0 rc=0 _init_cmd="init --distro $distro"
  t0=$(date +%s%3N 2>/dev/null || date +%s)
  (( force == 1 )) && _init_cmd+=" --force"
  [[ -n "$from" ]] && _init_cmd+=" --from $from"
  (( agent == 1 )) && _init_cmd+=" --agent"
  (( trusted == 1 )) && _init_cmd+=" --trusted"
  with_lock init -- _do_init "$distro" "$force" "$from" "$agent"
  rc=$?
  if declare -F audit_command >/dev/null 2>&1; then
    if (( rc == 0 )); then
      audit_command init "$rc" "$t0" "cmd=$_init_cmd"
    else
      audit_command init "$rc" "$t0" "cmd=$_init_cmd" "detail=init 失败，退出码 $rc"
    fi
  fi
  return "$rc"
}

# 仅脚手架：把 CLI 模板的 bin/lib/skill 填进当前工作区 .capbox，不下载 rootfs
cmd_bootstrap() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        i18n_print help.bootstrap
        return 0
        ;;
      *)
        i18n_die 2 rootfs.bootstrap_unknown_option arg="$1"
        ;;
    esac
  done
  if declare -F capbox_scaffold_project >/dev/null 2>&1; then
    capbox_scaffold_project || return 1
  else
    i18n_die 1 rootfs.scaffold_implementation_unavailable
  fi
  i18n_info rootfs.next_capbox_init_distro distro="${CAPBOX_DISTRO:-alpine}"
  return 0
}

_apply_agent_preset() {
  config_apply SECURITY_PROFILE untrusted NET none IDMAP off RESOURCES_MODE require || return $?
  i18n_info rootfs.agent_preset_security_profile_untrusted_net_none
  i18n_info rootfs.resource_limits_must_set_separately_via_memory
  i18n_info rootfs.untrusted_hides_ssh_gnupg_aws_azure_kube
  i18n_info rootfs.pkg_install_pkg_update_will_network_other
  i18n_info rootfs.one_shot_network_grant_capbox_exec_net
  i18n_info rootfs.allowlist_example_com_allows_only_ports_80
}

# 显式 --from：gzip 必须有效。和官方钉扎一致则记录；不一致只警告。
_tarball_accept_explicit() {
  local f="${1:-}" distro="${2:-}" expect
  _tarball_ok "$f" || return 1
  expect="$(_distro_tarball_sha256 "$distro" 2>/dev/null || true)"
  if [[ -n "$expect" ]] && _tarball_sha256_matches "$f" "$expect"; then
    i18n_info rootfs.explicit_rootfs_matches_official_sha256
  else
    i18n_warn rootfs.explicit_tarball_does_not_match_official_sha256
  fi
  return 0
}

_do_init() {
  local distro="${1:-}"
  local force="${2:-0}"
  local from="${3:-}"
  local agent="${4:-0}"
  local rootfs="$CAPBOX_DIR/os/$distro"

  i18n_info rootfs.initializing_capbox_distro distro="$distro"

  # 已存在且不强制 -> 幂等直接返回
  if rootfs_ready_at "$rootfs" && (( force == 0 )); then
    i18n_info rootfs.rootfs_already_exists_skipping_download_extract rootfs="$rootfs"
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
        i18n_info rootfs.downloading_specified_url from="$from"
        need_cmd curl rootfs.need_curl_to_init_from_url
        local name
        name="$(_distro_tarball_name "$distro")"
        mkdir -p "$CAPBOX_CACHE_DIR"
        local dst="$CAPBOX_CACHE_DIR/$name"
        if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 1800 -o "$dst.part" "$from"; then
          rm -f "$dst.part" 2>/dev/null || true
          i18n_die 1 rootfs.download_failed_2 from="$from"
        fi
        _tarball_accept_explicit "$dst.part" "$distro" || {
          rm -f "$dst.part" 2>/dev/null || true
          i18n_die 1 rootfs.downloaded_file_not_valid_gzip_tarball from="$from"
        }
        mv -f "$dst.part" "$dst"
        tarball="$dst"
        ;;
      *)
        [[ -f "$from" ]] || i18n_die 1 rootfs.local_tarball_does_not_exist from="$from"
        _tarball_accept_explicit "$from" "$distro" || i18n_die 1 rootfs.not_valid_gzip_tarball from="$from"
        tarball="$(resolve_path "$from")"
        # 拷进缓存以便下次复用
        local name2
        name2="$(_distro_tarball_name "$distro")"
        cp -f -- "$tarball" "$CAPBOX_CACHE_DIR/$name2" 2>/dev/null || true
        ;;
    esac
  else
    tarball="$(fetch_tarball "$distro" $( ((force == 1)) && printf '%s' '--force' ))"
    [[ -n "$tarball" ]] || i18n_die 1 rootfs.unable_obtain_rootfs_image
  fi

  # 2) 解包（force 时先删旧 rootfs）
  if (( force == 1 )) && [[ -d "$rootfs" ]]; then
    _safe_rm_rootfs "$rootfs" || i18n_die 1 rootfs.unable_remove_old_rootfs
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
    i18n_die 1 rootfs.rootfs_incomplete_missing_executable_bin_sh rootfs="$rootfs"
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
  inject_mirrors "$distro" || i18n_warn rootfs.mirror_injection_failed_you_can_rerun_capbox
  inject_proxy_files "$distro" || i18n_warn rootfs.proxy_file_injection_failed_did_not_follow

  # rootfs 内写一份内置版本标记，便于排查
  {
    printf 'CAPBOX_VERSION=%s\n' "$CAPBOX_VERSION"
    printf 'CAPBOX_DISTRO=%s\n' "$distro"
    printf 'CAPBOX_MIRROR=%s\n' "${CAPBOX_MIRROR:-cn}"
    printf 'INIT_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } | _rootfs_write_file "$rootfs/etc/capbox-release" || i18n_warn rootfs.unable_write_capbox_release

  run_bootstrap "$distro" || true

  # 预构建数字 uid 降权 helper（BusyBox alpine 无 GNU setpriv/python 时必需）
  if declare -F _idmap_ensure_drop_priv_helper >/dev/null 2>&1; then
    _idmap_ensure_drop_priv_helper || i18n_warn rootfs.drop_priv_helper_not_ready_exec_uid detail="${CAPBOX_IDMAP_DROP_HELPER_DETAIL:-unknown}"
  fi

  local bytes
  bytes="$(dir_bytes "$rootfs")"
  i18n_info rootfs.done rootfs="$rootfs" size="$(human_bytes "$bytes")"
  i18n_info rootfs.next_capbox_exec_id_u_should_print
  return 0
}

# 供 bin/capbox 的命令表检查
declare -F cmd_init >/dev/null 2>&1
declare -F cmd_bootstrap >/dev/null 2>&1
