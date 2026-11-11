# shellcheck shell=bash
# 共享消息目录：bash 与 Python 读同一份文件。无 gettext。
# 格式：
#   key=单行值
#   key<<
#   多行值
#   >>
# 缺 key 或值为空时输出 key 本身，不回落另一语言，不输出空串。

# 解析完成前按设计默认英文（未设置 / 未匹配均为英文）
CAPBOX_UI_LANG="${CAPBOX_UI_LANG:-en}"
_CAPBOX_LOG_PREFIX_INFO='[capbox]'
_CAPBOX_LOG_PREFIX_WARN='[capbox] warning:'
_CAPBOX_LOG_PREFIX_ERR='[capbox] error:'

declare -gA CAPBOX_I18N_MAP=()

_capbox_i18n_catalog_dir() {
  printf '%s/i18n' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
}

# 去掉首尾空白，丢掉 @modifier，统一小写，仅用于匹配
_capbox_norm_locale_tag() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  s="${s%%@*}"
  printf '%s' "$s" | tr '[:upper:]' '[:lower:]'
}

# 仅 zh、zh.*、zh_CN、zh_CN.*（含 zh.UTF-8）。不用 zh* 前缀。
_capbox_tag_is_zh() {
  local s
  s="$(_capbox_norm_locale_tag "$1")"
  [[ "$s" == "zh" || "$s" == zh.?* || "$s" == "zh_cn" || "$s" == zh_cn.?* ]]
}

# en、en.*、en_*、en_*.*（如 en、en_US、en_US.UTF-8）
_capbox_tag_is_en() {
  local s
  s="$(_capbox_norm_locale_tag "$1")"
  [[ "$s" == "en" || "$s" == en.?* || "$s" == en_?* ]]
}

# 把 CAPBOX_LANG 取值收成 zh|en；非法返回 2
_capbox_parse_lang_value() {
  local raw="${1-}"
  if _capbox_tag_is_zh "$raw"; then
    printf 'zh'
    return 0
  fi
  if _capbox_tag_is_en "$raw"; then
    printf 'en'
    return 0
  fi
  return 2
}

# locale 标签：命中中文规则才是 zh，其余一律 en（含未设置、C、zh_TW、zh_HK）
_capbox_locale_to_lang() {
  if _capbox_tag_is_zh "${1-}"; then
    printf 'zh'
  else
    printf 'en'
  fi
}

# LC_ALL > LC_MESSAGES > LANG；都空则空串
_capbox_locale_raw() {
  if [[ -n "${LC_ALL:-}" ]]; then
    printf '%s' "$LC_ALL"
  elif [[ -n "${LC_MESSAGES:-}" ]]; then
    printf '%s' "$LC_MESSAGES"
  elif [[ -n "${LANG:-}" ]]; then
    printf '%s' "$LANG"
  fi
}

_capbox_i18n_load_file() {
  local file="${1-}"
  local key="" line="" mode="line" buf="" first=0
  local open_re='^([A-Za-z0-9._-]+)<<$'
  local assign_re='^([A-Za-z0-9._-]+)=(.*)$'
  [[ -f "$file" && -r "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$mode" == "multi" ]]; then
      if [[ "$line" == '>>' ]]; then
        CAPBOX_I18N_MAP["$key"]="$buf"
        mode="line"
        key=""
        buf=""
        first=0
      elif [[ "$first" -eq 1 ]]; then
        buf="$line"
        first=0
      else
        buf+=$'\n'"$line"
      fi
      continue
    fi
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ $open_re ]]; then
      key="${BASH_REMATCH[1]}"
      buf=""
      first=1
      mode="multi"
    elif [[ "$line" =~ $assign_re ]]; then
      CAPBOX_I18N_MAP["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    else
      printf 'i18n catalog syntax error: %s: %s\n' "$file" "$line" >&2
      return 1
    fi
  done <"$file"
  if [[ "$mode" == "multi" ]]; then
    printf 'i18n catalog unterminated block: %s: %s\n' "$file" "$key" >&2
    return 1
  fi
  return 0
}

_capbox_i18n_load_catalog() {
  local lang="${1:-en}" dir file
  dir="$(_capbox_i18n_catalog_dir)"
  file="$dir/${lang}.msg"
  CAPBOX_I18N_MAP=()
  _capbox_i18n_load_file "$file" || return 1
}

# 读一条消息。缺 key 或空值时输出 key 本身。
i18n_get() {
  local key="${1-}" val=""
  [[ -n "$key" ]] || return 0
  val="${CAPBOX_I18N_MAP[$key]-}"
  if [[ -z "$val" ]]; then
    printf '%s' "$key"
    return 0
  fi
  printf '%s' "$val"
}

# 把消息写到 stdout，保证末尾有换行（供 --help）
i18n_print() {
  local text
  text="$(i18n_get "$1")"
  if [[ "$text" == *$'\n' ]]; then
    printf '%s' "$text"
  else
    printf '%s\n' "$text"
  fi
}

