# shellcheck shell=bash
# Host credential store + guest placeholder preparation for restricted proxy injection.
[[ -f "${BASH_SOURCE[0]%/*}/credentials-runtime.py" ]] || return 5

_credentials_command() {
  need_cmd python3
  local private
  private="$(_capbox_host_state_dir)" || return 1
  env "CAPBOX_CRED_PRIVATE=$private" \
    python3 "${BASH_SOURCE[0]%/*}/credentials-runtime.py" "$@"
}

cmd_secret() {
  case "${1:-}" in
    set|ls|rm|import|prepare) _credentials_command "$@" ;;
    -h|--help|help|"")
      cat <<'HELP'
用法: capbox secret set|ls|rm|import

  secret set <service> [--value-stdin|--command CMD]
  secret set --custom --host HOST [--host HOST...] --env NAME [--name ID] [--value-stdin|--command CMD]
  secret ls
  secret rm <name>
  secret import [service] [--all] [--force] [--dry-run]

真实密钥只保存在宿主私有目录（0700/0600）。guest 仅见 capbox-sec-<32hex> 占位符；
restricted 代理在 NET_ALLOW 授权域名上改写 HTTP(S) 请求头。详见 docs/credentials.md。
HELP
      ;;
    *)
      log_err "未知 secret 子命令: ${1:-}"
      return 2
      ;;
  esac
}

# Prepare inject map / guest env for restricted launches. No-op when unused.
_credentials_prepare_restricted() {
  local allow="${CAPBOX_NET_ALLOW:-}" out rc=0
  unset CAPBOX_CRED_INJECT_MAP CAPBOX_CRED_GUEST_ENV_FILE CAPBOX_CRED_CA_CERT || true
  [[ -n "$allow" ]] || return 0
  # Skip prepare when store empty — prepare still succeeds with active=false.
  out="$(_credentials_command prepare --allow "$allow" --session "${CAPBOX_NET_SESSION:-oneshot}")" || rc=$?
  if (( rc != 0 )); then
    log_err "凭据会话准备失败"
    return "$rc"
  fi
  # Parse tiny JSON without requiring jq.
  local active inject envf cacert
  active="$(CAPBOX_CRED_JSON="$out" python3 -c 'import json,os; d=json.loads(os.environ["CAPBOX_CRED_JSON"]); print("1" if d.get("active") else "0")')" || return 1
  [[ "$active" == "1" ]] || return 0
  inject="$(CAPBOX_CRED_JSON="$out" python3 -c 'import json,os; print(json.loads(os.environ["CAPBOX_CRED_JSON"]).get("inject_map",""))')"
  envf="$(CAPBOX_CRED_JSON="$out" python3 -c 'import json,os; print(json.loads(os.environ["CAPBOX_CRED_JSON"]).get("guest_env_file",""))')"
  cacert="$(CAPBOX_CRED_JSON="$out" python3 -c 'import json,os; print(json.loads(os.environ["CAPBOX_CRED_JSON"]).get("ca_cert") or "")')"
  [[ -n "$inject" && -n "$envf" ]] || return 1
  export CAPBOX_CRED_INJECT_MAP="$inject"
  export CAPBOX_CRED_GUEST_ENV_FILE="$envf"
  if [[ -n "$cacert" ]]; then
    export CAPBOX_CRED_CA_CERT="$cacert"
  fi
  return 0
}

_credentials_append_bwrap_args() {
  local -n _cred_arr="$1"
  local envf="${CAPBOX_CRED_GUEST_ENV_FILE:-}" line name value
  if [[ -n "$envf" && -f "$envf" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" != *=* ]] && continue
      name="${line%%=*}"
      value="${line#*=}"
      [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
      # Placeholders only — never real secrets in this file.
      _cred_arr+=(--setenv "$name" "$value")
    done <"$envf"
  fi
  if [[ -n "${CAPBOX_CRED_CA_CERT:-}" && -f "${CAPBOX_CRED_CA_CERT}" ]]; then
    local bundle private
    private="$(_capbox_host_state_dir)" || return 1
    bundle="$private/credentials/sessions/${CAPBOX_NET_SESSION:-oneshot}/ca-bundle.pem"
    mkdir -p "$(dirname -- "$bundle")"
    # Concatenate system trust + CapBox CA for guest SSL_CERT_FILE.
    : >"$bundle"
    chmod 600 "$bundle"
    for candidate in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem /etc/pki/tls/certs/ca-bundle.crt; do
      if [[ -f "$candidate" ]]; then
        cat "$candidate" >>"$bundle"
        break
      fi
    done
    cat "${CAPBOX_CRED_CA_CERT}" >>"$bundle"
    _cred_arr+=(--ro-bind "$bundle" /etc/capbox/ca-bundle.pem)
    _cred_arr+=(--setenv SSL_CERT_FILE /etc/capbox/ca-bundle.pem)
    _cred_arr+=(--setenv REQUESTS_CA_BUNDLE /etc/capbox/ca-bundle.pem)
    _cred_arr+=(--setenv CURL_CA_BUNDLE /etc/capbox/ca-bundle.pem)
    _cred_arr+=(--setenv SSL_CERT_DIR /etc/capbox)
  fi
}
