# shellcheck shell=bash
# 宿主凭据库 + guest 占位符准备（restricted 代理注入用）。
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
      i18n_print help.secret
      ;;
    *)
      i18n_err cred.unknown_secret_subcommand arg="${1:-}"
      return 2
      ;;
  esac
}

# 为 restricted 启动准备 inject map / guest env；未使用时为空操作。
_credentials_prepare_restricted() {
  local allow="${CAPBOX_NET_ALLOW:-}" out rc=0
  unset CAPBOX_CRED_INJECT_MAP CAPBOX_CRED_GUEST_ENV_FILE CAPBOX_CRED_CA_CERT || true
  [[ -n "$allow" ]] || return 0
  # 库为空则跳过 prepare — 仍成功，active=false。
  out="$(_credentials_command prepare --allow "$allow" --session "${CAPBOX_NET_SESSION:-oneshot}")" || rc=$?
  if (( rc != 0 )); then
    i18n_err cred.failed_prepare_credentials_session
    return "$rc"
  fi
  # 解析小 JSON，不依赖 jq。
  local active inject envf cacert
  active="$(CAPBOX_CRED_JSON="$out" python3 -c 'import json,os; d=json.loads(os.environ["CAPBOX_CRED_JSON"]); print("1" if d.get("active") else "0")')" || return 1
  if [[ "$active" != "1" ]]; then
    hint="$(CAPBOX_CRED_JSON="$out" python3 -c 'import json,os; print(json.loads(os.environ["CAPBOX_CRED_JSON"]).get("hint") or "")' 2>/dev/null || true)"
    if [[ -n "$hint" ]]; then
      log_warn "$hint"
    fi
    return 0
  fi
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
      # 仅占位符 — 此文件绝不能含真实密钥。
      _cred_arr+=(--setenv "$name" "$value")
    done <"$envf"
  fi
  if [[ -n "${CAPBOX_CRED_CA_CERT:-}" && -f "${CAPBOX_CRED_CA_CERT}" ]]; then
    local bundle private
    private="$(_capbox_host_state_dir)" || return 1
    bundle="$private/credentials/sessions/${CAPBOX_NET_SESSION:-oneshot}/ca-bundle.pem"
    mkdir -p "$(dirname -- "$bundle")"
    # 拼接系统信任根与 CapBox CA，供 guest SSL_CERT_FILE 使用。
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