# 占位符替换：i18n_fmt key name=value ...  替换文案里的 {name}
i18n_fmt() {
  local key="${1-}" text k v
  shift || true
  text="$(i18n_get "$key")"
  local pair
  for pair in "$@"; do
    k="${pair%%=*}"
    v="${pair#*=}"
    text="${text//\{$k\}/$v}"
  done
  printf '%s' "$text"
}

# Convert {name} placeholders into POSIX printf %s, in appearance order.
# For host-assembled guest / child scripts and the Landlock helper messages file.
# Existing % in the catalog value is escaped first so it stays literal.
i18n_printf_fmt() {
  local text
  text="$(i18n_get "$1")"
  text="${text//%/%%}"
  while [[ "$text" =~ \{[A-Za-z0-9_]+\} ]]; do
    text="${text/${BASH_REMATCH[0]}/%s}"
  done
  printf '%s' "$text"
}

_capbox_i18n_apply_prefixes() {
  local v
  v="$(i18n_get log.prefix.info)"
  [[ "$v" != log.prefix.info && -n "$v" ]] && _CAPBOX_LOG_PREFIX_INFO="$v"
  v="$(i18n_get log.prefix.warn)"
  [[ "$v" != log.prefix.warn && -n "$v" ]] && _CAPBOX_LOG_PREFIX_WARN="$v"
  v="$(i18n_get log.prefix.err)"
  [[ "$v" != log.prefix.err && -n "$v" ]] && _CAPBOX_LOG_PREFIX_ERR="$v"
}

_capbox_i18n_illegal_lang() {
  # 固定中英各一句，不依赖这次没解析成功的语言
  printf '%s\n%s\n' \
    'CAPBOX_LANG 取值无效（仅支持 zh / en 及其区域形式，例如 zh_CN、en_US）。' \
    'Invalid CAPBOX_LANG (accepted values: zh / en and regional forms such as zh_CN, en_US).' >&2
  exit 2
}

# 按进程环境或 locale 预解析（合法 CAPBOX_LANG 或 locale）。非法值留到 load_config 之后再报错。
_capbox_resolve_lang_preview() {
  local lang="en" parsed=""
  if [[ -n "${CAPBOX_LANG:-}" ]]; then
    if parsed="$(_capbox_parse_lang_value "$CAPBOX_LANG")"; then
      lang="$parsed"
    fi
  else
    lang="$(_capbox_locale_to_lang "$(_capbox_locale_raw)")"
  fi
  CAPBOX_UI_LANG="$lang"
  export CAPBOX_UI_LANG
  _capbox_i18n_load_catalog "$lang" || true
  _capbox_i18n_apply_prefixes
}

# 在 load_config 之后调用：进程环境 CAPBOX_LANG > config.env > locale
_capbox_resolve_lang() {
  local lang="en" parsed=""
  if [[ -n "${CAPBOX_LANG:-}" ]]; then
    parsed="$(_capbox_parse_lang_value "$CAPBOX_LANG")" || _capbox_i18n_illegal_lang
    lang="$parsed"
  else
    lang="$(_capbox_locale_to_lang "$(_capbox_locale_raw)")"
  fi
  CAPBOX_UI_LANG="$lang"
  export CAPBOX_UI_LANG
  _capbox_i18n_load_catalog "$lang" || {
    printf 'i18n: failed to load catalog for %s\n' "$lang" >&2
    exit 1
  }
  _capbox_i18n_apply_prefixes
}


# 值为空时用目录里的回退词（如 val.unset），供消息占位符使用。
i18n_or() {
  local v="${1-}" key="${2-}"
  if [[ -n "$v" ]]; then
    printf '%s' "$v"
  else
    i18n_get "$key"
  fi
}

# 在 common.sh 定义彩色 log_* / die 之前，提供无颜色的兜底实现。
if ! declare -F log_info >/dev/null 2>&1; then
  log_info() { printf '%s %s\n' "${_CAPBOX_LOG_PREFIX_INFO}" "$*" >&2; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn() { printf '%s %s\n' "${_CAPBOX_LOG_PREFIX_WARN}" "$*" >&2; }
fi
if ! declare -F log_err >/dev/null 2>&1; then
  log_err() { printf '%s %s\n' "${_CAPBOX_LOG_PREFIX_ERR}" "$*" >&2; }
fi

i18n_info() { log_info "$(i18n_fmt "$@")"; }
i18n_warn() { log_warn "$(i18n_fmt "$@")"; }
i18n_err() { log_err "$(i18n_fmt "$@")"; }
i18n_die() {
  local code="${1:-1}"
  shift || true
  if declare -F die >/dev/null 2>&1; then
    die "$code" "$(i18n_fmt "$@")"
  else
    log_err "$(i18n_fmt "$@")"
    exit "$code"
  fi
}

_capbox_resolve_lang_preview
