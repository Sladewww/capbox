"""Shared CapBox message catalog reader. Bash and Python use the same files."""
from __future__ import annotations

import argparse
import os
import re
import sys
from contextlib import contextmanager
from pathlib import Path

CATALOG_DIR = Path(__file__).resolve().parent / 'i18n'
_KEY_LINE = re.compile(r'^([A-Za-z0-9._-]+)=(.*)$')
_KEY_OPEN = re.compile(r'^([A-Za-z0-9._-]+)<<$')


def catalog_path(lang: str) -> Path:
    return CATALOG_DIR / f'{lang}.msg'


def load_catalog(lang: str) -> dict[str, str]:
    path = catalog_path(lang)
    text = path.read_text(encoding='utf-8')
    result: dict[str, str] = {}
    key = None
    buf: list[str] = []
    for line in text.splitlines():
        if key is not None:
            if line == '>>':
                result[key] = '\n'.join(buf)
                key = None
                buf = []
            else:
                buf.append(line)
            continue
        if not line or line.startswith('#'):
            continue
        opened = _KEY_OPEN.match(line)
        if opened:
            key = opened.group(1)
            buf = []
            continue
        assigned = _KEY_LINE.match(line)
        if assigned:
            result[assigned.group(1)] = assigned.group(2)
            continue
        raise ValueError(f'i18n catalog syntax error: {path}: {line}')
    if key is not None:
        raise ValueError(f'i18n catalog unterminated block: {path}: {key}')
    return result


def get(catalog: dict[str, str], key: str) -> str:
    value = catalog.get(key, '')
    if value == '':
        return key
    return value


def catalog_languages() -> list[str]:
    return sorted(path.stem for path in CATALOG_DIR.glob('*.msg'))


def check_complete(languages: tuple[str, ...] = ('en', 'zh')) -> list[str]:
    """Lock both catalogs: same key set, no empty values."""
    errors: list[str] = []
    loaded = {}
    for lang in languages:
        path = catalog_path(lang)
        if not path.is_file():
            errors.append(f'missing catalog: {path}')
            continue
        loaded[lang] = load_catalog(lang)
    if len(loaded) != len(languages):
        return errors
    keysets = {lang: set(catalog) for lang, catalog in loaded.items()}
    all_keys = set().union(*keysets.values())
    for lang, keys in keysets.items():
        missing = sorted(all_keys - keys)
        if missing:
            errors.append(f'{lang}: missing keys: {", ".join(missing)}')
        empty = sorted(key for key, value in loaded[lang].items() if value == '')
        if empty:
            errors.append(f'{lang}: empty values: {", ".join(empty)}')
    return errors


ILLEGAL_ZH = 'CAPBOX_LANG 取值无效（仅支持 zh / en 及其区域形式，例如 zh_CN、en_US）。'
ILLEGAL_EN = 'Invalid CAPBOX_LANG (accepted values: zh / en and regional forms such as zh_CN, en_US).'
_PLACEHOLDER = re.compile(r'\{([A-Za-z0-9_]+)\}')
_catalog_cache: dict[str, dict[str, str]] = {}

# argparse gettext templates → catalog keys (values keep argparse % placeholders)
ARGPARSE_MESSAGES = {
    'usage: ': 'argparse.usage',
    'positional arguments': 'argparse.positional',
    'options': 'argparse.options',
    'optional arguments': 'argparse.options',
    'subcommands': 'argparse.subcommands',
    'show this help message and exit': 'argparse.show_help',
    "show program's version number and exit": 'argparse.show_version',
    'unrecognized arguments: %s': 'argparse.unrecognized',
    'the following arguments are required: %s': 'argparse.required',
    'expected one argument': 'argparse.expected_one',
    'expected at most one argument': 'argparse.expected_at_most_one',
    'expected at least one argument': 'argparse.expected_at_least_one',
    'invalid choice: %(value)r (choose from %(choices)s)': 'argparse.invalid_choice',
    'invalid %(type)s value: %(value)r': 'argparse.invalid_type',
    'not allowed with argument %s': 'argparse.not_allowed_with',
    'one of the arguments %s is required': 'argparse.one_required',
    'argument %(argument_name)s: %(message)s': 'argparse.argument_message',
    '%(prog)s: error: %(message)s\n': 'argparse.error',
    '%(prog)s: warning: %(message)s\n': 'argparse.warning',
    'ambiguous option: %(option)s could match %(matches)s': 'argparse.ambiguous',
    'ignored explicit argument %r': 'argparse.ignored_argument',
    'cannot have multiple subparser arguments': 'argparse.multiple_subparsers',
}


