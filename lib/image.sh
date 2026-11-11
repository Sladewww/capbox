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
      i18n_err image.extracting_zst_requires_zstd
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
      i18n_err image.refusing_write_image_contents_symlink cur="$cur" part="$part"
      return 1
    fi
    if [[ -d "$cur/$part" ]]; then
      cur="$cur/$part"
      continue
    fi
    if [[ -e "$cur/$part" ]]; then
      i18n_err image.cache_target_not_directory cur="$cur" part="$part"
      return 1
    fi
    mkdir -- "$cur/$part" || return 1
    cur="$cur/$part"
  done
  [[ "$cur" == "$dest" && -d "$dest" && ! -L "$dest" ]] || return 1
  if find "$src" -type l -print -quit | grep -q .; then
    i18n_err image.cache_tree_contains_symlink_refusing_write_rootfs
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
      i18n_print help.image
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
      _image_valid_name "$name" || i18n_die 2 image.invalid_image_name
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
      i18n_info image.exported out="$out"
      i18n_info image.sha256 sum="$sum"
      if declare -F audit_event >/dev/null 2>&1; then
        audit_event image ok "object=$name" "detail=export:$sum" "exit=0" "ms=0"
      fi
      printf '%s\n' "$out"
      return 0
      ;;
    verify)
      local name="${1:-}" arch
      _image_valid_name "$name" || i18n_die 2 image.invalid_image_name
      if [[ -f "$(_image_dir)/${name}.tar.zst" ]]; then arch="$(_image_dir)/${name}.tar.zst"
      elif [[ -f "$(_image_dir)/${name}.tar.gz" ]]; then arch="$(_image_dir)/${name}.tar.gz"
      else i18n_die 1 image.image_does_not_exist name="$name"; fi
      [[ -f "${arch}.sha256" ]] || i18n_die 1 image.missing_sha256 arch="${arch}"
      local expect got
      expect="$(head -c 64 "${arch}.sha256" | tr -d '\n')"
      got="$(_image_sha256_file "$arch")"
      if [[ "$expect" == "$got" ]]; then
        printf 'OK %s\n' "$got"
        return 0
      fi
      i18n_err image.sha256_mismatch_expect_got expect="$expect" got="$got"
      return 1
      ;;
    import)
      local name="" force=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --force) force=1; shift ;;
          -h|--help) cmd_image --help; return 0 ;;
          -*) i18n_die 2 image.image_import_unknown_option arg="$1" ;;
          *) name="$1"; shift ;;
        esac
      done
      _image_valid_name "$name" || i18n_die 2 image.invalid_image_name
      cmd_image verify "$name" >/dev/null || return 1
      local arch parent target
      if [[ -f "$(_image_dir)/${name}.tar.zst" ]]; then arch="$(_image_dir)/${name}.tar.zst"
      else arch="$(_image_dir)/${name}.tar.gz"; fi
      parent="$(dirname "$CAPBOX_ROOTFS")"
      target="$parent/${CAPBOX_DISTRO}.imported-${name}"
      if [[ -L "$parent" || -L "$target" || -L "$target.extract" ]]; then
        i18n_die 1 image.import_target_path_symlink
      fi
      rm -rf --one-file-system -- "$target" "$target.extract"
      mkdir -p -- "$target.extract" || i18n_die 1 image.unable_create_extract_directory
      [[ -d "$target.extract" && ! -L "$target.extract" ]] || i18n_die 1 image.extract_directory_not_real_directory
      _image_extract_archive "$arch" "$target.extract" || i18n_die 1 image.failed_extract_import_archive
      local extracted="$target.extract/$(basename "$CAPBOX_ROOTFS")"
      if [[ ! -d "$extracted" || -L "$extracted" ]]; then
        extracted="$(find "$target.extract" -mindepth 1 -maxdepth 1 -type d -print -quit)"
      fi
      [[ -n "$extracted" ]] || i18n_die 1 image.import_archive_has_no_root_directory
      _image_realpath_inside "$extracted" "$target.extract" >/dev/null || i18n_die 1 image.import_root_directory_escaped_extract_directory
      [[ ! -e "$target" && ! -L "$target" ]] || i18n_die 1 image.import_target_already_exists
      mv -- "$extracted" "$target" || i18n_die 1 image.unable_place_import_directory
      [[ -d "$target" && ! -L "$target" ]] || i18n_die 1 image.import_result_not_real_directory
      rm -rf --one-file-system -- "$target.extract"
      i18n_info image.imported_sidecar_path_current_rootfs_not_replaced target="$target"
      if (( force == 1 )); then
        local bak="$parent/${CAPBOX_DISTRO}.pre-import-$$"
        [[ -d "$CAPBOX_ROOTFS" && ! -L "$CAPBOX_ROOTFS" ]] || i18n_die 1 image.current_rootfs_not_real_directory_refusing_force
        [[ ! -e "$bak" && ! -L "$bak" ]] || i18n_die 1 image.backup_path_already_exists bak="$bak"
        mv -- "$CAPBOX_ROOTFS" "$bak" || i18n_die 1 image.unable_move_current_rootfs_aside
        if mv -- "$target" "$CAPBOX_ROOTFS" && [[ -d "$CAPBOX_ROOTFS" && ! -L "$CAPBOX_ROOTFS" ]]; then
          i18n_info image.replaced_current_rootfs_force_old_tree bak="$bak"
        else
          rm -rf --one-file-system -- "$CAPBOX_ROOTFS"
          mv -- "$bak" "$CAPBOX_ROOTFS" || true
          i18n_die 1 image.replace_failed
        fi
      else
        i18n_info image.replace_current_rootfs_capbox_image_import_force name="$name"
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
          [[ $# -le 2 ]] || i18n_die 2 image.image_lock_too_many_arguments
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
        *) i18n_die 2 image.image_lock_save_show_verify_restore ;;
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
          i18n_info image.offline_cache out="$out" sum="$sum"
          printf '%s\n' "$out"
          ;;
        restore)
          local arch="${1:-}"
          [[ -n "$arch" && -f "$arch" ]] || i18n_die 2 image.usage_image_cache_restore_archive
          require_rootfs
          if [[ -f "${arch}.sha256" ]]; then
            local expect got
            expect="$(head -c 64 "${arch}.sha256" | tr -d '\n')"
            got="$(_image_sha256_file "$arch")"
            [[ "$expect" == "$got" ]] || i18n_die 1 image.cache_verification_failed
          fi
          local rel stage
          if [[ "${CAPBOX_DISTRO}" == "alpine" ]]; then
            rel="var/cache/apk"
          else
            rel="var/cache/apt"
          fi
          stage="$(mktemp -d "${CAPBOX_STATE_DIR:-${TMPDIR:-/tmp}}/cache-restore.XXXXXX")" || i18n_die 1 image.unable_create_cache_staging_directory
          if ! _image_extract_archive "$arch" "$stage"; then
            rm -rf --one-file-system -- "$stage"
            i18n_die 1 image.failed_extract_cache_archive
          fi
          if [[ ! -d "$stage/$rel" || -L "$stage/$rel" ]]; then
            rm -rf --one-file-system -- "$stage"
            i18n_die 1 image.cache_archive_does_not_contain rel="$rel"
          fi
          if ! _image_install_tree "$stage/$rel" "$rel"; then
            rm -rf --one-file-system -- "$stage"
            i18n_die 1 image.refusing_write_cache_rootfs
          fi
          rm -rf --one-file-system -- "$stage"
          i18n_info image.restored_offline_package_cache_rootfs
          ;;
        *) i18n_die 2 image.image_cache_save_restore_path ;;
      esac
      return 0
      ;;
    *) i18n_die 2 image.image_unknown_subcommand sub="$sub" ;;
  esac
}

_image_doctor_report() {
  local d
  d="$(_image_dir)"
  if [[ -d "$d" ]]; then
    local n
    n="$(ls "$d"/*.tar.* 2>/dev/null | grep -vc sha256 || true)"
    _doctor_pass_i18n doctor.image_dir_present path="$d" n="${n:-0}"
  else
    _doctor_pass_i18n doctor.image_dir_missing
  fi
  if [[ -f "$(_image_lock_path)" ]]; then
    _doctor_pass_i18n doctor.package_lock_present
  fi
}
