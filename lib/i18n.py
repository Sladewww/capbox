"""Shared CapBox message catalog reader. Bash and Python use the same files."""
from __future__ import annotations

import re
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