def fmt(catalog: dict[str, str], _key: str, **kwargs: object) -> str:
    """Replace {name} placeholders; unknown placeholders stay literal.

    形参刻意不用 `key` —— 模板占位符里就有 {key}，用同名形参会与
    `**{'key': ...}` 冲突（TypeError: got multiple values for argument 'key'）。
    """
    text = get(catalog, _key)
    if not kwargs:
        return text

    def repl(match: re.Match[str]) -> str:
        name = match.group(1)
        if name in kwargs:
            return str(kwargs[name])
        return match.group(0)

    return _PLACEHOLDER.sub(repl, text)


def norm_locale_tag(value: str) -> str:
    text = (value or '').strip()
    text = text.split('@', 1)[0]
    return text.lower()


def tag_is_zh(value: str) -> bool:
    text = norm_locale_tag(value)
    return text == 'zh' or text.startswith('zh.') or text == 'zh_cn' or text.startswith('zh_cn.')


def tag_is_en(value: str) -> bool:
    text = norm_locale_tag(value)
    return text == 'en' or text.startswith('en.') or text.startswith('en_')


def parse_lang_value(value: str) -> str | None:
    """Return zh|en, or None if the CAPBOX_LANG value is illegal."""
    if tag_is_zh(value):
        return 'zh'
    if tag_is_en(value):
        return 'en'
    return None


def locale_raw(environ: dict[str, str] | None = None) -> str:
    env = os.environ if environ is None else environ
    for key in ('LC_ALL', 'LC_MESSAGES', 'LANG'):
        value = env.get(key, '')
        if value:
            return value
    return ''


def report_illegal_lang() -> None:
    print(ILLEGAL_ZH, file=sys.stderr)
    print(ILLEGAL_EN, file=sys.stderr)
    raise SystemExit(2)


def resolve_lang(environ: dict[str, str] | None = None, *, on_illegal: str = 'exit') -> str:
    """Process env CAPBOX_LANG, else CAPBOX_UI_LANG already resolved by bash, else locale.

    Illegal CAPBOX_LANG: exit 2 with the fixed bilingual sentences (on_illegal='exit'),
    raise ValueError ('raise'), or treat as English like bash preview ('preview').
    """
    env = os.environ if environ is None else environ
    raw = env.get('CAPBOX_LANG', '')
    if raw:
        parsed = parse_lang_value(raw)
        if parsed is None:
            if on_illegal == 'exit':
                report_illegal_lang()
            if on_illegal == 'raise':
                raise ValueError('illegal CAPBOX_LANG')
            return 'en'
        return parsed
    ui = env.get('CAPBOX_UI_LANG', '')
    if ui in ('zh', 'en'):
        return ui
    return 'zh' if tag_is_zh(locale_raw(env)) else 'en'


def catalog_for(lang: str) -> dict[str, str]:
    cached = _catalog_cache.get(lang)
    if cached is None:
        cached = load_catalog(lang)
        _catalog_cache[lang] = cached
    return cached


def t(_key: str, **kwargs: object) -> str:
    """Look up a catalog key in the current process language.

    形参不用 `key`：模板占位符 {key} 需要能通过 kwargs 传入。
    """
    return fmt(catalog_for(resolve_lang()), _key, **kwargs)


def argparse_gettext(message: str) -> str:
    key = ARGPARSE_MESSAGES.get(message)
    if key is None:
        return message
    return t(key)


@contextmanager
def argparse_i18n_locale():
    original = argparse._
    argparse._ = argparse_gettext
    try:
        yield
    finally:
        argparse._ = original


class I18nArgumentParser(argparse.ArgumentParser):
    """ArgumentParser whose --help and parse errors follow CAPBOX_LANG."""

    def __init__(self, *args, **kwargs):
        with argparse_i18n_locale():
            super().__init__(*args, **kwargs)

    def add_subparsers(self, **kwargs):
        kwargs.setdefault('parser_class', I18nArgumentParser)
        with argparse_i18n_locale():
            return super().add_subparsers(**kwargs)

    def parse_known_args(self, args=None, namespace=None):
        with argparse_i18n_locale():
            return super().parse_known_args(args, namespace)

    def format_help(self):
        with argparse_i18n_locale():
            return super().format_help()

    def format_usage(self):
        with argparse_i18n_locale():
            return super().format_usage()

    def error(self, message):
        # parse 之后调用 ap.error() 时，也走同一套 argparse 文案。
        with argparse_i18n_locale():
            return super().error(message)
