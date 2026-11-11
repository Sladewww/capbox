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

# Docker / OCI 镜像是数据：只展开层，不执行 Entrypoint、Cmd、Env。
_oci_py() {
  if [[ -n "${CAPBOX_LIB_DIR:-}" && -f "${CAPBOX_LIB_DIR}/oci-image.py" ]]; then
    printf '%s/oci-image.py' "$CAPBOX_LIB_DIR"
    return 0
  fi
  printf '%s/oci-image.py' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
}

_image_docker_dir() { printf '%s/docker' "$(_image_dir)"; }
_image_docker_home() { printf '%s/%s' "$(_image_docker_dir)" "$1"; }
_image_docker_meta() { printf '%s/%s/meta.json' "$(_image_docker_dir)" "$1"; }
_image_docker_rootfs() { printf '%s/%s/rootfs' "$(_image_docker_dir)" "$1"; }

_oci_py_cmd() {
  python3 "$(_oci_py)" --lang "${CAPBOX_UI_LANG:-en}" "$@"
}

# 把已导入的 docker rootfs 接到本次启动。不改 DISTRO，不写 config.env。
_image_docker_use_rootfs() {
  local name="${1:-}" root base real
  _image_valid_name "$name" || i18n_die 2 image.invalid_image_name
  root="$(_image_docker_rootfs "$name")"
  [[ -d "$root" && ! -L "$root" && -f "$(_image_docker_meta "$name")" && ! -L "$(_image_docker_meta "$name")" ]] \
    || i18n_die 1 oci.missing name="$name"
  base="$(realpath -- "$(_image_docker_dir)")" || i18n_die 1 oci.missing name="$name"
  real="$(realpath -- "$root")" || i18n_die 1 oci.busy_symlink path="$root"
  [[ "$real" == "$base"/* ]] || i18n_die 1 oci.busy_symlink path="$root"
  CAPBOX_ROOTFS="$real"
  export CAPBOX_ROOTFS
}

# 镜像 Env 只变成 bwrap --setenv。文件必须在 images/docker 下面，且不是符号链接。
_oci_append_image_env() {
  local -n _arr="$1"
  local file="${2:-}" real base key value pairs rc=0
  [[ -n "$file" && -f "$file" && ! -L "$file" ]] || {
    i18n_err oci.env_file_unusable
    return 1
  }
  base="$(realpath -- "$(_image_docker_dir)" 2>/dev/null)" || {
    i18n_err oci.env_file_outside
    return 1
  }
  real="$(realpath -- "$file" 2>/dev/null)" || {
    i18n_err oci.env_file_outside
    return 1
  }
  [[ "$real" == "$base"/* ]] || {
    i18n_err oci.env_file_outside
    return 1
  }
  pairs="$(mktemp "${TMPDIR:-/tmp}/capbox-oci-env.XXXXXX")" || return 1
  _oci_py_cmd env-pairs --meta "$file" >"$pairs" || rc=$?
  if (( rc != 0 )); then
    rm -f -- "$pairs"
    return "$rc"
  fi
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
      rm -f -- "$pairs"
      i18n_err oci.env_key key="$key"
      return 1
    }
    _arr+=(--setenv "$key" "$value")
  done <"$pairs"
  rm -f -- "$pairs"
}

_image_docker_suggest_name() {
  python3 -c 'import json,sys,re
m=json.loads(sys.stdin.read())
tags=m.get("repo_tags") or []
raw=tags[0] if tags else ""
raw=re.sub(r"[^A-Za-z0-9._@+-]+","_", raw).strip("._")
digest=(m.get("source_sha256") or "").split(":")[-1]
fallback="img-"+(digest[:12] or "noname")
print(raw if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._@+-]*", raw or "") else fallback)'
}

_image_docker_import() {
  local src="" name="" platform="" index="" tag="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        name="${2:-}"
        shift 2 || i18n_die 2 oci.import_needs_archive
        ;;
      --platform)
        platform="${2:-}"
        shift 2 || i18n_die 2 oci.import_needs_archive
        ;;
      --index)
        index="${2:-}"
        shift 2 || i18n_die 2 oci.import_needs_archive
        ;;
      --tag)
        tag="${2:-}"
        shift 2 || i18n_die 2 oci.import_needs_archive
        ;;
      --force) force=1; shift ;;
      -*) i18n_die 2 oci.unknown_option arg="$1" ;;
      *)
        [[ -z "$src" ]] || i18n_die 2 oci.import_needs_archive
        src="$1"
        shift
        ;;
    esac
  done
  [[ -n "$src" && -e "$src" && ! -L "$src" ]] || i18n_die 1 oci.not_an_image path="${src:-<empty>}"
  local -a inspect=(inspect --input "$src")
  [[ -n "$platform" ]] && inspect+=(--platform "$platform")
  [[ -n "$index" ]] && inspect+=(--index "$index")
  [[ -n "$tag" ]] && inspect+=(--tag "$tag")
  local preview
  preview="$(_oci_py_cmd "${inspect[@]}")" || return $?
  if [[ -z "$name" ]]; then
    name="$(printf '%s' "$preview" | _image_docker_suggest_name)" || return 1
  fi
  _image_valid_name "$name" || i18n_die 2 image.invalid_image_name
  local base dest stage
  base="$(_image_docker_dir)"
  mkdir -p -- "$base" || i18n_die 1 oci.stage_failed
  dest="$base/$name"
  [[ ! -L "$dest" && ! -L "$base" ]] || i18n_die 1 oci.busy_symlink path="$dest"
  if [[ -e "$dest" && "$force" -ne 1 ]]; then
    i18n_die 1 oci.exists name="$name"
  fi
  stage="$(mktemp -d "$base/.stage.XXXXXX")" || i18n_die 1 oci.stage_failed
  mkdir -p -- "$stage/rootfs" || {
    rm -rf --one-file-system -- "$stage"
    i18n_die 1 oci.stage_failed
  }
  local -a mat=(materialize --input "$src" --dest "$stage/rootfs")
  [[ -n "$platform" ]] && mat+=(--platform "$platform")
  [[ -n "$index" ]] && mat+=(--index "$index")
  [[ -n "$tag" ]] && mat+=(--tag "$tag")
  local json rc=0
  json="$(_oci_py_cmd "${mat[@]}")" || rc=$?
  if (( rc != 0 )); then
    rm -rf --one-file-system -- "$stage"
    return "$rc"
  fi
  printf '%s\n' "$json" >"$stage/meta.json" || {
    rm -rf --one-file-system -- "$stage"
    i18n_die 1 oci.stage_failed
  }
  if [[ -e "$dest" ]]; then
    local bak="$base/.bak.$name.$$"
    mv -- "$dest" "$bak" || {
      rm -rf --one-file-system -- "$stage"
      i18n_die 1 oci.stage_failed
    }
    if ! mv -- "$stage" "$dest"; then
      mv -- "$bak" "$dest" || true
      rm -rf --one-file-system -- "$stage"
      i18n_die 1 oci.stage_failed
    fi
    rm -rf --one-file-system -- "$bak"
  elif ! mv -- "$stage" "$dest"; then
    rm -rf --one-file-system -- "$stage"
    i18n_die 1 oci.stage_failed
  fi
  [[ -d "$dest/rootfs" && ! -L "$dest/rootfs" && -f "$dest/meta.json" && ! -L "$dest/meta.json" ]] \
    || i18n_die 1 oci.stage_failed
  if declare -F audit_event >/dev/null 2>&1; then
    audit_event image ok "object=$name" "detail=docker-import" "exit=0" "ms=0"
  fi
  i18n_info oci.import_ok name="$name" path="$dest/rootfs"
  printf '%s\n' "$dest/rootfs"
}

_image_docker_run() {
  local target="" name="" platform="" index="" tag="" cwd="" user="" timeout_s="" net_override="" profile="" entrypoint=""
  local clear=0
  local -a cmd=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 || i18n_die 2 oci.run_needs_target ;;
      --platform) platform="${2:-}"; shift 2 || i18n_die 2 oci.run_needs_target ;;
      --index) index="${2:-}"; shift 2 || i18n_die 2 oci.run_needs_target ;;
      --tag) tag="${2:-}"; shift 2 || i18n_die 2 oci.run_needs_target ;;
      --cwd) cwd="${2:-}"; shift 2 || i18n_die 2 oci.run_needs_target ;;
      --user) user="${2:-}"; shift 2 || i18n_die 2 oci.run_needs_target ;;
      --timeout) timeout_s="${2:-}"; shift 2 || i18n_die 2 oci.run_needs_target ;;
      --net) net_override="${2:-}"; shift 2 || i18n_die 2 sandbox.exec_net_requires_mode_none_restricted_open ;;
      --profile) profile="${2:-}"; shift 2 || i18n_die 2 oci.run_needs_target ;;
      --entrypoint) entrypoint="${2:-}"; shift 2 || i18n_die 2 oci.run_needs_target ;;
      --clear-entrypoint) clear=1; shift ;;
      --) shift; cmd+=("$@"); break ;;
      -*) i18n_die 2 oci.unknown_option arg="$1" ;;
      *)
        if [[ -z "$target" ]]; then
          target="$1"
          shift
        else
          cmd+=("$@")
          break
        fi
        ;;
    esac
  done
  [[ -n "$target" ]] || i18n_die 2 oci.run_needs_target
  local use_name="$name" imported=""
  if [[ -e "$target" && ! -L "$target" && ( -f "$target" || -d "$target" ) ]]; then
    local -a imp=("$target" --force)
    [[ -n "$name" ]] && imp+=(--name "$name")
    [[ -n "$platform" ]] && imp+=(--platform "$platform")
    [[ -n "$index" ]] && imp+=(--index "$index")
    [[ -n "$tag" ]] && imp+=(--tag "$tag")
    imported="$(_image_docker_import "${imp[@]}")" || return $?
    use_name="$(basename -- "$(dirname -- "$imported")")"
  else
    use_name="${name:-$target}"
  fi
  _image_docker_use_rootfs "$use_name" || return $?
  if [[ -n "$net_override" ]]; then
    _capbox_declare_net "$net_override" exec || return $?
  fi
  if [[ -n "$profile" ]]; then
    case "$profile" in
      compat | untrusted | strict) CAPBOX_SECURITY_PROFILE="$profile" ;;
      *) i18n_die 2 sandbox.exec_profile_must_compat_untrusted_strict_got profile_override="$profile" ;;
    esac
  fi
  [[ -n "$timeout_s" ]] || timeout_s="${CAPBOX_EXEC_TIMEOUT:-600}"
  [[ "$timeout_s" =~ ^[0-9]+$ ]] || i18n_die 2 sandbox.exec_timeout_must_non_negative_integer_number timeout_s="$timeout_s"
  local plan meta
  meta="$(_image_docker_meta "$use_name")"
  plan="$(mktemp -d "${TMPDIR:-/tmp}/capbox-oci-plan.XXXXXX")" || i18n_die 1 oci.stage_failed
  local -a plan_cmd=(plan --meta "$meta" --rootfs "$CAPBOX_ROOTFS" --out-dir "$plan")
  [[ -n "$cwd" ]] && plan_cmd+=(--cwd "$cwd")
  [[ -n "$user" ]] && plan_cmd+=(--user "$user")
  [[ -n "$entrypoint" ]] && plan_cmd+=(--entrypoint "$entrypoint")
  (( clear == 1 )) && plan_cmd+=(--clear-entrypoint)
  if [[ ${#cmd[@]} -gt 0 ]]; then
    plan_cmd+=(-- "${cmd[@]}")
  fi
  if ! _oci_py_cmd "${plan_cmd[@]}"; then
    rm -rf --one-file-system -- "$plan"
    return 1
  fi
  local pcwd puid pgid
  IFS= read -r pcwd <"$plan/cwd" || pcwd=/
  IFS= read -r puid <"$plan/uid" || puid=0
  IFS= read -r pgid <"$plan/gid" || pgid=0
  [[ "$puid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ ]] || {
    rm -rf --one-file-system -- "$plan"
    i18n_die 1 oci.user_unresolved user="${user:-image}"
  }
  local -a argv=()
  mapfile -d '' argv <"$plan/argv"
  if [[ ${#argv[@]} -gt 0 && -z "${argv[-1]}" ]]; then
    unset 'argv[-1]'
  fi
  if [[ ${#argv[@]} -eq 0 ]]; then
    rm -rf --one-file-system -- "$plan"
    i18n_die 2 oci.no_argv
  fi
  rm -rf --one-file-system -- "$plan"
  export CAPBOX_EXEC_UID_OVERRIDE="$puid"
  export CAPBOX_EXEC_GID_OVERRIDE="$pgid"
  CAPBOX_OCI_ENV_FILE="$meta"
  run_bwrap_oneshot "$pcwd" "$timeout_s" "${argv[@]}"
  local rc=$?
  unset CAPBOX_OCI_ENV_FILE
  return "$rc"
}

_image_json_field() {
  python3 -c 'import json,sys
data=json.load(sys.stdin)
value=data.get(sys.argv[1], "")
if not isinstance(value, str):
    value=""
sys.stdout.write(value)' "$1"
}

# 拉取在宿主上调用 skopeo 或 crane，不连接 docker.sock。
# 标签先解析成 sha256，再按摘要复制到临时 OCI layout，然后走 import。
_image_docker_pull_copy() {
  local tool="$1" reference="$2" digest="$3" layout="$4" oci_tag="$5"
  local osn="$6" arch="$7" variant="$8" platform="$9"
  local -a proxy=()
  if [[ -n "${CAPBOX_PROXY:-}" && -z "${https_proxy:-}" && -z "${HTTPS_PROXY:-}" ]]; then
    proxy=(env "http_proxy=${CAPBOX_PROXY}" "https_proxy=${CAPBOX_PROXY}")
  fi
  local resolved="$digest" src="${reference%%@sha256:*}" out digestfile got note
  note="$(dirname -- "$layout")/got"
  if [[ "$tool" == skopeo ]]; then
    local -a ov=()
    [[ -n "$osn" ]] && ov+=(--override-os "$osn" --override-arch "$arch")
    [[ -n "$variant" ]] && ov+=(--override-variant "$variant")
    if [[ -z "$resolved" ]]; then
      out="$("${proxy[@]}" skopeo inspect --format '{{.Digest}}' "${ov[@]}" "docker://${reference}")" || return 1
      resolved="${out//[$'\r\n']/}"
      if [[ ! "$resolved" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        printf '%s' "$resolved" >"$note"
        return 2
      fi
    fi
    digestfile="$(dirname -- "$layout")/digest"
    "${proxy[@]}" skopeo copy --digestfile "$digestfile" "${ov[@]}" \
      "docker://${src}@${resolved}" "oci:${layout}:${oci_tag}" || return 1
    got="$(tr -d '[:space:]' <"$digestfile" 2>/dev/null || true)"
    if [[ "$got" != "$resolved" ]]; then
      printf '%s' "${got:-$resolved}" >"$note"
      return 2
    fi
    return 0
  fi
  local -a plat=()
  [[ -n "$platform" ]] && plat+=(--platform "$platform")
  if [[ -z "$resolved" ]]; then
    out="$("${proxy[@]}" crane digest "${plat[@]}" "$reference")" || return 1
    resolved="${out//[$'\r\n']/}"
    if [[ ! "$resolved" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      printf '%s' "$resolved" >"$note"
      return 2
    fi
  fi
  "${proxy[@]}" crane pull --format oci "${plat[@]}" "${src}@${resolved}" "$layout" || return 1
  return 0
}

_image_docker_pull() {
  local ref="" name="" platform="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 || i18n_die 2 oci.pull_needs_ref ;;
      --platform) platform="${2:-}"; shift 2 || i18n_die 2 oci.pull_needs_ref ;;
      --force) force=1; shift ;;
      -*) i18n_die 2 oci.unknown_option arg="$1" ;;
      *)
        [[ -z "$ref" ]] || i18n_die 2 oci.pull_needs_ref
        ref="$1"
        shift
        ;;
    esac
  done
  [[ -n "$ref" ]] || i18n_die 2 oci.pull_needs_ref
  local tool=""
  if have_cmd skopeo; then
    tool=skopeo
  elif have_cmd crane; then
    tool=crane
  else
    i18n_die 1 oci.pull_tool_missing
  fi
  local -a norm=(normalize-ref --ref "$ref")
  [[ -n "${CAPBOX_OCI_REGISTRIES+x}" ]] && norm+=(--allow "${CAPBOX_OCI_REGISTRIES}")
  [[ -n "$platform" ]] && norm+=(--platform "$platform")
  local json
  json="$(_oci_py_cmd "${norm[@]}")" || return $?
  local registry reference digest oci_tag default_name osn arch variant
  registry="$(printf '%s' "$json" | _image_json_field registry)"
  reference="$(printf '%s' "$json" | _image_json_field reference)"
  digest="$(printf '%s' "$json" | _image_json_field digest)"
  oci_tag="$(printf '%s' "$json" | _image_json_field oci_tag)"
  default_name="$(printf '%s' "$json" | _image_json_field default_name)"
  osn="$(printf '%s' "$json" | _image_json_field os)"
  arch="$(printf '%s' "$json" | _image_json_field arch)"
  variant="$(printf '%s' "$json" | _image_json_field variant)"
  [[ -n "$reference" && -n "$oci_tag" && -n "$registry" ]] || i18n_die 1 oci.pull_bad_ref ref="$ref"
  [[ -n "$name" ]] || name="$default_name"
  _image_valid_name "$name" || i18n_die 2 image.invalid_image_name
  local base dest
  base="$(_image_docker_dir)"
  mkdir -p -- "$base" || i18n_die 1 oci.stage_failed
  [[ ! -L "$base" ]] || i18n_die 1 oci.busy_symlink path="$base"
  dest="$base/$name"
  [[ ! -L "$dest" ]] || i18n_die 1 oci.busy_symlink path="$dest"
  if [[ -e "$dest" && "$force" -ne 1 ]]; then
    i18n_die 1 oci.exists name="$name"
  fi
  local stage
  stage="$(mktemp -d "$base/.pull.XXXXXX")" || i18n_die 1 oci.stage_failed
  [[ ! -L "$stage" ]] || i18n_die 1 oci.busy_symlink path="$stage"
  (
    local layout="$stage/layout" copy_rc=0 bytes="" got=""
    _image_docker_pull_copy "$tool" "$reference" "$digest" "$layout" "$oci_tag" \
      "$osn" "$arch" "$variant" "$platform" || copy_rc=$?
    if (( copy_rc != 0 )); then
      if (( copy_rc == 2 )); then
        got="$(cat "$stage/got" 2>/dev/null || true)"
        i18n_die 1 oci.pull_digest_mismatch digest="${got:-unknown}"
      fi
      i18n_die 1 oci.pull_failed tool="$tool"
    fi
    [[ -d "$layout" && ! -L "$layout" && -f "$layout/index.json" && ! -L "$layout/index.json" \
      && -f "$layout/oci-layout" && ! -L "$layout/oci-layout" ]] \
      || i18n_die 1 oci.pull_failed tool="$tool"
    bytes="$(du -sb -- "$layout" | awk '{print $1}')"
    [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -le 8589934592 ]] || i18n_die 1 oci.too_large limit='8GiB'
    local -a imp=("$layout" --name "$name")
    [[ -n "$platform" ]] && imp+=(--platform "$platform")
    (( force == 1 )) && imp+=(--force)
    _image_docker_import "${imp[@]}"
  )
  local rc=$?
  rm -rf --one-file-system -- "$stage"
  if (( rc == 0 )) && declare -F audit_event >/dev/null 2>&1; then
    audit_event image ok "object=$name" "detail=docker-pull:$registry" "exit=0" "ms=0"
  fi
  return "$rc"
}

cmd_image_docker() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    "" | -h | --help)
      i18n_print help.image.docker
      return 0
      ;;
    inspect)
      local src="${1:-}"
      shift || true
      [[ -n "$src" ]] || i18n_die 2 oci.import_needs_archive
      local platform="" index="" tag=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --platform) platform="${2:-}"; shift 2 || i18n_die 2 oci.unknown_option arg="$1" ;;
          --index) index="${2:-}"; shift 2 || i18n_die 2 oci.unknown_option arg="$1" ;;
          --tag) tag="${2:-}"; shift 2 || i18n_die 2 oci.unknown_option arg="$1" ;;
          *) i18n_die 2 oci.unknown_option arg="$1" ;;
        esac
      done
      local -a args=(inspect --input "$src")
      [[ -n "$platform" ]] && args+=(--platform "$platform")
      [[ -n "$index" ]] && args+=(--index "$index")
      [[ -n "$tag" ]] && args+=(--tag "$tag")
      _oci_py_cmd "${args[@]}"
      ;;
    import)
      _image_docker_import "$@"
      ;;
    pull)
      _image_docker_pull "$@"
      ;;
    list)
      local d meta name
      d="$(_image_docker_dir)"
      if [[ ! -d "$d" ]]; then
        i18n_print oci.none
        return 0
      fi
      local any=0
      shopt -s nullglob
      for meta in "$d"/*/meta.json; do
        [[ -f "$meta" && ! -L "$meta" ]] || continue
        any=1
        name="$(basename -- "$(dirname -- "$meta")")"
        python3 -c 'import json,sys
m=json.load(open(sys.argv[1], encoding="utf-8"))
tags=",".join(m.get("repo_tags") or []) or "-"
print("%s\t%s/%s\t%s" % (sys.argv[2], m.get("os") or "?", m.get("architecture") or "?", tags))' \
          "$meta" "$name"
      done
      shopt -u nullglob
      (( any == 0 )) && i18n_print oci.none
      return 0
      ;;
    show)
      local name="${1:-}"
      _image_valid_name "$name" || i18n_die 2 image.invalid_image_name
      local meta="$(_image_docker_meta "$name")"
      [[ -f "$meta" && ! -L "$meta" ]] || i18n_die 1 oci.missing name="$name"
      python3 -m json.tool -- "$meta"
      ;;
    rm)
      local name="${1:-}"
      _image_valid_name "$name" || i18n_die 2 image.invalid_image_name
      local dest base real
      dest="$(_image_docker_home "$name")"
      [[ -d "$dest" && ! -L "$dest" ]] || i18n_die 1 oci.missing name="$name"
      base="$(realpath -- "$(_image_docker_dir)")" || i18n_die 1 oci.missing name="$name"
      real="$(realpath -- "$dest")" || i18n_die 1 oci.busy_symlink path="$dest"
      [[ "$real" == "$base"/* ]] || i18n_die 1 oci.busy_symlink path="$dest"
      rm -rf --one-file-system -- "$real"
      i18n_info oci.removed name="$name"
      return 0
      ;;
    run)
      _image_docker_run "$@"
      ;;
    *)
      i18n_die 2 oci.unknown sub="${sub:-}"
      ;;
  esac
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
        printf '%s\n' "$(i18n_get image.no_exported_images)"
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
          [[ -f "$(_image_lock_path)" ]] || { printf '%s\n' "$(i18n_get image.no_package_lock)"; return 0; }
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
    docker)
      cmd_image_docker "$@"
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
  local docker_n=0 meta
  if [[ -d "$(_image_docker_dir)" ]]; then
    shopt -s nullglob
    for meta in "$(_image_docker_dir)"/*/meta.json; do
      [[ -f "$meta" && ! -L "$meta" ]] || continue
      docker_n=$(( docker_n + 1 ))
    done
    shopt -u nullglob
  fi
  _doctor_pass_i18n doctor.docker_images n="$docker_n"
}
