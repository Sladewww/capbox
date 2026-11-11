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

    def test_unknown_command_body_locked_in_zh_and_en(self):
        zh = self.run_cli('definitely-not-a-command', env={'CAPBOX_LANG': 'zh'})
        self.assertIn('未知命令: definitely-not-a-command', zh.stderr)
        self.assertNotIn('Unknown command:', zh.stderr)
        en = self.run_cli('definitely-not-a-command', env={'CAPBOX_LANG': 'en'})
        self.assertIn('Unknown command: definitely-not-a-command', en.stderr)
        self.assertNotIn('未知命令:', en.stderr)

    def test_config_usage_error_locked_in_zh_and_en(self):
        zh = self.run_cli('config', 'get', env={'CAPBOX_LANG': 'zh'})
        self.assertEqual(zh.returncode, 2, zh.stderr)
        self.assertIn('用法: capbox config get KEY', zh.stderr)
        self.assertNotIn('Usage: capbox config get KEY', zh.stderr)
        en = self.run_cli('config', 'get', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(en.returncode, 2, en.stderr)
        self.assertIn('Usage: capbox config get KEY', en.stderr)
        self.assertNotIn('用法: capbox config get KEY', en.stderr)

    def test_pre_catalog_root_missing_arg_locked_in_zh_and_en(self):
        def run(lang):
            merged = base_env()
            merged['CAPBOX_LANG'] = lang
            return subprocess.run([str(CLI), '--root'], env=merged,
                                  capture_output=True, text=True, timeout=20)
        zh = run('zh')
        self.assertEqual(zh.returncode, 2, zh.stderr)
        self.assertIn('--root 需要参数（工作区路径）', zh.stderr)
        self.assertIn('[capbox] 错误:', zh.stderr)
        self.assertNotIn('--root requires an argument', zh.stderr)
        en = run('en')
        self.assertEqual(en.returncode, 2, en.stderr)
        self.assertIn('--root requires an argument (workspace path)', en.stderr)
        self.assertIn('[capbox] error:', en.stderr)
        self.assertNotIn('--root 需要参数', en.stderr)

    def test_pre_catalog_upgrade_incomplete_locked_in_zh_and_en(self):
        cap = self.ws / '.capbox'
        cap.mkdir(parents=True, exist_ok=True)
        (cap / '.upgrade-in-progress').touch()
        zh = self.run_cli('status', env={'CAPBOX_LANG': 'zh'})
        self.assertNotEqual(zh.returncode, 0)
        self.assertIn('运行文件升级未完成；请用完整模板运行 upgrade rollback', zh.stderr)
        self.assertNotIn('A runtime file upgrade did not finish', zh.stderr)
        en = self.run_cli('status', env={'CAPBOX_LANG': 'en'})
        self.assertNotEqual(en.returncode, 0)
        self.assertIn('A runtime file upgrade did not finish; run upgrade rollback with a complete template', en.stderr)
        self.assertNotIn('升级未完成', en.stderr)

    def test_pre_catalog_missing_template_fallback_locked_in_zh_and_en(self):
        """CLI copy with no lib/ beside it cannot load catalogs; fallback still honors CAPBOX_LANG."""
        solo_dir = Path(self.tmp.name) / 'solo-bin'
        solo_dir.mkdir()
        solo = solo_dir / 'capbox'
        solo.write_bytes(CLI.read_bytes())
        solo.chmod(0o755)
        empty = Path(self.tmp.name) / 'empty-ws'
        empty.mkdir()
        def run(lang):
            merged = base_env()
            merged['CAPBOX_LANG'] = lang
            return subprocess.run([str(solo)], cwd=str(empty), env=merged,
                                  capture_output=True, text=True, timeout=20)
        zh = run('zh')
        self.assertEqual(zh.returncode, 1, zh.stderr)
        self.assertIn('找不到 CapBox 模板（CLI 旁无 lib/）；请安装 CapBox 或用项目内 .capbox/bin/capbox', zh.stderr)
        self.assertNotIn('CapBox template not found', zh.stderr)
        en = run('en')
        self.assertEqual(en.returncode, 1, en.stderr)
        self.assertIn('CapBox template not found (no lib/ next to the CLI); install CapBox or use a project-local .capbox/bin/capbox', en.stderr)
        self.assertNotIn('找不到 CapBox 模板', en.stderr)

    def test_old_bwrap_version_fallback_uses_val_unknown(self):
        """Host old-bwrap paths must not leak a hardcoded 未知 into English messages."""
        common = (REPO / 'lib/common.sh').read_text()
        start = common.index('_capbox_enforce_bwrap_baseline()')
        end = common.index('_capbox_audit_old_bwrap()', start)
        body = common[start:end]
        self.assertNotIn('未知', body)
        self.assertIn('val.unknown', body)
        config = (REPO / 'lib/config.sh').read_text()
        idx = config.index('config set CAPBOX_ALLOW_OLD_BWRAP 1')
        block = config[max(0, idx - 500): idx + 80]
        self.assertNotIn('未知', block)
        self.assertIn('val.unknown', block)

    def test_need_cmd_and_service_reason_args_use_catalog_keys(self):
        """Hints and service reasons must be catalog keys, not Chinese literals."""
        zh = i18n.load_catalog('zh')
        en = i18n.load_catalog('en')
        self.assertEqual(zh['rootfs.need_curl_to_download'], '下载 rootfs 需要 curl')
        self.assertEqual(en['rootfs.need_curl_to_download'], 'Downloading a rootfs requires curl')
        self.assertEqual(zh['cli.module_not_ready'], '{module} 尚未就绪')
        self.assertEqual(en['cli.module_not_ready'], '{module} is not ready')
        self.assertEqual(zh['svc.restricted_prerequisites_not_met'], 'restricted 前置不满足')
        self.assertEqual(en['svc.restricted_prerequisites_not_met'],
                         'restricted prerequisites are not met')
        self.assertNotIn('尚未就绪', Path(REPO / 'bin/capbox').read_text())
        import re
        cjk = re.compile(r'[\u4e00-\u9fff]')
        for rel, prefixes in (
            ('lib/rootfs.sh', ('need_cmd ',)),
            ('lib/config.sh', ('need_cmd ',)),
            ('lib/service.sh', ('_service_abort ', '_service_diagnose ')),
            ('bin/capbox', ('_require_decl ',)),
        ):
            for i, line in enumerate((REPO / rel).read_text().splitlines(), 1):
                if any(line.lstrip().startswith(p) or f'; {p}' in line for p in prefixes):
                    self.assertFalse(cjk.search(line), f'{rel}:{i}: {line}')

    def test_doctor_unknown_version_fallback_uses_val_unknown(self):
        """Doctor bwrap path must not leak a hardcoded 未知 into English messages."""
        common = (REPO / 'lib/common.sh').read_text()
        start = common.index('_capbox_doctor_check_bwrap()')
        end = common.index('cmd_doctor()', start)
        body = common[start:end]
        self.assertNotIn('未知', body)
        self.assertIn('val.unknown', body)

        fake = Path(self.tmp.name) / 'bwrap-unparseable'
        fake.write_text('#!/bin/sh\necho no-version-here\n')
        fake.chmod(0o755)
        zh = self.run_cli('doctor', env={'CAPBOX_LANG': 'zh', 'CAPBOX_BWRAP': str(fake)})
        self.assertIn('FAIL  bwrap 未知 低于安全基线 0.12.0', zh.stdout)
        self.assertNotIn('bwrap unknown is below', zh.stdout)
        en = self.run_cli('doctor', env={'CAPBOX_LANG': 'en', 'CAPBOX_BWRAP': str(fake)})
        self.assertIn('FAIL  bwrap unknown is below the 0.12.0 security baseline', en.stdout)
        for line in en.stdout.splitlines():
            if line.startswith('FAIL  bwrap '):
                self.assertNotIn('未知', line)

    def test_doctor_pass_fail_warn_locked_in_zh_and_en(self):
        """Representative doctor pass/fail/warn bodies and the summary follow CAPBOX_LANG."""
        zh = self.run_cli('doctor', env={'CAPBOX_LANG': 'zh'})
        self.assertIn('PASS  工作区安全', zh.stdout)
        self.assertIn('FAIL  rootfs 缺失或不可用', zh.stdout)
        self.assertIn('WARN  resolv.conf 尚未生成', zh.stdout)
        self.assertIn('自检结果:', zh.stdout)
        self.assertNotIn('Workspace is safe', zh.stdout)
        self.assertNotIn('Doctor result:', zh.stdout)
        self.assertNotIn('rootfs is missing or unavailable', zh.stdout)

        en = self.run_cli('doctor', env={'CAPBOX_LANG': 'en'})
        self.assertIn('PASS  Workspace is safe', en.stdout)
        self.assertIn('FAIL  rootfs is missing or unavailable', en.stdout)
        self.assertIn('WARN  resolv.conf has not been generated yet', en.stdout)
        self.assertIn('Doctor result:', en.stdout)
        self.assertNotIn('工作区安全', en.stdout)
        self.assertNotIn('自检结果:', en.stdout)
        self.assertNotIn('rootfs 缺失或不可用', en.stdout)

    def test_doctor_catalog_keys_locked_in_both_languages(self):
        zh = i18n.load_catalog('zh')
        en = i18n.load_catalog('en')
        self.assertEqual(zh['val.unknown'], '未知')
        self.assertEqual(en['val.unknown'], 'unknown')
        self.assertEqual(zh['doctor.bwrap_below_baseline'], 'bwrap {ver} 低于安全基线 0.12.0')
        self.assertEqual(en['doctor.bwrap_below_baseline'],
                         'bwrap {ver} is below the 0.12.0 security baseline')
        self.assertEqual(zh['doctor.summary_pass'], '自检结果: 全部通过')
        self.assertEqual(en['doctor.summary_pass'], 'Doctor result: all passed')
        self.assertEqual(zh['doctor.workspace_safe'], '工作区安全 ({workspace})')
        self.assertEqual(en['doctor.workspace_safe'], 'Workspace is safe ({workspace})')


if __name__ == '__main__':
    unittest.main()
