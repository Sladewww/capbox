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
  lock save|show           保存/显示包版本锁（apk policy / dpkg-query）
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
        audit_event image ok "object=$name" "detail=export:$sum"
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
      rm -rf "$target"
      mkdir -p "$target.extract"
      if [[ "$arch" == *.zst ]]; then
        zstd -q -d -c "$arch" | tar --numeric-owner -C "$target.extract" -xf -
      else
        tar --numeric-owner -C "$target.extract" -xzf "$arch"
      fi
      local extracted="$target.extract/$(basename "$CAPBOX_ROOTFS")"
      [[ -d "$extracted" ]] || extracted="$(find "$target.extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
      [[ -d "$extracted" ]] || die 1 "导入归档无根目录"
      mv -- "$extracted" "$target"
      rm -rf "$target.extract"
      log_info "已导入到旁路: $target（未替换当前 rootfs）"
      if (( force == 1 )); then
        local bak="$parent/${CAPBOX_DISTRO}.pre-import-$$"
        mv -- "$CAPBOX_ROOTFS" "$bak"
        if mv -- "$target" "$CAPBOX_ROOTFS"; then
          log_info "已 --force 替换当前 rootfs；旧树在 $bak"
        else
          mv -- "$bak" "$CAPBOX_ROOTFS" || true
          die 1 "替换失败"
        fi
      else
        log_info "如需替换当前 rootfs: capbox image import $name --force"
      fi
      if declare -F audit_event >/dev/null 2>&1; then
        audit_event image ok "object=$name" "detail=import:force=$force"
      fi
      return 0
      ;;
    lock)
      local lsub="${1:-show}"
      case "$lsub" in
        save)
          require_rootfs
          mkdir -p "$(dirname "$(_image_lock_path)")"
          local out
          if [[ "${CAPBOX_DISTRO}" == "alpine" ]]; then
            out="$(exec_in_guest 'apk info -v 2>/dev/null | sort' /workspace 120)" || true
          else
            out="$(exec_in_guest 'dpkg-query -W -f='\''${Package}=${Version}\n'\'' 2>/dev/null | sort' /workspace 120)" || true
          fi
          {
            printf '# CapBox package.lock — %s %s\n' "${CAPBOX_DISTRO}" "$(date -Iseconds 2>/dev/null || date)"
            printf '%s\n' "$out"
          } >"$(_image_lock_path)"
          log_info "已写入 $(_image_lock_path)"
          printf '%s\n' "$(_image_lock_path)"
          ;;
        show|"")
          [[ -f "$(_image_lock_path)" ]] || { printf '(无 package.lock；先 image lock save)\n'; return 0; }
          cat -- "$(_image_lock_path)"
          ;;
        *) die 2 "image lock: save|show" ;;
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
          tar --numeric-owner -C "$CAPBOX_ROOTFS" -xzf "$arch"
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
