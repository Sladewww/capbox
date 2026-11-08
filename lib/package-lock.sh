# shellcheck shell=bash
# Fixed versions are installed through the normal package wrapper and then verified.
_package_lock_tool() {
  local action="$1" file="$2" distro="${3:-$CAPBOX_DISTRO}"
  if (( $# >= 3 )); then shift 3; else shift 2; fi
  python3 "${BASH_SOURCE[0]%/*}/package-lock.py" "$action" \
    --distro "$distro" --architecture "$(uname -m)" "$file" "$@"
}

_package_lock_validate() {
  need_cmd python3
  local requested="${3:-}" p
  local -a packages=() args=()
  requested="${requested//,/ }"
  read -r -a packages <<<"$requested"
  for p in "${packages[@]}"; do args+=(--require "$p"); done
  _package_lock_tool validate "$1" "${2:-$CAPBOX_DISTRO}" "${args[@]}"
}

_package_lock_inventory() {
  if [[ "$CAPBOX_DISTRO" == alpine ]]; then
    exec_in_guest 'apk info -v' /workspace 120
  else
    exec_in_guest "dpkg-query -W -f='\${db:Status-Abbrev}\\t\${binary:Package}\\t\${Version}\\n'" /workspace 120
  fi
}

_package_lock_save() {
  require_rootfs
  need_cmd python3
  local file="$(_image_lock_path)" private input staged rc=0
  private="$(_capbox_host_state_dir)" || return 1
  input="$(mktemp "$private/packages.XXXXXX")" || return 1
  staged="$(mktemp "$private/package-lock.XXXXXX")" || { rm -f "$input"; return 1; }
  _package_lock_inventory >"$input" || rc=$?
  if (( rc == 0 )); then
    _package_lock_tool save "$file" <"$input" >"$staged" || rc=$?
  fi
  if (( rc == 0 )); then
    [[ ! -L "$CAPBOX_STATE_DIR" && ! -L "$file" ]] || rc=1
    if (( rc == 0 )); then
      mkdir -p -- "$CAPBOX_STATE_DIR" && cat -- "$staged" >"$file" || rc=1
    fi
  fi
  rm -f -- "$input" "$staged"
  (( rc == 0 )) || { log_err '包锁未保存'; return "$rc"; }
  printf '%s\n' "$file"
}

_package_lock_verify() {
  local file="$1" private input rc=0
  _package_lock_validate "$file" || return $?
  require_rootfs
  private="$(_capbox_host_state_dir)" || return 1
  input="$(mktemp "$private/packages-verify.XXXXXX")" || return 1
  _package_lock_inventory >"$input" || rc=$?
  if (( rc == 0 )); then
    _package_lock_tool verify "$file" <"$input" || rc=$?
  fi
  rm -f -- "$input"
  return "$rc"
}

_package_lock_restore() {
  local file="$1" private argv rc=0 p
  _package_lock_validate "$file" || return $?
  require_rootfs
  private="$(_capbox_host_state_dir)" || return 1
  argv="$(mktemp "$private/package-argv.XXXXXX")" || return 1
  _package_lock_tool arguments "$file" >"$argv" || { rm -f "$argv"; return 2; }
  local -a packages=()
  while IFS= read -r -d '' p; do packages+=("$p"); done <"$argv"
  rm -f -- "$argv"
  cmd_pkg install -- "${packages[@]}" || rc=$?
  (( rc == 0 )) || return "$rc"
  _package_lock_verify "$file"
}
