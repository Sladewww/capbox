#!/usr/bin/env python3
"""Language resolution, catalog completeness, and prefix/--help smoke tests."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'lib'))
import i18n  # noqa: E402

CLI = REPO / 'bin/capbox'
I18N_SH = REPO / 'lib/i18n.sh'
ILLEGAL_ZH = 'CAPBOX_LANG 取值无效（仅支持 zh / en 及其区域形式，例如 zh_CN、en_US）。'
ILLEGAL_EN = 'Invalid CAPBOX_LANG (accepted values: zh / en and regional forms such as zh_CN, en_US).'


def base_env():
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('CAPBOX_', '_CAPBOX_')) and k not in
           ('LC_ALL', 'LC_MESSAGES', 'LANG', 'LANGUAGE', 'LC_CTYPE')}
    env['LC_ALL'] = 'C'
    return env


def run_bash(script, env=None):
    merged = base_env()
    if env:
        merged.update(env)
    return subprocess.run(['bash', '-c', script], cwd=str(REPO), env=merged,
                          capture_output=True, text=True, timeout=20)


class CatalogTests(unittest.TestCase):
    def test_both_catalogs_have_the_same_keys_and_no_empty_values(self):
        errors = i18n.check_complete(('en', 'zh'))
        self.assertEqual(errors, [], '\n'.join(errors))

    def test_missing_key_returns_the_key_itself(self):
        catalog = i18n.load_catalog('en')
        self.assertEqual(i18n.get(catalog, 'no.such.key'), 'no.such.key')
        self.assertNotEqual(i18n.get(catalog, 'log.prefix.err'), '')


class ResolveUnitTests(unittest.TestCase):
    def classify(self, capbox_lang=None, lc_all='', lc_messages='', lang='',
                 expect_exit=0):
        assignments = []
        for name, value in (('CAPBOX_LANG', capbox_lang), ('LC_ALL', lc_all),
                            ('LC_MESSAGES', lc_messages), ('LANG', lang)):
            if value is None:
                assignments.append(f'unset {name}')
            else:
                assignments.append(f'{name}={subprocess.list2cmdline([value])}')
        script = ('; '.join(assignments) +
                  f'; source "{I18N_SH}"; '
                  'if [[ -n "${CAPBOX_LANG:-}" ]]; then '
                  '  if parsed="$(_capbox_parse_lang_value "$CAPBOX_LANG")"; then '
                  '    printf "%s" "$parsed"; '
                  '  else '
                  '    _capbox_i18n_illegal_lang; '
                  '  fi; '
                  'else '
                  '  _capbox_locale_to_lang "$(_capbox_locale_raw)"; '
                  'fi')
        result = run_bash(script)
        if expect_exit:
            self.assertEqual(result.returncode, expect_exit, result.stderr)
            return result
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result.stdout

    def test_capbox_lang_aliases(self):
        for value in ('zh', 'zh_CN', 'zh_CN.UTF-8', 'zh_CN.utf8', 'zh.UTF-8', 'ZH', 'zh_cn'):
            self.assertEqual(self.classify(capbox_lang=value), 'zh', value)
        for value in ('en', 'en_US', 'en_US.UTF-8', 'en_GB', 'en.UTF-8', 'EN', 'en_us.utf-8'):
            self.assertEqual(self.classify(capbox_lang=value), 'en', value)

    def test_illegal_capbox_lang(self):
        for value in ('zh_TW', 'zh_HK', 'zh-CN', 'fr', 'english', 'C', 'C.UTF-8'):
            result = self.classify(capbox_lang=value, expect_exit=2)
            self.assertIn(ILLEGAL_ZH, result.stderr)
            self.assertIn(ILLEGAL_EN, result.stderr)

    def test_locale_chinese_only_for_zh_cn_and_plain_zh(self):
        for value in ('zh_CN', 'zh_CN.UTF-8', 'zh_CN.utf8', 'zh', 'zh.UTF-8'):
            self.assertEqual(self.classify(lc_all=value), 'zh', value)

    def test_locale_english_for_everything_else(self):
        for value in ('', 'C', 'C.UTF-8', 'en_US', 'en_US.UTF-8', 'zh_TW',
                      'zh_HK', 'zh_TW.UTF-8', 'zh_HK.UTF-8', 'POSIX', 'fr_FR'):
            self.assertEqual(self.classify(lc_all=value), 'en', repr(value))

    def test_locale_precedence_lc_all_over_lc_messages_over_lang(self):
        self.assertEqual(self.classify(lc_all='C', lc_messages='zh_CN', lang='zh_CN'), 'en')
        self.assertEqual(self.classify(lc_all='', lc_messages='C', lang='zh_CN'), 'en')
        self.assertEqual(self.classify(lc_all='', lc_messages='', lang='zh_CN'), 'zh')
        self.assertEqual(self.classify(lc_all='zh_CN', lc_messages='C', lang='C'), 'zh')


class CliResolveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='capbox-i18n-')
        self.addCleanup(self.tmp.cleanup)
        self.ws = Path(self.tmp.name) / 'ws'
        self.ws.mkdir()

    def run_cli(self, *args, env=None, config=None):
        merged = base_env()
        if env:
            merged.update(env)
        if config is not None:
            cap = self.ws / '.capbox'
            cap.mkdir(parents=True, exist_ok=True)
            (cap / 'config.env').write_text(config)
        return subprocess.run(
            [str(CLI), '--root', str(self.ws), *args],
            env=merged, capture_output=True, text=True, timeout=30)

    def test_capbox_lang_en_help_and_error_prefix(self):
        help_out = self.run_cli('--help', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(help_out.returncode, 0, help_out.stderr)
        self.assertIn('Usage:', help_out.stdout)
        self.assertNotIn('用法:', help_out.stdout)
        err = self.run_cli('definitely-not-a-command', env={'CAPBOX_LANG': 'en'})
        self.assertNotEqual(err.returncode, 0)
        self.assertIn('[capbox] error:', err.stderr)
        self.assertNotIn('[capbox] 错误:', err.stderr)

    def test_capbox_lang_zh_help_and_error_prefix(self):
        help_out = self.run_cli('--help', env={'CAPBOX_LANG': 'zh'})
        self.assertEqual(help_out.returncode, 0, help_out.stderr)
        self.assertIn('用法:', help_out.stdout)
        self.assertNotIn('Usage:', help_out.stdout)
        err = self.run_cli('definitely-not-a-command', env={'CAPBOX_LANG': 'zh'})
        self.assertIn('[capbox] 错误:', err.stderr)
        self.assertNotIn('[capbox] warning:', err.stderr)

    def test_process_env_beats_config_env(self):
        result = self.run_cli('--help', env={'CAPBOX_LANG': 'en'},
                              config="CAPBOX_LANG='zh'\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Usage:', result.stdout)
        self.assertNotIn('用法:', result.stdout)

    def test_config_env_beats_locale_when_env_unset(self):
        result = self.run_cli('--help', env={'LC_ALL': 'C.UTF-8'},
                              config="CAPBOX_LANG='zh'\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('用法:', result.stdout)
        self.assertNotIn('Usage:', result.stdout)

    def test_locale_c_utf8_is_english_when_lang_unset(self):
        result = self.run_cli('--help', env={'LC_ALL': 'C.UTF-8'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Usage:', result.stdout)
        self.assertNotIn('用法:', result.stdout)

    def test_illegal_capbox_lang_exits_with_bilingual_message(self):
        result = self.run_cli('--help', env={'CAPBOX_LANG': 'zh_TW'})
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(ILLEGAL_ZH, result.stderr)
        self.assertIn(ILLEGAL_EN, result.stderr)
        self.assertNotIn('Usage:', result.stdout)
        self.assertNotIn('用法:', result.stdout)

    def test_log_debug_stays_english(self):
        result = self.run_cli('--debug', 'version', env={'CAPBOX_LANG': 'zh'})
        self.assertEqual(result.returncode, 0, result.stderr)
        if 'debug:' in result.stderr:
            self.assertIn('[capbox] debug:', result.stderr)
            self.assertNotIn('调试', result.stderr)


if __name__ == '__main__':
    unittest.main()
