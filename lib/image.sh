# shellcheck shell=bash
# =============================================================================
# CapBox - image.sh
# rootfs 镜像导出/导入（SHA256）、包版本锁、离线缓存与恢复。
# tar 使用 --numeric-owner，保留多 UID 数字属主。
# 测试与导入绝不默认覆盖正在使用的 rootfs（需 --force 或导入到旁路目录）。
# =============================================================================

_image_dir() { printf '%s' "${CAPBOX_DIR}/images"; }
_image_lock_path() { printf '%s/package.lock' "${CAPBOX_STATE_DIR:-$CAPBOX_DIR/state}"; }
_image_cache_dir() { printf '%s/pkg-cache' "${CAPBOX_DIR}/cache"; }

_image_valid_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]]
}

_image_sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

# 解包到 dest。以 data filter 为底：拒绝绝对成员名、..、特殊文件、
# 以及解析后落到目标目录外的链接。rootfs 里常见的绝对符号链接
# （例如 usr/sbin/add-shell → /bin/busybox）只保存链接文本，允许留下；
# 带 .. 的绝对目标、绝对硬链接仍然拒绝。没有 data filter 的 Python 直接失败。
_image_extract_archive() {
  local arch="${1:-}" dest="${2:-}" tarpath="$1" tmp="" rc=0
  [[ -n "$arch" && -n "$dest" && -d "$dest" && ! -L "$dest" ]] || return 1
  if [[ "$arch" == *.zst ]]; then
    have_cmd zstd || {
      log_err "解包 zst 需要 zstd"
      return 1
    }
    tmp="$(mktemp "${TMPDIR:-/tmp}/capbox-image.XXXXXX.tar")" || return 1
    if ! zstd -q -d -c -- "$arch" >"$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
    tarpath="$tmp"
  fi
  rc=0
  python3 - "$tarpath" "$dest" <<'PY' || rc=$?
import inspect, os, sys, tarfile
src, dest = sys.argv[1], sys.argv[2]
sig = inspect.signature(tarfile.TarFile.extractall)
if "filter" not in sig.parameters or not hasattr(tarfile, "data_filter"):
    sys.stderr.write("python tarfile has no data filter; refusing extract\n")
    sys.exit(1)

def _guest_absolute_symlink(link):
    if not link or "\0" in link or "\\" in link or not link.startswith("/"):
        return False
    return ".." not in link.split("/")

# 绝对符号链接若在 extractall 中途落盘，后面的相对链接会被 realpath 跟出 dest。
# 先跳过，等其余成员都通过 data filter 后再按原链接文本创建。
deferred = []

def capbox_filter(member, dest_path):
    if member.issym() and _guest_absolute_symlink(member.linkname):
        shadow = member.replace(linkname=".", deep=False)
        filtered = tarfile.data_filter(shadow, dest_path)
        deferred.append((filtered.name, member.linkname))
        return None
    return tarfile.data_filter(member, dest_path)

def _inside(path, root):
    path = os.path.realpath(path, strict=os.path.ALLOW_MISSING)
    root = os.path.realpath(root, strict=os.path.ALLOW_MISSING)
    return path == root or path.startswith(root + os.sep)

with tarfile.open(src, "r:*") as tf:
    tf.extractall(dest, numeric_owner=True, filter=capbox_filter)
for name, link in deferred:
    parent = os.path.dirname(name)
    cur = dest
    if parent:
        for part in parent.split("/"):
            if part in ("", ".", ".."):
                sys.stderr.write("refusing symlink path %s\n" % name)
                sys.exit(1)
            cur = os.path.join(cur, part)
            if os.path.islink(cur) or not _inside(cur, dest):
                sys.stderr.write("refusing symlink path %s\n" % name)
                sys.exit(1)
            if not os.path.isdir(cur):
                os.mkdir(cur)
    path = os.path.join(dest, name)
    if os.path.lexists(path) or not _inside(path, dest):
        sys.stderr.write("refusing symlink path %s\n" % name)
        sys.exit(1)
    os.symlink(link, path)
PY
  [[ -n "$tmp" ]] && rm -f -- "$tmp"
  return "$rc"
}

# 真实目录，且 realpath 必须落在 root 下面。
_image_realpath_inside() {
  local path="${1:-}" root="${2:-}" real base
  [[ -n "$path" && -n "$root" && ! -L "$path" ]] || return 1
  real="$(realpath -- "$path" 2>/dev/null)" || return 1
  base="$(realpath -- "$root" 2>/dev/null)" || return 1
  [[ "$real" == "$base" || "$real" == "$base"/* ]] || return 1
  printf '%s\n' "$real"
}

# 把 src 拷进 rootfs 下的相对路径。祖先或目标是符号链接则失败。
_image_install_tree() {
  local src="${1:-}" rel="${2:-}"
  local root dest
  [[ -d "$src" && ! -L "$src" ]] || return 1
  [[ "$rel" == /* || "$rel" == *..* || -z "$rel" ]] && return 1
  root="$(realpath -- "$CAPBOX_ROOTFS" 2>/dev/null)" || return 1
  [[ -d "$root" && ! -L "$CAPBOX_ROOTFS" ]] || return 1
  dest="$root/$rel"
  local cur="$root" part rest="${dest#"$root"/}"
  local IFS=/
  local -a parts=()
  read -r -a parts <<< "$rest"
  for part in "${parts[@]}"; do
    [[ -n "$part" && "$part" != "." && "$part" != ".." ]] || return 1
    if [[ -L "$cur/$part" ]]; then
      log_err "拒绝把镜像内容写入符号链接: $cur/$part"
      return 1
    fi
    if [[ -d "$cur/$part" ]]; then
      cur="$cur/$part"
      continue
    fi
    if [[ -e "$cur/$part" ]]; then
      log_err "缓存目标不是目录: $cur/$part"
      return 1
    fi
    mkdir -- "$cur/$part" || return 1
    cur="$cur/$part"
  done
  [[ "$cur" == "$dest" && -d "$dest" && ! -L "$dest" ]] || return 1
  if find "$src" -type l -print -quit | grep -q .; then
    log_err "缓存树含符号链接，拒绝写入 rootfs"
    return 1
  fi
  cp -a -- "$src/." "$dest/" || return 1
  return 0
}

_image_write_meta() {
  local arch="${1:-}" distro="${2:-}" sum="${3:-}"
  {
    printf 'DISTRO=%s\n' "$(_shq "$distro")"
    printf 'SHA256=%s\n' "$(_shq "$sum")"
    printf 'CREATED_AT=%s\n' "$(_shq "$(date -Iseconds 2>/dev/null || date)")"
    printf 'NUMERIC_OWNER=1\n'
    printf 'CAPBOX_SCHEMA=%s\n' "$(_shq "${CAPBOX_SCHEMA_VERSION:-}")"
  } >"${arch}.meta"
}

cmd_image() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    -h|--help|"")
      cat <<'H'
用法: capbox image <export|import|list|verify|lock|cache> ...

  export NAME              导出当前 rootfs → .capbox/images/NAME.tar.zst|gz + .sha256
  import NAME [--force]    导入到旁路目录 os/<distro>.imported-NAME；--force 才替换当前 rootfs
  list                     列出已导出镜像
  verify NAME              校验 SHA256
  lock save|show|verify|restore [FILE]  保存/查看/验证/按精确版本恢复包锁
  cache save|restore|path  离线包缓存（apk/apt 缓存目录打包）

导入默认不破坏现有 rootfs；--force 会先 snapshot-bak 再替换。
H
      return 0
      ;;
    list)
      local d
      d="$(_image_dir)"
      if [[ ! -d "$d" ]] || [[ -z "$(ls -A "$d" 2>/dev/null | grep -v '\.meta$' || true)" ]]; then
        printf '(无导出镜像)\n'
        return 0
      fi
      ls -lh -- "$d"/*.tar.* 2>/dev/null | grep -v '.sha256' || true
      return 0
      ;;
    export)
      local name="${1:-}"
      _image_valid_name "$name" || die 2 "镜像名非法"
      require_rootfs
      local d out
      d="$(_image_dir)"
      mkdir -p "$d"
      if have_cmd zstd; then
        out="$d/${name}.tar.zst"
        tar --numeric-owner -C "$(dirname "$CAPBOX_ROOTFS")" -cf - "$(basename "$CAPBOX_ROOTFS")" \
          | zstd -q -T0 -o "$out"
      else
        out="$d/${name}.tar.gz"
        tar --numeric-owner -C "$(dirname "$CAPBOX_ROOTFS")" -czf "$out" "$(basename "$CAPBOX_ROOTFS")"
      fi
      local sum
      sum="$(_image_sha256_file "$out")"
      printf '%s\n' "$sum" >"${out}.sha256"
      _image_write_meta "$out" "${CAPBOX_DISTRO}" "$sum"
      log_info "已导出: $out"
      log_info "SHA256: $sum"
      if declare -F audit_event >/dev/null 2>&1; then
        audit_event image ok "object=$name" "detail=export:$sum" "exit=0" "ms=0"
      fi
      printf '%s\n' "$out"
      return 0
      ;;
    verify)
      local name="${1:-}" arch
      _image_valid_name "$name" || die 2 "镜像名非法"
      if [[ -f "$(_image_dir)/${name}.tar.zst" ]]; then arch="$(_image_dir)/${name}.tar.zst"
      elif [[ -f "$(_image_dir)/${name}.tar.gz" ]]; then arch="$(_image_dir)/${name}.tar.gz"
      else die 1 "镜像不存在: $name"; fi
      [[ -f "${arch}.sha256" ]] || die 1 "缺少 ${arch}.sha256"
      local expect got
      expect="$(head -c 64 "${arch}.sha256" | tr -d '\n')"
      got="$(_image_sha256_file "$arch")"
      if [[ "$expect" == "$got" ]]; then
        printf 'OK %s\n' "$got"
        return 0
      fi
      log_err "SHA256 不匹配: expect=$expect got=$got"
      return 1
      ;;
    import)
      local name="" force=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --force) force=1; shift ;;
          -h|--help) cmd_image --help; return 0 ;;
          -*) die 2 "image import: 未知选项 $1" ;;
          *) name="$1"; shift ;;
        esac
      done
      _image_valid_name "$name" || die 2 "镜像名非法"
      cmd_image verify "$name" >/dev/null || return 1
      local arch parent target
      if [[ -f "$(_image_dir)/${name}.tar.zst" ]]; then arch="$(_image_dir)/${name}.tar.zst"
      else arch="$(_image_dir)/${name}.tar.gz"; fi
      parent="$(dirname "$CAPBOX_ROOTFS")"
      target="$parent/${CAPBOX_DISTRO}.imported-${name}"
      if [[ -L "$parent" || -L "$target" || -L "$target.extract" ]]; then
        die 1 "导入目标路径是符号链接"
      fi
      rm -rf --one-file-system -- "$target" "$target.extract"
      mkdir -p -- "$target.extract" || die 1 "无法创建解包目录"
      [[ -d "$target.extract" && ! -L "$target.extract" ]] || die 1 "解包目录不是真实目录"
      _image_extract_archive "$arch" "$target.extract" || die 1 "导入归档解包失败"
      local extracted="$target.extract/$(basename "$CAPBOX_ROOTFS")"
      if [[ ! -d "$extracted" || -L "$extracted" ]]; then
        extracted="$(find "$target.extract" -mindepth 1 -maxdepth 1 -type d -print -quit)"
      fi
      [[ -n "$extracted" ]] || die 1 "导入归档无根目录"
      _image_realpath_inside "$extracted" "$target.extract" >/dev/null || die 1 "导入根目录越出解包目录"
      [[ ! -e "$target" && ! -L "$target" ]] || die 1 "导入目标已存在"
      mv -- "$extracted" "$target" || die 1 "无法放置导入目录"
      [[ -d "$target" && ! -L "$target" ]] || die 1 "导入结果不是真实目录"
      rm -rf --one-file-system -- "$target.extract"
      log_info "已导入到旁路: $target（未替换当前 rootfs）"
      if (( force == 1 )); then
        local bak="$parent/${CAPBOX_DISTRO}.pre-import-$$"
        [[ -d "$CAPBOX_ROOTFS" && ! -L "$CAPBOX_ROOTFS" ]] || die 1 "当前 rootfs 不是真实目录，拒绝 --force"
        [[ ! -e "$bak" && ! -L "$bak" ]] || die 1 "备份路径已存在: $bak"
        mv -- "$CAPBOX_ROOTFS" "$bak" || die 1 "无法挪开当前 rootfs"
        if mv -- "$target" "$CAPBOX_ROOTFS" && [[ -d "$CAPBOX_ROOTFS" && ! -L "$CAPBOX_ROOTFS" ]]; then
          log_info "已 --force 替换当前 rootfs；旧树在 $bak"
        else
          rm -rf --one-file-system -- "$CAPBOX_ROOTFS"
          mv -- "$bak" "$CAPBOX_ROOTFS" || true
          die 1 "替换失败"
        fi
      else
        log_info "如需替换当前 rootfs: capbox image import $name --force"
      fi
      if declare -F audit_event >/dev/null 2>&1; then
        audit_event image ok "object=$name" "detail=import:force=$force" "exit=0" "ms=0"
      fi
      return 0
      ;;
    lock)
      local lsub="${1:-show}"
      case "$lsub" in
        save)
          _package_lock_save || return $?
          ;;
        verify|restore)
          local action="$lsub" lockfile="${2:-$(_image_lock_path)}"
          [[ $# -le 2 ]] || die 2 'image lock: 参数过多'
          if [[ "$action" == verify ]]; then
            _package_lock_verify "$lockfile"
          else
            _package_lock_restore "$lockfile"
          fi
          return $?
          ;;
        show|"")
          [[ -f "$(_image_lock_path)" ]] || { printf '(无 package.lock；先 image lock save)\n'; return 0; }
          cat -- "$(_image_lock_path)"
          ;;
        *) die 2 "image lock: save|show|verify|restore" ;;
      esac
      return 0
      ;;
    cache)
      local csub="${1:-path}"
      shift || true
      case "$csub" in
        path)
          printf '%s\n' "$(_image_cache_dir)"
          ;;
        save)
          require_rootfs
          local cd out
          cd="$(_image_cache_dir)"
          mkdir -p "$cd"
          out="$cd/${CAPBOX_DISTRO}-pkgs-$(date +%Y%m%d%H%M%S).tar.gz"
          # 从 rootfs 内打包包管理器缓存（不碰 mssql 等数据）
          if [[ "${CAPBOX_DISTRO}" == "alpine" ]]; then
            tar --numeric-owner -C "$CAPBOX_ROOTFS" -czf "$out" var/cache/apk 2>/dev/null || \
              tar --numeric-owner -C "$CAPBOX_ROOTFS" -czf "$out" --files-from /dev/null
          else
            tar --numeric-owner -C "$CAPBOX_ROOTFS" -czf "$out" var/cache/apt 2>/dev/null || \
              tar --numeric-owner -C "$CAPBOX_ROOTFS" -czf "$out" --files-from /dev/null
          fi
          local sum
          sum="$(_image_sha256_file "$out")"
          printf '%s\n' "$sum" >"${out}.sha256"
          log_info "离线缓存: $out ($sum)"
          printf '%s\n' "$out"
          ;;
        restore)
          local arch="${1:-}"
          [[ -n "$arch" && -f "$arch" ]] || die 2 "用法: image cache restore ARCHIVE"
          require_rootfs
          if [[ -f "${arch}.sha256" ]]; then
            local expect got
            expect="$(head -c 64 "${arch}.sha256" | tr -d '\n')"
            got="$(_image_sha256_file "$arch")"
            [[ "$expect" == "$got" ]] || die 1 "缓存校验失败"
          fi
          local rel stage
          if [[ "${CAPBOX_DISTRO}" == "alpine" ]]; then
            rel="var/cache/apk"
          else
            rel="var/cache/apt"
          fi
          stage="$(mktemp -d "${CAPBOX_STATE_DIR:-${TMPDIR:-/tmp}}/cache-restore.XXXXXX")" || die 1 "无法创建缓存暂存目录"
          if ! _image_extract_archive "$arch" "$stage"; then
            rm -rf --one-file-system -- "$stage"
            die 1 "缓存归档解包失败"
          fi
          if [[ ! -d "$stage/$rel" || -L "$stage/$rel" ]]; then
            rm -rf --one-file-system -- "$stage"
            die 1 "缓存归档没有 $rel"
          fi
          if ! _image_install_tree "$stage/$rel" "$rel"; then
            rm -rf --one-file-system -- "$stage"
            die 1 "拒绝把缓存写入 rootfs"
          fi
          rm -rf --one-file-system -- "$stage"
          log_info "已恢复离线包缓存到 rootfs"
          ;;
        *) die 2 "image cache: save|restore|path" ;;
      esac
      return 0
      ;;
    *) die 2 "image: 未知子命令 $sub" ;;
  esac
}

_image_doctor_report() {
  local d
  d="$(_image_dir)"
  if [[ -d "$d" ]]; then
    local n
    n="$(ls "$d"/*.tar.* 2>/dev/null | grep -vc sha256 || true)"
    _doctor_pass "镜像目录 $d（约 ${n:-0} 个归档）"
  else
    _doctor_pass "镜像目录尚未创建（image export 时建立）"
  fi
  if [[ -f "$(_image_lock_path)" ]]; then
    _doctor_pass "存在 package.lock"
  fi
}
