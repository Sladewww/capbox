#!/usr/bin/env python3
"""Language resolution, catalog completeness, and prefix/--help smoke tests."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
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

    def test_shared_detail_values_locked_and_not_leaked_in_english_doctor(self):
        """CAPBOX_*_DETAIL assignment sites follow CAPBOX_LANG; English doctor must not embed Chinese details."""
        zh_cat = i18n.load_catalog('zh')
        en_cat = i18n.load_catalog('en')
        self.assertEqual(
            zh_cat['idmap.detail_missing_helpers'],
            '缺少 newuidmap/newgidmap（安装 uidmap 包）；内核仅允许单 UID 自映射')
        self.assertEqual(
            en_cat['idmap.detail_missing_helpers'],
            'newuidmap/newgidmap are missing (install the uidmap package); '
            'the kernel only allows a single-UID self-mapping')
        self.assertEqual(
            zh_cat['common.bwrap_version_unparseable'],
            '无法解析 {bin} --version（需要 >= 0.12.0）')
        self.assertEqual(
            en_cat['common.bwrap_version_unparseable'],
            'unable to parse {bin} --version (need >= 0.12.0)')
        self.assertEqual(zh_cat['res.cgroup_dual_hint'].startswith('兑现限额需同时满足'), True)
        self.assertIn('Honoring limits requires both', en_cat['res.cgroup_dual_hint'])

        chinese_details = (
            '缺少 newuidmap/newgidmap',
            '内核仅允许单 UID 自映射',
            '无法获得可用 cgroup 父目录',
            '兑现限额需同时满足',
            '无法 mkdir 子目录',
            '无法解析',
        )
        zh = self.run_cli('doctor', env={'CAPBOX_LANG': 'zh'})
        en = self.run_cli('doctor', env={'CAPBOX_LANG': 'en'})
        en_text = en.stdout + en.stderr
        for phrase in chinese_details:
            self.assertNotIn(phrase, en_text, phrase)
        # On hosts without uidmap, the representative idmap detail must flip with the language.
        if '缺少 newuidmap/newgidmap' in zh.stdout:
            self.assertIn('newuidmap/newgidmap are missing', en.stdout)

        fake = Path(self.tmp.name) / 'bwrap-unparseable-detail'
        fake.write_text('#!/bin/sh\necho no-version-here\n')
        fake.chmod(0o755)
        def version_detail(lang):
            quoted = subprocess.list2cmdline([str(fake)])
            script = (
                f'export CAPBOX_LANG={lang}; '
                f'source "{I18N_SH}"; source "{REPO}/lib/common.sh"; '
                f'_capbox_bwrap_version_ok {quoted} || true; '
                'printf "%s\n" "$CAPBOX_BWRAP_VERSION_DETAIL"'
            )
            result = run_bash(script)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()
        zh_detail = version_detail('zh')
        en_detail = version_detail('en')
        self.assertIn('无法解析', zh_detail)
        self.assertNotIn('unable to parse', zh_detail)
        self.assertIn('unable to parse', en_detail)
        self.assertNotIn('无法解析', en_detail)

        import re
        cjk = re.compile(r'[\u4e00-\u9fff]')
        for rel, needles in (
            ('lib/common.sh', ('CAPBOX_BWRAP_VERSION_DETAIL=',)),
            ('lib/idmap.sh', ('CAPBOX_IDMAP_DETAIL=', 'CAPBOX_IDMAP_DROP_HELPER_DETAIL=')),
            ('lib/resources.sh', ('CAPBOX_CGROUP_DETAIL=', 'CAPBOX_CGROUP_FIND_WHY=', 'CAPBOX_DISK_DETAIL=')),
        ):
            for i, line in enumerate((REPO / rel).read_text().splitlines(), 1):
                if line.lstrip().startswith('#'):
                    continue
                if any(n in line for n in needles) and cjk.search(line):
                    self.fail(f'{rel}:{i} still has a Chinese DETAIL literal: {line}')

    def test_fail_closed_limit_reasons_locked_in_zh_and_en(self):
        """Require-mode fail-closed reasons, including the empty DISK_MAX fallback, follow CAPBOX_LANG."""
        zh_cat = i18n.load_catalog('zh')
        en_cat = i18n.load_catalog('en')
        self.assertEqual(
            zh_cat['res.fail_closed_memory_max'],
            'MEMORY_MAX(需要 cgroup memory.max，不能用 prlimit)')
        self.assertEqual(
            en_cat['res.fail_closed_memory_max'],
            'MEMORY_MAX(requires cgroup memory.max, cannot use prlimit)')
        self.assertEqual(zh_cat['res.fail_closed_pids_max'], 'PIDS_MAX(需要 cgroup pids.max)')
        self.assertEqual(en_cat['res.fail_closed_pids_max'], 'PIDS_MAX(requires cgroup pids.max)')
        self.assertEqual(zh_cat['res.fail_closed_cpu_max'], 'CPU_MAX(需要 cgroup cpu.max)')
        self.assertEqual(en_cat['res.fail_closed_cpu_max'], 'CPU_MAX(requires cgroup cpu.max)')
        self.assertEqual(zh_cat['res.fail_closed_disk_not_honored'], '未按私有 loop 兑现')
        self.assertEqual(en_cat['res.fail_closed_disk_not_honored'], 'not honored via a private loop')

        def run_fail_closed(lang):
            script = (
                f'export CAPBOX_LANG={lang}; '
                f'source "{I18N_SH}"; source "{REPO}/lib/resources.sh"; '
                '_resources_probe_disk() { CAPBOX_DISK_DETAIL=""; return 1; }; '
                'CAPBOX_RESOURCES_MODE=require; '
                'CAPBOX_MEMORY_MAX=32M; CAPBOX_PIDS_MAX=64; '
                'CAPBOX_CPU_MAX=50%; CAPBOX_DISK_MAX=1G; '
                'unset CAPBOX_RESOURCES_APPLIED_MEMORY CAPBOX_RESOURCES_APPLIED_PIDS; '
                'unset CAPBOX_RESOURCES_APPLIED_CPU CAPBOX_RESOURCES_APPLIED_DISK; '
                '_resources_fail_closed_check'
            )
            return run_bash(script)

        zh = run_fail_closed('zh')
        self.assertNotEqual(zh.returncode, 0, zh.stderr)
        self.assertIn('MEMORY_MAX(需要 cgroup memory.max，不能用 prlimit)', zh.stderr)
        self.assertIn('PIDS_MAX(需要 cgroup pids.max)', zh.stderr)
        self.assertIn('CPU_MAX(需要 cgroup cpu.max)', zh.stderr)
        self.assertIn('DISK_MAX(未按私有 loop 兑现)', zh.stderr)
        self.assertNotIn('cannot use prlimit', zh.stderr)
        self.assertNotIn('not honored via a private loop', zh.stderr)

        en = run_fail_closed('en')
        self.assertNotEqual(en.returncode, 0, en.stderr)
        self.assertIn('MEMORY_MAX(requires cgroup memory.max, cannot use prlimit)', en.stderr)
        self.assertIn('PIDS_MAX(requires cgroup pids.max)', en.stderr)
        self.assertIn('CPU_MAX(requires cgroup cpu.max)', en.stderr)
        self.assertIn('DISK_MAX(not honored via a private loop)', en.stderr)
        self.assertNotIn('不能用 prlimit', en.stderr)
        self.assertNotIn('未按私有 loop 兑现', en.stderr)
        self.assertNotIn('需要 cgroup', en.stderr)



class LeftoverResourcesRuntimeErrorTests(unittest.TestCase):
    """DISK_MAX unload, cgroup.procs write, and missing cgroup-leaf abort follow CAPBOX_LANG.

    The first two messages are translated on the host and interpolated into bash -c
    child scripts; the child itself must not call i18n_*. The leaf string is a
    ${var:?word} nounset abort, so the abort text must also follow CAPBOX_LANG.
    """

    def test_runtime_error_strings_locked_in_zh_and_en(self):
        zh_cat = i18n.load_catalog('zh')
        en_cat = i18n.load_catalog('en')
        self.assertEqual(zh_cat['res.disk_max_unload_failed_leaving'],
                         'capbox: DISK_MAX 卸载失败，保留 {base}')
        self.assertEqual(en_cat['res.disk_max_unload_failed_leaving'],
                         'capbox: DISK_MAX unload failed, leaving {base}')
        self.assertEqual(zh_cat['res.cgroup_procs_write_failed'], '写入 cgroup.procs 失败')
        self.assertEqual(en_cat['res.cgroup_procs_write_failed'], 'failed to write cgroup.procs')
        self.assertEqual(zh_cat['res.cgroup_leaf_missing_after_setup'],
                         'setup 后缺少 cgroup leaf')
        self.assertEqual(en_cat['res.cgroup_leaf_missing_after_setup'],
                         'cgroup leaf missing after setup')

    def test_hardcoded_runtime_error_literals_are_gone_from_resources_sh(self):
        needles = (
            'DISK_MAX 卸载失败',
            '写入 cgroup.procs 失败',
            'setup 后缺少 cgroup leaf',
        )
        for i, line in enumerate((REPO / 'lib/resources.sh').read_text().splitlines(), 1):
            if line.lstrip().startswith('#'):
                continue
            for needle in needles:
                if needle in line:
                    self.fail(f'lib/resources.sh:{i} still hardcodes {needle!r}: {line}')

    def test_host_lookup_and_child_scripts_do_not_call_i18n(self):
        text = (REPO / 'lib/resources.sh').read_text()
        self.assertIn('unload_fail="$(i18n_get res.disk_max_unload_failed_leaving)"', text)
        self.assertIn('procs_fail="$(i18n_get res.cgroup_procs_write_failed)"', text)
        self.assertIn('leaf_missing="$(i18n_get res.cgroup_leaf_missing_after_setup)"', text)
        self.assertIn("""$(printf '%q' "$unload_fail")""", text)
        self.assertIn("""$(printf '%q' "$procs_fail")""", text)
        # Quoted bash -c bodies must not invoke the catalog themselves.
        in_single = False
        buf = []
        chunks = []
        for line in text.splitlines():
            if "/bin/bash -c" in line:
                in_single = True
                buf = [line]
                continue
            if in_single:
                buf.append(line)
                # The wrap assignment ends at the closing quote of the script
                # followed by the bash/$cg/"$base" argument lines.
                if line.strip() in ('bash',) and buf:
                    chunks.append('\n'.join(buf))
                    in_single = False
                    buf = []
        self.assertGreaterEqual(len(chunks), 2, chunks)
        for chunk in chunks:
            self.assertNotIn('i18n_', chunk, chunk)

    def test_cgroup_leaf_nounset_abort_follows_lang(self):
        def run(lang):
            script = (
                f'export CAPBOX_LANG={lang}; '
                'log_warn() { :; }; log_err() { printf "%s\\n" "$*" >&2; }; '
                'log_debug() { :; }; have_cmd() { command -v "$1" >/dev/null 2>&1; }; '
                f'source "{I18N_SH}"; source "{REPO}/lib/resources.sh"; '
                '_resources_any_configured() { return 0; }; '
                '_resources_setup_cgroup() { CAPBOX_RESOURCES_CGROUP_LEAF=""; return 0; }; '
                'cmd=(true); _resources_wrap_argv cmd'
            )
            return run_bash(script)

        zh = run('zh')
        self.assertNotEqual(zh.returncode, 0, zh.stderr)
        self.assertIn('setup 后缺少 cgroup leaf', zh.stderr)
        self.assertNotIn('cgroup leaf missing after setup', zh.stderr)

        en = run('en')
        self.assertNotEqual(en.returncode, 0, en.stderr)
        self.assertIn('cgroup leaf missing after setup', en.stderr)
        self.assertNotIn('setup 后缺少 cgroup leaf', en.stderr)

    def test_cgroup_procs_write_failure_follows_lang(self):
        def run(lang):
            script = (
                f'export CAPBOX_LANG={lang}; '
                'log_warn() { :; }; log_err() { printf "%s\\n" "$*" >&2; }; '
                'log_debug() { :; }; have_cmd() { command -v "$1" >/dev/null 2>&1; }; '
                f'source "{I18N_SH}"; source "{REPO}/lib/resources.sh"; '
                'leaf=$(mktemp -d); chmod a-w "$leaf"; '
                'trap \'chmod u+w "$leaf"; rm -rf "$leaf"\' EXIT; '
                '_resources_any_configured() { return 0; }; '
                '_resources_setup_cgroup() { CAPBOX_RESOURCES_CGROUP_LEAF="$leaf"; return 0; }; '
                'cmd=(true); _resources_wrap_argv cmd; "${cmd[@]}"'
            )
            return run_bash(script)

        zh = run('zh')
        self.assertNotEqual(zh.returncode, 0, zh.stderr)
        self.assertIn('写入 cgroup.procs 失败', zh.stderr)
        self.assertNotIn('failed to write cgroup.procs', zh.stderr)

        en = run('en')
        self.assertNotEqual(en.returncode, 0, en.stderr)
        self.assertIn('failed to write cgroup.procs', en.stderr)
        self.assertNotIn('写入 cgroup.procs 失败', en.stderr)

    def test_disk_max_unload_failure_follows_lang(self):
        def run(lang):
            script = (
                f'export CAPBOX_LANG={lang}; '
                f'source "{I18N_SH}"; '
                'unload_fail="$(i18n_get res.disk_max_unload_failed_leaving)"; '
                "bash -c 'base=$1; _um='\"$(printf '%q' \"$unload_fail\")\"'; "
                r'''printf "%s\n" "${_um//\{base\}/$base}" >&2' bash /tmp/capbox-disk-base'''
            )
            return run_bash(script)

        zh = run('zh')
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertIn('capbox: DISK_MAX 卸载失败，保留 /tmp/capbox-disk-base', zh.stderr)
        self.assertNotIn('unload failed', zh.stderr)

        en = run('en')
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('capbox: DISK_MAX unload failed, leaving /tmp/capbox-disk-base', en.stderr)
        self.assertNotIn('卸载失败', en.stderr)



class PythonArgparseI18nTests(unittest.TestCase):
    """Python / argparse prompts follow CAPBOX_LANG; English must not embed the Chinese copy."""

    def test_representative_python_strings_locked_in_zh_and_en(self):
        zh = i18n.load_catalog('zh')
        en = i18n.load_catalog('en')
        self.assertEqual(zh['argparse.usage'], '用法: ')
        self.assertEqual(en['argparse.usage'], 'usage: ')
        self.assertEqual(zh['argparse.show_help'], '显示此帮助并退出')
        self.assertEqual(en['argparse.show_help'], 'show this help message and exit')
        self.assertEqual(zh['upgrade.failed'], '[capbox] 升级失败: {exc}')
        self.assertEqual(en['upgrade.failed'], '[capbox] upgrade failed: {exc}')
        self.assertEqual(zh['audit.report_generated'], '已生成审计报告: {path}（{count} 条事件）')
        self.assertEqual(en['audit.report_generated'], 'generated audit report: {path} ({count} events)')
        self.assertEqual(zh['audit.report_description'],
                         '导出可搜索、筛选的离线 HTML 审计报告，不启动服务')
        self.assertIn('searchable', en['audit.report_description'])
        self.assertEqual(zh['task.help_start'], '启动独立监督的 exec 任务')
        self.assertIn('supervised', en['task.help_start'])
        self.assertEqual(zh['mcp.help_profile'], '安全配置档（默认: %(default)s）')
        self.assertIn('security profile', en['mcp.help_profile'])
        self.assertEqual(zh['mcp.instructions'].startswith('固定工作区与策略'), True)
        self.assertIn('cannot raise the policy', en['mcp.instructions'])
        self.assertEqual(zh['cred.hint_empty_store'].startswith('未绑定凭据：宿主密钥库为空'), True)
        self.assertIn('host secret store is empty', en['cred.hint_empty_store'])
        self.assertNotIn('未绑定凭据', en['cred.hint_empty_net_allow'])
        self.assertNotIn('未绑定凭据', en['cred.hint_empty_store'])
        self.assertNotIn('未绑定凭据', en['cred.hint_domains_not_in_net_allow'])
        self.assertEqual(zh['net.publish_child_netns_not_ready'], 'publish: 子 netns 尚未就绪')
        self.assertEqual(en['net.publish_child_netns_not_ready'], 'publish: child netns is not ready')

    def test_python_resolve_lang_matches_locked_rules(self):
        self.assertEqual(i18n.resolve_lang({'CAPBOX_LANG': 'zh_CN'}), 'zh')
        self.assertEqual(i18n.resolve_lang({'CAPBOX_LANG': 'zh.UTF-8'}), 'zh')
        self.assertEqual(i18n.resolve_lang({'CAPBOX_LANG': 'en_US.UTF-8'}), 'en')
        self.assertEqual(i18n.resolve_lang({'LC_ALL': 'C'}), 'en')
        self.assertEqual(i18n.resolve_lang({'LANG': 'zh_CN.UTF-8'}), 'zh')
        self.assertEqual(i18n.resolve_lang({'LANG': 'zh_TW'}), 'en')
        self.assertEqual(i18n.resolve_lang({'CAPBOX_UI_LANG': 'zh', 'LC_ALL': 'C'}), 'zh')
        with self.assertRaises(SystemExit) as cm:
            i18n.resolve_lang({'CAPBOX_LANG': 'zh_TW'})
        self.assertEqual(cm.exception.code, 2)

    def test_python_fmt_and_t_follow_lang(self):
        zh_cat = i18n.load_catalog('zh')
        self.assertEqual(i18n.fmt(zh_cat, 'audit.report_generated', path='x', count=3),
                         '已生成审计报告: x（3 条事件）')
        previous = os.environ.get('CAPBOX_LANG')
        previous_ui = os.environ.get('CAPBOX_UI_LANG')
        try:
            os.environ.pop('CAPBOX_UI_LANG', None)
            os.environ['CAPBOX_LANG'] = 'zh'
            self.assertIn('已生成审计报告', i18n.t('audit.report_generated', path='x', count=3))
            os.environ['CAPBOX_LANG'] = 'en'
            text = i18n.t('audit.report_generated', path='x', count=3)
            self.assertIn('generated audit report', text)
            self.assertNotIn('已生成审计报告', text)
            hint = i18n.t('cred.hint_empty_store')
            self.assertIn('host secret store is empty', hint)
            self.assertNotIn('未绑定凭据', hint)
        finally:
            if previous is None:
                os.environ.pop('CAPBOX_LANG', None)
            else:
                os.environ['CAPBOX_LANG'] = previous
            if previous_ui is None:
                os.environ.pop('CAPBOX_UI_LANG', None)
            else:
                os.environ['CAPBOX_UI_LANG'] = previous_ui

    def test_publish_literal_is_gone_from_net_sh(self):
        text = (REPO / 'lib/net.sh').read_text()
        self.assertNotIn('子 netns 尚未就绪', text)
        self.assertIn('CAPBOX_PUBLISH_NETNS_MSG="$(i18n_get net.publish_child_netns_not_ready)"', text)
        self.assertIn('CAPBOX_PUBLISH_NETNS_MSG', text)


class PythonCliHelpTests(unittest.TestCase):
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

    def test_audit_report_help_follows_lang(self):
        zh = self.run_cli('audit', 'report', '--help', env={'CAPBOX_LANG': 'zh'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertIn('用法:', zh.stdout)
        self.assertIn('导出可搜索', zh.stdout)
        self.assertIn('显示此帮助并退出', zh.stdout)
        self.assertNotIn('usage:', zh.stdout)
        self.assertNotIn('show this help message and exit', zh.stdout)

        en = self.run_cli('audit', 'report', '--help', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('usage:', en.stdout)
        self.assertIn('searchable', en.stdout)
        self.assertIn('show this help message and exit', en.stdout)
        self.assertNotIn('用法:', en.stdout)
        self.assertNotIn('导出可搜索', en.stdout)

    def test_task_and_mcp_help_follow_lang(self):
        zh = self.run_cli('task', '--help', env={'CAPBOX_LANG': 'zh'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertIn('用法:', zh.stdout)
        self.assertIn('启动独立监督的 exec 任务', zh.stdout)
        en = self.run_cli('task', '--help', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('usage:', en.stdout)
        self.assertIn('supervised', en.stdout)
        self.assertNotIn('启动独立监督', en.stdout)
        self.assertNotIn('用法:', en.stdout)

        zh = self.run_cli('mcp', '--help', env={'CAPBOX_LANG': 'zh'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertIn('安全配置档', zh.stdout)
        en = self.run_cli('mcp', '--help', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('security profile', en.stdout)
        self.assertNotIn('安全配置档', en.stdout)


class TableOutputI18nTests(unittest.TestCase):
    """Human-facing status / distros / config list tables follow CAPBOX_LANG.

    Machine field names, column identifiers, and enum-like cell values stay
    English in both languages. cmd_status (daemon.sh) is the CLI path;
    status_oneshot in common.sh is the fallback when daemon.sh is not loaded.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='capbox-i18n-tables-')
        self.addCleanup(self.tmp.cleanup)
        self.ws = Path(self.tmp.name) / 'ws'
        self.ws.mkdir()

    def run_cli(self, *args, env=None):
        merged = base_env()
        if env:
            merged.update(env)
        return subprocess.run(
            [str(CLI), '--root', str(self.ws), *args],
            env=merged, capture_output=True, text=True, timeout=30)

    def test_catalog_table_strings_locked_in_zh_and_en(self):
        zh = i18n.load_catalog('zh')
        en = i18n.load_catalog('en')
        self.assertEqual(zh['status.label_distro'], '发行版     : {value}')
        self.assertEqual(en['status.label_distro'], 'Distro       : {value}')
        self.assertEqual(zh['status.label_rootfs'], 'rootfs     : {path}（{state}，{size}）')
        self.assertEqual(en['status.label_rootfs'], 'rootfs       : {path} ({state}, {size})')
        self.assertEqual(zh['status.state_missing'], '缺失')
        self.assertEqual(en['status.state_missing'], 'missing')
        self.assertEqual(zh['status.state_ready'], '就绪')
        self.assertEqual(en['status.state_ready'], 'ready')
        self.assertEqual(zh['status.daemon_stopped_hint'],
                         '守护进程   : 未运行（用后台任务运行 capbox up 启动）')
        self.assertEqual(en['status.daemon_stopped_hint'],
                         'Daemon       : not running (start with capbox up in a background task)')
        self.assertEqual(zh['status.daemon_stopped'], '守护进程   : 未运行')
        self.assertEqual(en['status.daemon_stopped'], 'Daemon       : not running')
        self.assertEqual(zh['status.mirror_none'], '镜像源     : none（未注入）')
        self.assertEqual(en['status.mirror_none'], 'Mirror       : none (not injected)')
        self.assertEqual(zh['status.proxy_none'], '代理       : 无（直连）')
        self.assertEqual(en['status.proxy_none'], 'Proxy        : none (direct)')
        self.assertEqual(zh['config.list_file'], '# 配置文件: {path}')
        self.assertEqual(en['config.list_file'], '# config file: {path}')
        self.assertEqual(zh['distros.header'], '可用发行版：')
        self.assertEqual(en['distros.header'], 'Available distros:')
        self.assertEqual(zh['distros.state_missing'], '未初始化')
        self.assertEqual(en['distros.state_missing'], 'not initialized')
        self.assertEqual(zh['distros.state_ready'], '已初始化')
        self.assertEqual(en['distros.state_ready'], 'initialized')
        self.assertEqual(zh['distros.cached_yes'], '是')
        self.assertEqual(en['distros.cached_yes'], 'yes')
        self.assertEqual(zh['distros.cached_no'], '否')
        self.assertEqual(en['distros.cached_no'], 'no')
        self.assertEqual(zh['val.unset'], '未设置')
        self.assertEqual(en['val.unset'], 'not set')

    def test_status_table_follows_lang_and_keeps_machine_tokens(self):
        zh = self.run_cli('status', env={'CAPBOX_LANG': 'zh'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertIn('发行版     : alpine', zh.stdout)
        self.assertIn('rootfs     :', zh.stdout)
        self.assertIn('（缺失，0B）', zh.stdout)
        self.assertIn('守护进程   : 未运行（用后台任务运行 capbox up 启动）', zh.stdout)
        self.assertIn('网络模式   : open', zh.stdout)
        self.assertIn('镜像源     : cn（', zh.stdout)
        self.assertIn('代理       : 无（直连）', zh.stdout)
        self.assertIn('宿主名     : capbox', zh.stdout)
        self.assertIn('bwrap      :', zh.stdout)
        self.assertIn('工作区     :', zh.stdout)
        self.assertIn('版本       :', zh.stdout)
        self.assertNotIn('Distro', zh.stdout)
        self.assertNotIn('Network mode', zh.stdout)
        self.assertNotIn('not running', zh.stdout)

        en = self.run_cli('status', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('Distro       : alpine', en.stdout)
        self.assertIn('rootfs       :', en.stdout)
        self.assertIn('(missing, 0B)', en.stdout)
        self.assertIn('Daemon       : not running (start with capbox up in a background task)', en.stdout)
        self.assertIn('Network mode : open', en.stdout)
        self.assertIn('Mirror       : cn (', en.stdout)
        self.assertIn('Proxy        : none (direct)', en.stdout)
        self.assertIn('Hostname     : capbox', en.stdout)
        self.assertIn('bwrap        :', en.stdout)
        self.assertIn('Workspace    :', en.stdout)
        self.assertIn('Version      :', en.stdout)
        self.assertNotIn('发行版', en.stdout)
        self.assertNotIn('守护进程', en.stdout)
        self.assertNotIn('网络模式', en.stdout)
        self.assertNotIn('缺失', en.stdout)
        self.assertNotIn('未运行', en.stdout)
        self.assertNotIn('无（直连）', en.stdout)
        # Machine field names and enum-like values stay English in both languages.
        for out in (zh.stdout, en.stdout):
            self.assertIn('rootfs', out)
            self.assertIn('bwrap', out)
            self.assertIn('alpine', out)
            self.assertIn('open', out)
            self.assertIn('cn', out)

    def test_status_json_stays_machine_english(self):
        zh = self.run_cli('status', '--json', env={'CAPBOX_LANG': 'zh'})
        en = self.run_cli('status', '--json', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertEqual(zh.stdout, en.stdout)
        self.assertIn('"distro":"alpine"', zh.stdout)
        self.assertIn('"rootfs":"', zh.stdout)
        self.assertIn('"running":false', zh.stdout.replace(' ', ''))
        self.assertIn('"net":"open"', zh.stdout)
        self.assertIn('"mirror":"cn"', zh.stdout)
        self.assertNotIn('发行版', zh.stdout)
        self.assertNotIn('Distro', zh.stdout)
        self.assertNotIn('缺失', zh.stdout)
        self.assertNotIn('missing', zh.stdout)
        self.assertNotIn('未注入', zh.stdout)
        self.assertNotIn('not injected', zh.stdout)

    def test_status_oneshot_fallback_follows_lang(self):
        """common.sh status_oneshot (no daemon.sh) uses the same catalog keys."""
        runtime = ('os', 'cache', 'run', 'state', 'logs', 'secrets', 'services')
        before = {name: (REPO / name).exists() for name in runtime}

        def _cleanup_repo_runtime():
            for name, existed in before.items():
                if not existed:
                    path = REPO / name
                    if path.is_dir():
                        shutil.rmtree(path, ignore_errors=True)

        self.addCleanup(_cleanup_repo_runtime)

        def run(lang):
            script = (
                f'export CAPBOX_LANG={lang}; '
                f'source "{REPO}/lib/common.sh"; '
                'status_oneshot'
            )
            result = run_bash(script)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout
        zh = run('zh')
        en = run('en')
        self.assertIn('发行版     : alpine', zh)
        self.assertIn('守护进程   : 未运行', zh)
        self.assertNotIn('用后台任务运行 capbox up 启动', zh)
        self.assertNotIn('Distro', zh)
        self.assertIn('Distro       : alpine', en)
        self.assertIn('Daemon       : not running', en)
        self.assertNotIn('start with capbox up', en)
        self.assertNotIn('发行版', en)
        self.assertNotIn('守护进程', en)
        for out in (zh, en):
            self.assertIn('rootfs', out)
            self.assertIn('alpine', out)
            self.assertIn('open', out)

    def test_distros_table_follows_lang_and_keeps_machine_tokens(self):
        zh = self.run_cli('distros', env={'CAPBOX_LANG': 'zh'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertIn('可用发行版：', zh.stdout)
        self.assertIn('  alpine  （未初始化）', zh.stdout)
        self.assertIn('  ubuntu  （未初始化）', zh.stdout)
        self.assertIn('镜像包 :', zh.stdout)
        self.assertIn('下载   :', zh.stdout)
        self.assertIn('已缓存 : 否', zh.stdout)
        self.assertIn('当前默认发行版: alpine（capbox init --distro <名字> 切换）', zh.stdout)
        self.assertNotIn('Available distros', zh.stdout)
        self.assertNotIn('not initialized', zh.stdout)

        en = self.run_cli('distros', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('Available distros:', en.stdout)
        self.assertIn('  alpine  (not initialized)', en.stdout)
        self.assertIn('  ubuntu  (not initialized)', en.stdout)
        self.assertIn('Tarball  :', en.stdout)
        self.assertIn('Download :', en.stdout)
        self.assertIn('Cached   : no', en.stdout)
        self.assertIn('Current default distro: alpine (switch with capbox init --distro <name>)', en.stdout)
        self.assertNotIn('可用发行版', en.stdout)
        self.assertNotIn('未初始化', en.stdout)
        self.assertNotIn('镜像包', en.stdout)
        self.assertNotIn('已缓存', en.stdout)
        for out in (zh.stdout, en.stdout):
            self.assertIn('alpine-minirootfs-', out)
            self.assertIn('ubuntu-base-', out)
            self.assertIn('https://', out)

    def test_config_list_footer_follows_lang_keys_stay_english(self):
        zh = self.run_cli('config', 'list', env={'CAPBOX_LANG': 'zh'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertIn('# 配置文件: ', zh.stdout)
        self.assertIn('CAPBOX_DISTRO', zh.stdout)
        self.assertIn('= alpine', zh.stdout)
        self.assertIn('CAPBOX_MIRROR', zh.stdout)
        self.assertIn('= cn', zh.stdout)
        self.assertIn('CAPBOX_NET', zh.stdout)
        self.assertIn('= open', zh.stdout)
        self.assertNotIn('# config file:', zh.stdout)

        en = self.run_cli('config', 'list', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('# config file: ', en.stdout)
        self.assertIn('CAPBOX_DISTRO', en.stdout)
        self.assertIn('= alpine', en.stdout)
        self.assertIn('CAPBOX_MIRROR', en.stdout)
        self.assertIn('= cn', en.stdout)
        self.assertIn('CAPBOX_NET', en.stdout)
        self.assertIn('= open', en.stdout)
        self.assertNotIn('配置文件', en.stdout)
        # Values that are machine enums stay English in both languages.
        for out in (zh.stdout, en.stdout):
            self.assertIn('CAPBOX_RESOURCES_MODE', out)
            self.assertIn('= warn', out)
            self.assertIn('CAPBOX_IDMAP', out)
            self.assertIn('= auto', out)
            self.assertIn('CAPBOX_SECURITY_PROFILE', out)
            self.assertIn('= compat', out)
            self.assertIn('CAPBOX_AUDIT', out)
            self.assertIn('= summary', out)

    def test_hardcoded_table_literals_are_gone_from_both_status_paths(self):
        needles = (
            '发行版     :',
            '守护进程   :',
            '网络模式   :',
            '镜像源     :',
            '代理       :',
            '宿主名     :',
            '工作区     :',
            '版本       :',
            '未运行（用后台任务运行 capbox up 启动）',
            '无（直连）',
            'none（未注入）',
            '可用发行版：',
            '已缓存 :',
            '当前默认发行版:',
            '# 配置文件:',
        )
        for rel in ('lib/common.sh', 'lib/daemon.sh'):
            for i, line in enumerate((REPO / rel).read_text().splitlines(), 1):
                if line.lstrip().startswith('#'):
                    continue
                for needle in needles:
                    if needle in line:
                        self.fail(f'{rel}:{i} still hardcodes {needle!r}: {line}')
        common = (REPO / 'lib/common.sh').read_text()
        daemon = (REPO / 'lib/daemon.sh').read_text()
        for key in (
            'status.label_distro', 'status.label_rootfs', 'status.state_missing',
            'status.state_ready', 'status.daemon_running', 'status.label_net',
            'status.label_mirror', 'status.proxy_none', 'status.label_bwrap',
        ):
            self.assertIn(key, common)
            self.assertIn(key, daemon)
        self.assertIn('status.daemon_stopped_hint', daemon)
        self.assertIn('status.daemon_stopped', common)
        self.assertIn('status.heartbeat', daemon)
        self.assertNotIn('status.heartbeat', common)
        self.assertIn('config.list_file', common)
        self.assertIn('distros.header', common)
        self.assertIn('distros.entry', common)
        self.assertIn('distros.footer', common)




class LeftoverSweepTests(unittest.TestCase):
    """Leftover credentials, package-lock, net-proxy, audit HTML, and audit-detail strings."""

    def test_catalog_strings_locked_in_zh_and_en(self):
        zh = i18n.load_catalog('zh')
        en = i18n.load_catalog('en')
        self.assertEqual(zh['cred.error_prefix'], '[capbox] 错误: {message}')
        self.assertEqual(en['cred.error_prefix'], '[capbox] error: {message}')
        self.assertEqual(zh['cred.secret_not_found'].startswith('找不到密钥:'), True)
        self.assertIn('secret not found', en['cred.secret_not_found'])
        self.assertNotIn('找不到密钥', en['cred.secret_not_found'])
        self.assertEqual(zh['pkglock.not_strict_lock'],
                         '不是有效的严格包锁；旧版清单请重新 image lock save')
        self.assertIn('image lock save', en['pkglock.not_strict_lock'])
        self.assertNotIn('不是有效的严格包锁', en['pkglock.not_strict_lock'])
        self.assertEqual(zh['pkglock.verify_ok'], '包锁验证通过')
        self.assertEqual(en['pkglock.verify_ok'], 'package lock verification passed')
        self.assertEqual(zh['proxy.cred_unbound'].startswith('凭据未绑定到该主机'), True)
        self.assertIn('not bound to this host', en['proxy.cred_unbound'])
        self.assertNotIn('凭据未绑定', en['proxy.cred_unbound'])
        self.assertIn('secret={name}', zh['proxy.cred_unbound'])
        self.assertIn('secret={name}', en['proxy.cred_unbound'])
        self.assertIn('CAPBOX_NET_ALLOW', zh['proxy.cred_unbound'])
        self.assertIn('CAPBOX_NET_ALLOW', en['proxy.cred_unbound'])
        self.assertEqual(zh['audit.no_log'], '(无审计日志)')
        self.assertEqual(en['audit.no_log'], '(no audit log)')
        self.assertEqual(zh['audit.detail_cmd_failed'], '{cmd} 失败，退出码 {rc}')
        self.assertEqual(en['audit.detail_cmd_failed'], '{cmd} failed, exit code {rc}')
        self.assertEqual(zh['audit.detail_upgrade_failed'], 'upgrade {action} 失败，退出码 {rc}')
        self.assertEqual(en['audit.detail_upgrade_failed'], 'upgrade {action} failed, exit code {rc}')
        self.assertEqual(zh['audit.detail_pkg_returned'], 'pkg {sub} 返回 {rc}')
        self.assertEqual(en['audit.detail_pkg_returned'], 'pkg {sub} returned {rc}')
        self.assertEqual(zh['audit.html.warn_bad_records'], '跳过 {count} 条损坏、过长或未写完的记录')
        self.assertIn('Skipped {count}', en['audit.html.warn_bad_records'])
        self.assertIn('status=fail', zh['audit.html.stat_failed_foot'])
        self.assertIn('status=fail', en['audit.html.stat_failed_foot'])
        self.assertIn('start/stop/skip', zh['audit.html.fact_counts'])
        self.assertIn('start/stop/skip', en['audit.html.fact_counts'])

    def test_hardcoded_leftover_literals_are_gone(self):
        needles = {
            'lib/credentials-runtime.py': (
                '[capbox] 错误:',
                '缺少宿主私有目录上下文（CAPBOX_CRED_PRIVATE）',
                '存储服务或自定义密钥（真实值仅在宿主）',
            ),
            'lib/package-lock.py': (
                '包锁验证通过',
                '[capbox] 包锁失败:',
                '不是有效的严格包锁',
            ),
            'lib/net-proxy.py': (
                'capbox-net: 白名单为空',
                '凭据未绑定到该主机',
                'enter-net needs a positive child PID and a command',
            ),
            'lib/audit.sh': ('(无审计日志)',),
            'lib/upgrade.sh': ('失败，退出码 $rc',),
            'lib/rootfs.sh': ('detail=init 失败，退出码',),
            'lib/agent.sh': ('detail=task 失败，退出码',),
            'lib/envkit.sh': ('detail=mcp 失败，退出码',),
            'lib/recipe.sh': ('detail=recipe 失败，退出码',),
            'lib/sandbox.sh': ('detail=pkg $sub 返回 $rc',),
            'lib/audit-report.html': (
                'CapBox · 审计报告',
                '生成时尚无审计文件',
                '跳过 ',
            ),
        }
        for rel, items in needles.items():
            text = (REPO / rel).read_text()
            for needle in items:
                self.assertNotIn(needle, text, f'{rel} still hardcodes {needle!r}')
        self.assertIn('i18n_fmt audit.detail_pkg_returned', (REPO / 'lib/sandbox.sh').read_text())
        self.assertIn('i18n_fmt audit.detail_upgrade_failed', (REPO / 'lib/upgrade.sh').read_text())
        self.assertIn('i18n_get audit.no_log', (REPO / 'lib/audit.sh').read_text())
        for rel, key in (
            ('lib/rootfs.sh', 'cmd=init'),
            ('lib/agent.sh', 'cmd=task'),
            ('lib/envkit.sh', 'cmd=mcp'),
            ('lib/recipe.sh', 'cmd=recipe'),
        ):
            self.assertIn('i18n_fmt audit.detail_cmd_failed ' + key, (REPO / rel).read_text())

    def test_package_lock_errors_follow_lang(self):
        lock = Path(tempfile.mkdtemp(prefix='capbox-lock-')) / 'package.lock'
        lock.write_text('# CapBox package.lock\nbusybox-1.0-r0\n')
        tool = REPO / 'lib/package-lock.py'
        cmd = [sys.executable, str(tool), 'validate', '--distro', 'alpine',
               '--architecture', 'x86_64', str(lock)]
        zh = subprocess.run(cmd, env={**base_env(), 'CAPBOX_LANG': 'zh'},
                            capture_output=True, text=True, timeout=10)
        en = subprocess.run(cmd, env={**base_env(), 'CAPBOX_LANG': 'en'},
                            capture_output=True, text=True, timeout=10)
        self.assertEqual(zh.returncode, 2, zh.stderr)
        self.assertEqual(en.returncode, 2, en.stderr)
        self.assertIn('重新 image lock save', zh.stderr)
        self.assertIn('[capbox] 包锁失败:', zh.stderr)
        self.assertIn('image lock save', en.stderr)
        self.assertIn('[capbox] package lock failed:', en.stderr)
        self.assertNotIn('包锁失败', en.stderr)
        self.assertNotIn('不是有效的严格包锁', en.stderr)

    def test_credentials_errors_and_help_follow_lang(self):
        tool = REPO / 'lib/credentials-runtime.py'
        zh = subprocess.run([sys.executable, str(tool), 'set'],
                            env={**base_env(), 'CAPBOX_LANG': 'zh'},
                            capture_output=True, text=True, timeout=10)
        en = subprocess.run([sys.executable, str(tool), 'set'],
                            env={**base_env(), 'CAPBOX_LANG': 'en'},
                            capture_output=True, text=True, timeout=10)
        self.assertNotEqual(zh.returncode, 0)
        self.assertNotEqual(en.returncode, 0)
        self.assertIn('[capbox] 错误:', zh.stderr)
        self.assertIn('未知服务', zh.stderr)
        self.assertIn('[capbox] error:', en.stderr)
        self.assertIn('unknown service', en.stderr)
        self.assertNotIn('未知服务', en.stderr)
        self.assertNotIn('[capbox] 错误:', en.stderr)

        zh_help = subprocess.run([sys.executable, str(tool), 'set', '--help'],
                                 env={**base_env(), 'CAPBOX_LANG': 'zh'},
                                 capture_output=True, text=True, timeout=10)
        en_help = subprocess.run([sys.executable, str(tool), 'set', '--help'],
                                 env={**base_env(), 'CAPBOX_LANG': 'en'},
                                 capture_output=True, text=True, timeout=10)
        self.assertEqual(zh_help.returncode, 0, zh_help.stderr)
        self.assertEqual(en_help.returncode, 0, en_help.stderr)
        self.assertIn('用法:', zh_help.stdout)
        self.assertIn('内置服务名', zh_help.stdout)
        self.assertIn('usage:', en_help.stdout)
        self.assertIn('built-in service name', en_help.stdout)
        self.assertNotIn('用法:', en_help.stdout)
        self.assertNotIn('内置服务名', en_help.stdout)

        zh_top = subprocess.run([sys.executable, str(tool), '--help'],
                                env={**base_env(), 'CAPBOX_LANG': 'zh'},
                                capture_output=True, text=True, timeout=10)
        en_top = subprocess.run([sys.executable, str(tool), '--help'],
                                env={**base_env(), 'CAPBOX_LANG': 'en'},
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(zh_top.returncode, 0, zh_top.stderr)
        self.assertEqual(en_top.returncode, 0, en_top.stderr)
        self.assertIn('存储服务或自定义密钥', zh_top.stdout)
        self.assertIn('store a service or custom secret', en_top.stdout)
        self.assertNotIn('存储服务或自定义密钥', en_top.stdout)

    def test_net_proxy_operator_strings_follow_lang(self):
        tool = REPO / 'lib/net-proxy.py'
        zh = subprocess.run([sys.executable, str(tool), 'proxy', '--sock', '/tmp/x', '--allow', ''],
                            env={**base_env(), 'CAPBOX_LANG': 'zh'},
                            capture_output=True, text=True, timeout=10)
        en = subprocess.run([sys.executable, str(tool), 'proxy', '--sock', '/tmp/x', '--allow', ''],
                            env={**base_env(), 'CAPBOX_LANG': 'en'},
                            capture_output=True, text=True, timeout=10)
        self.assertEqual(zh.returncode, 2, zh.stderr)
        self.assertEqual(en.returncode, 2, en.stderr)
        self.assertIn('capbox-net: 白名单为空', zh.stderr)
        self.assertIn('capbox-net: allowlist is empty', en.stderr)
        self.assertNotIn('白名单为空', en.stderr)

        zh_err = subprocess.run([sys.executable, str(tool), 'enter-net', '--child', '0'],
                                env={**base_env(), 'CAPBOX_LANG': 'zh'},
                                capture_output=True, text=True, timeout=10)
        en_err = subprocess.run([sys.executable, str(tool), 'enter-net', '--child', '0'],
                                env={**base_env(), 'CAPBOX_LANG': 'en'},
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(zh_err.returncode, 0)
        self.assertNotEqual(en_err.returncode, 0)
        self.assertIn('需要正数子进程 PID', zh_err.stderr)
        self.assertIn('needs a positive child PID', en_err.stderr)
        self.assertNotIn('需要正数子进程', en_err.stderr)

    def test_audit_tail_and_details_follow_lang(self):
        script = (
            'source lib/i18n.sh\n'
            '_capbox_resolve_lang_preview\n'
            'printf "%s\\n" "$(i18n_get audit.no_log)"\n'
            'printf "%s\\n" "$(i18n_fmt audit.detail_cmd_failed cmd=init rc=3)"\n'
            'printf "%s\\n" "$(i18n_fmt audit.detail_cmd_failed cmd=task rc=4)"\n'
            'printf "%s\\n" "$(i18n_fmt audit.detail_cmd_failed cmd=mcp rc=5)"\n'
            'printf "%s\\n" "$(i18n_fmt audit.detail_cmd_failed cmd=recipe rc=6)"\n'
            'printf "%s\\n" "$(i18n_fmt audit.detail_upgrade_failed action=apply rc=7)"\n'
            'printf "%s\\n" "$(i18n_fmt audit.detail_pkg_returned sub=install rc=8)"\n'
        )
        zh = run_bash(script, env={'CAPBOX_LANG': 'zh'})
        en = run_bash(script, env={'CAPBOX_LANG': 'en'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('(无审计日志)', zh.stdout)
        self.assertIn('init 失败，退出码 3', zh.stdout)
        self.assertIn('task 失败，退出码 4', zh.stdout)
        self.assertIn('mcp 失败，退出码 5', zh.stdout)
        self.assertIn('recipe 失败，退出码 6', zh.stdout)
        self.assertIn('upgrade apply 失败，退出码 7', zh.stdout)
        self.assertIn('pkg install 返回 8', zh.stdout)
        self.assertIn('(no audit log)', en.stdout)
        self.assertIn('init failed, exit code 3', en.stdout)
        self.assertIn('task failed, exit code 4', en.stdout)
        self.assertIn('mcp failed, exit code 5', en.stdout)
        self.assertIn('recipe failed, exit code 6', en.stdout)
        self.assertIn('upgrade apply failed, exit code 7', en.stdout)
        self.assertIn('pkg install returned 8', en.stdout)
        self.assertNotIn('失败，退出码', en.stdout)
        self.assertNotIn('无审计日志', en.stdout)
        self.assertNotIn('返回 8', en.stdout)

    def test_audit_tail_cli_follows_lang(self):
        tmp = tempfile.TemporaryDirectory(prefix='capbox-i18n-audit-')
        self.addCleanup(tmp.cleanup)
        ws = Path(tmp.name) / 'ws'
        ws.mkdir()

        def run(lang):
            return subprocess.run(
                [str(CLI), '--root', str(ws), 'audit', 'tail'],
                env={**base_env(), 'CAPBOX_LANG': lang},
                capture_output=True, text=True, timeout=30)

        zh = run('zh')
        en = run('en')
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('(无审计日志)', zh.stdout)
        self.assertIn('(no audit log)', en.stdout)
        self.assertNotIn('无审计日志', en.stdout)

    def test_audit_html_follows_lang_and_keeps_machine_tokens(self):
        tmp = tempfile.TemporaryDirectory(prefix='capbox-i18n-html-')
        self.addCleanup(tmp.cleanup)
        ws = Path(tmp.name) / 'ws'
        ws.mkdir()
        source = ws / '.capbox' / 'logs' / 'audit.jsonl'
        source.parent.mkdir(parents=True, exist_ok=True)
        event = {'ts': '2026-11-08T00:00:00Z', 'kind': 'exec', 'status': 'fail',
                 'exit': 7, 'ms': 12, 'cmd': 'false'}
        source.write_text(json.dumps(event) + '\n{broken}\n')
        out_zh = Path(tmp.name) / 'zh.html'
        out_en = Path(tmp.name) / 'en.html'

        def generate(path, lang):
            return subprocess.run(
                [str(CLI), '--root', str(ws), 'audit', 'report',
                 '--output', str(path), '--force'],
                env={**base_env(), 'CAPBOX_LANG': lang},
                capture_output=True, text=True, timeout=30)

        zh = generate(out_zh, 'zh')
        en = generate(out_en, 'en')
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('已生成审计报告', zh.stdout)
        self.assertIn('generated audit report', en.stdout)
        self.assertNotIn('已生成审计报告', en.stdout)
        zh_html = out_zh.read_text()
        en_html = out_en.read_text()
        self.assertIn('lang="zh-CN"', zh_html)
        self.assertIn('lang="en"', en_html)
        self.assertIn('CapBox · 审计报告', zh_html)
        self.assertIn('CapBox · Audit Report', en_html)
        self.assertNotIn('CapBox · 审计报告', en_html)

        def ui(html):
            match = re.search(r'const I18N = (\{.*?\});\n', html)
            self.assertIsNotNone(match)
            return json.loads(match.group(1))

        zh_ui = ui(zh_html)
        en_ui = ui(en_html)
        self.assertEqual(zh_ui['warn_bad_records'], '跳过 {count} 条损坏、过长或未写完的记录')
        self.assertIn('Skipped {count}', en_ui['warn_bad_records'])
        self.assertNotIn('跳过', en_ui['warn_bad_records'])
        self.assertEqual(zh_ui['locale'], 'zh-CN')
        self.assertEqual(en_ui['locale'], 'en')
        for html in (zh_html, en_html):
            self.assertIn('status=fail', html)
            self.assertIn('start/stop/skip', html)
            data = json.loads(re.search(
                r'<script id="report-data" type="application/json">(.*?)</script>',
                html, re.S)[1])
            self.assertEqual(data['schema'], 'capbox.audit-report.v1')
            self.assertEqual(data['events'][0]['kind'], 'exec')
            self.assertEqual(data['events'][0]['status'], 'fail')
            self.assertNotIn('i18n', data)


class EmptyListAndProcessCountI18nTests(unittest.TestCase):
    """Empty-list placeholders and the host-interpolated capbox ps count line."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='capbox-i18n-')
        self.addCleanup(self.tmp.cleanup)
        self.ws = Path(self.tmp.name) / 'ws'
        self.ws.mkdir()

    def run_cli(self, *args, env=None):
        merged = base_env()
        if env:
            merged.update(env)
        return subprocess.run(
            [str(CLI), '--root', str(self.ws), *args],
            env=merged, capture_output=True, text=True, timeout=30)

    def _ps_script(self, lang, extra):
        return (
            f'export CAPBOX_LANG={lang}; '
            f'source "{I18N_SH}"; '
            f'source "{REPO}/lib/common.sh"; '
            f'source "{REPO}/lib/sandbox.sh"; '
            + extra
        )

    def test_catalog_strings_locked_in_zh_and_en(self):
        zh = i18n.load_catalog('zh')
        en = i18n.load_catalog('en')
        self.assertEqual(zh['fs.no_snapshots'], '(无快照)')
        self.assertEqual(en['fs.no_snapshots'], '(no snapshots)')
        self.assertEqual(zh['image.no_exported_images'], '(无导出镜像)')
        self.assertEqual(en['image.no_exported_images'], '(no exported images)')
        self.assertEqual(zh['image.no_package_lock'], '(无 package.lock；先 image lock save)')
        self.assertIn('package.lock', en['image.no_package_lock'])
        self.assertIn('image lock save', en['image.no_package_lock'])
        self.assertNotIn('无 package.lock', en['image.no_package_lock'])
        self.assertEqual(zh['svc.no_service_dir'], '(无服务定义目录 {d})')
        self.assertEqual(en['svc.no_service_dir'], '(no service definition directory {d})')
        self.assertEqual(zh['svc.no_service_defs'], '(尚无 *.env 服务定义)')
        self.assertIn('*.env', en['svc.no_service_defs'])
        self.assertNotIn('尚无', en['svc.no_service_defs'])
        self.assertEqual(zh['sandbox.ps_total'], '共 {count} 个进程')
        self.assertEqual(en['sandbox.ps_total'], '{count} processes')

    def test_hardcoded_literals_are_gone(self):
        needles = {
            'lib/fsguard.sh': ('(无快照)',),
            'lib/image.sh': ('(无导出镜像)', '(无 package.lock；先 image lock save)'),
            'lib/service.sh': ('(无服务定义目录', '(尚无 *.env 服务定义)'),
            'lib/sandbox.sh': ('共 $i 个进程', '共 "$i" 个进程'),
        }
        for rel, items in needles.items():
            text = (REPO / rel).read_text()
            for needle in items:
                self.assertNotIn(needle, text, f'{rel} still hardcodes {needle!r}')
        sandbox = (REPO / 'lib/sandbox.sh').read_text()
        self.assertIn('i18n_get sandbox.ps_total', sandbox)
        self.assertIn('$(_shq "$total_fmt")', sandbox)
        start = sandbox.index("printf '%s' 'i=0; for d in /proc/[0-9]*;")
        body = sandbox[start:sandbox.index('cmd_ps()', start)]
        self.assertNotIn('i18n_', body)

    def test_empty_list_cli_follows_lang(self):
        zh = self.run_cli('snapshot', 'list', env={'CAPBOX_LANG': 'zh'})
        en = self.run_cli('snapshot', 'list', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('(无快照)', zh.stdout)
        self.assertIn('(no snapshots)', en.stdout)
        self.assertNotIn('无快照', en.stdout)
        self.assertNotIn('no snapshots', zh.stdout)

        zh = self.run_cli('image', 'list', env={'CAPBOX_LANG': 'zh'})
        en = self.run_cli('image', 'list', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('(无导出镜像)', zh.stdout)
        self.assertIn('(no exported images)', en.stdout)
        self.assertNotIn('无导出镜像', en.stdout)

        zh = self.run_cli('image', 'lock', 'show', env={'CAPBOX_LANG': 'zh'})
        en = self.run_cli('image', 'lock', 'show', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('(无 package.lock；先 image lock save)', zh.stdout)
        self.assertIn('package.lock', en.stdout)
        self.assertIn('image lock save', en.stdout)
        self.assertNotIn('无 package.lock', en.stdout)

        zh = self.run_cli('service', 'list', env={'CAPBOX_LANG': 'zh'})
        en = self.run_cli('service', 'list', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('(无服务定义目录', zh.stdout)
        self.assertIn('(no service definition directory', en.stdout)
        self.assertNotIn('无服务定义目录', en.stdout)
        self.assertIn(str(self.ws), zh.stdout)
        self.assertIn(str(self.ws), en.stdout)

        services = self.ws / '.capbox' / 'services'
        services.mkdir(parents=True, exist_ok=True)
        zh = self.run_cli('service', 'list', env={'CAPBOX_LANG': 'zh'})
        en = self.run_cli('service', 'list', env={'CAPBOX_LANG': 'en'})
        self.assertEqual(zh.returncode, 0, zh.stderr)
        self.assertEqual(en.returncode, 0, en.stderr)
        self.assertIn('(尚无 *.env 服务定义)', zh.stdout)
        self.assertIn('(no *.env service definitions yet)', en.stdout)
        self.assertIn('*.env', zh.stdout)
        self.assertIn('*.env', en.stdout)
        self.assertNotIn('尚无', en.stdout)

    def test_ps_fallback_command_is_host_interpolated(self):
        zh = run_bash(self._ps_script('zh', '_sandbox_ps_proc_fallback_cmd'))
        en = run_bash(self._ps_script('en', '_sandbox_ps_proc_fallback_cmd'))
        self.assertEqual(zh.returncode, 0, zh.stderr + zh.stdout)
        self.assertEqual(en.returncode, 0, en.stderr + en.stdout)
        self.assertIn("printf '共 %s 个进程' \"$i\"; echo", zh.stdout)
        self.assertIn("printf '%s processes' \"$i\"; echo", en.stdout)
        self.assertNotIn('i18n_', zh.stdout)
        self.assertNotIn('i18n_', en.stdout)
        self.assertNotIn('共 %s 个进程', en.stdout)
        self.assertNotIn('%s processes', zh.stdout)

        eval_foot = (
            'cmd="$(_sandbox_ps_proc_fallback_cmd)"; '
            'foot="${cmd#*; printf }"; '
            'i=7; eval "printf $foot"'
        )
        zh_f = run_bash(self._ps_script('zh', eval_foot))
        en_f = run_bash(self._ps_script('en', eval_foot))
        self.assertEqual(zh_f.returncode, 0, zh_f.stderr + zh_f.stdout)
        self.assertEqual(en_f.returncode, 0, en_f.stderr + en_f.stdout)
        self.assertIn('共 7 个进程', zh_f.stdout)
        self.assertIn('7 processes', en_f.stdout)
        self.assertNotIn('共 7 个进程', en_f.stdout)
        self.assertNotIn('个进程', en_f.stdout)


class LandlockHelperI18nTests(unittest.TestCase):
    """C landlock helper uses static zh/en sets keyed off CAPBOX_UI_LANG."""

    SRC = REPO / 'lib/guest/capbox-landlock.c'
    LANDLOCK_SH = REPO / 'lib/landlock.sh'

    @classmethod
    def setUpClass(cls):
        cls.tmpdir = tempfile.TemporaryDirectory(prefix='capbox-landlock-i18n-')
        cls.helper = Path(cls.tmpdir.name) / 'capbox-landlock'
        built = subprocess.run(
            ['gcc', '-O2', '-o', str(cls.helper), str(cls.SRC)],
            capture_output=True, text=True, timeout=30)
        if built.returncode != 0:
            cls.tmpdir.cleanup()
            raise unittest.SkipTest(
                f'cannot compile landlock helper: {built.stderr}')

    @classmethod
    def tearDownClass(cls):
        cls.tmpdir.cleanup()

    def run_helper(self, args, ui_lang, rules_text=None):
        env = base_env()
        if ui_lang is None:
            env.pop('CAPBOX_UI_LANG', None)
        else:
            env['CAPBOX_UI_LANG'] = ui_lang
        work = Path(self.tmpdir.name)
        cmd = [str(self.helper), *args]
        if rules_text is not None:
            rules = work / 'rules'
            rules.write_text(rules_text)
            cmd = [str(rules) if arg == 'RULES' else arg for arg in cmd]
        return subprocess.run(
            cmd, env=env, capture_output=True, text=True, timeout=20,
            cwd=str(work))

    def test_source_has_static_sets_and_no_catalog_parse(self):
        src = self.SRC.read_text()
        self.assertIn('getenv("CAPBOX_UI_LANG")', src)
        self.assertIn('拒绝规则路径', src)
        self.assertIn('rejected rule path', src)
        self.assertIn('内核不支持 Landlock', src)
        self.assertIn('kernel does not support Landlock', src)
        self.assertNotIn('.msg', src)
        self.assertNotIn('i18n', src)
        self.assertNotIn('"--messages"', src)
        self.assertNotRegex(src, r'strcmp\s*\([^)]*--messages')
        lowered = src.lower()
        self.assertNotIn('catalog', lowered)
        self.assertNotRegex(src, r'\bload_msg\b|\bmsgfile\b')

    def test_host_landlock_sh_passes_ui_lang_and_keeps_catalog_errors(self):
        text = self.LANDLOCK_SH.read_text()
        self.assertIn('--setenv CAPBOX_UI_LANG "${CAPBOX_UI_LANG:-en}"', text)
        self.assertIn('i18n_err landlock.missing_lib_guest_capbox_landlock_c', text)
        self.assertNotIn('--messages', text)

    def test_usage_stays_english_in_both_languages(self):
        usage = 'usage: capbox-landlock --rules FILE -- CMD [ARGS...]'
        for lang in ('zh', 'en', None, '', 'C', 'zh_TW', 'zh_CN'):
            result = self.run_helper(['--nope'], lang)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn(usage, result.stderr)
            self.assertNotIn('用法', result.stderr)

    def test_rules_flag_and_empty_file_follow_ui_lang(self):
        zh = self.run_helper(['--rules'], 'zh')
        en = self.run_helper(['--rules'], 'en')
        self.assertEqual(zh.returncode, 2, zh.stderr)
        self.assertEqual(en.returncode, 2, en.stderr)
        self.assertIn('capbox-landlock: --rules 缺少路径', zh.stderr)
        self.assertIn('capbox-landlock: --rules is missing a path', en.stderr)
        self.assertNotIn('缺少路径', en.stderr)
        self.assertNotIn('missing a path', zh.stderr)

        zh = self.run_helper(['--rules', 'RULES', '--', '/bin/true'], 'zh', '')
        en = self.run_helper(['--rules', 'RULES', '--', '/bin/true'], 'en', '')
        self.assertEqual(zh.returncode, 1, zh.stderr)
        self.assertEqual(en.returncode, 1, en.stderr)
        self.assertIn('capbox-landlock: 规则为空', zh.stderr)
        self.assertIn('capbox-landlock: rules are empty', en.stderr)
        self.assertNotIn('规则为空', en.stderr)

    def test_rule_parse_errors_follow_ui_lang(self):
        cases = [
            ('nopath\n', '规则格式必须是 ro|rw 绝对路径',
             'rule format must be ro|rw absolute path'),
            ('xx /tmp\n', '未知规则类型 xx', 'unknown rule type xx'),
            ('ro relative\n', '拒绝规则路径 relative', 'rejected rule path relative'),
            ('ro /tmp/../etc\n', '拒绝规则路径 /tmp/../etc',
             'rejected rule path /tmp/../etc'),
        ]
        for rules, zh_need, en_need in cases:
            zh = self.run_helper(['--rules', 'RULES', '--', '/bin/true'], 'zh', rules)
            en = self.run_helper(['--rules', 'RULES', '--', '/bin/true'], 'en', rules)
            self.assertEqual(zh.returncode, 1, zh.stderr)
            self.assertEqual(en.returncode, 1, en.stderr)
            self.assertIn('capbox-landlock: ' + zh_need, zh.stderr)
            self.assertIn('capbox-landlock: ' + en_need, en.stderr)
            self.assertNotIn(zh_need, en.stderr)

        missing = Path(self.tmpdir.name) / 'missing-rules'
        zh = self.run_helper(['--rules', str(missing), '--', '/bin/true'], 'zh')
        en = self.run_helper(['--rules', str(missing), '--', '/bin/true'], 'en')
        self.assertEqual(zh.returncode, 1, zh.stderr)
        self.assertEqual(en.returncode, 1, en.stderr)
        self.assertIn(f'capbox-landlock: 打不开规则 {missing}:', zh.stderr)
        self.assertIn(f'capbox-landlock: cannot open rules {missing}:', en.stderr)
        self.assertNotIn('打不开规则', en.stderr)

        zh = self.run_helper(
            ['--rules', 'RULES', '--', '/bin/true'], 'zh',
            'ro /no-such-capbox-ll-path\n')
        en = self.run_helper(
            ['--rules', 'RULES', '--', '/bin/true'], 'en',
            'ro /no-such-capbox-ll-path\n')
        self.assertEqual(zh.returncode, 1, zh.stderr)
        self.assertEqual(en.returncode, 1, en.stderr)
        self.assertIn('capbox-landlock: 打不开 /no-such-capbox-ll-path:', zh.stderr)
        self.assertIn('capbox-landlock: cannot open /no-such-capbox-ll-path:',
                      en.stderr)
        self.assertNotIn('打不开 /no-such', en.stderr)

        long_line = 'ro /' + ('a' * 9000) + '\n'
        zh = self.run_helper(['--rules', 'RULES', '--', '/bin/true'], 'zh', long_line)
        en = self.run_helper(['--rules', 'RULES', '--', '/bin/true'], 'en', long_line)
        self.assertEqual(zh.returncode, 1, zh.stderr)
        self.assertEqual(en.returncode, 1, en.stderr)
        self.assertIn('capbox-landlock: 规则行过长', zh.stderr)
        self.assertIn('capbox-landlock: rule line too long', en.stderr)
        self.assertNotIn('规则行过长', en.stderr)

        too_many = ''.join('rw /tmp\n' for _ in range(4097))
        zh = self.run_helper(['--rules', 'RULES', '--', '/bin/true'], 'zh', too_many)
        en = self.run_helper(['--rules', 'RULES', '--', '/bin/true'], 'en', too_many)
        self.assertEqual(zh.returncode, 1, zh.stderr)
        self.assertEqual(en.returncode, 1, en.stderr)
        self.assertIn('capbox-landlock: 规则过多', zh.stderr)
        self.assertIn('capbox-landlock: too many rules', en.stderr)
        self.assertNotIn('规则过多', en.stderr)

    def test_exec_failure_follows_ui_lang(self):
        missing = '/no-such-capbox-landlock-cmd'
        zh = self.run_helper(['--rules', 'RULES', '--', missing], 'zh', 'rw /tmp\n')
        en = self.run_helper(['--rules', 'RULES', '--', missing], 'en', 'rw /tmp\n')
        self.assertEqual(zh.returncode, 127, zh.stderr)
        self.assertEqual(en.returncode, 127, en.stderr)
        self.assertIn(f'capbox-landlock: exec {missing} 失败:', zh.stderr)
        self.assertIn(f'capbox-landlock: exec {missing} failed:', en.stderr)
        self.assertNotIn('失败:', en.stderr)

    def test_only_exact_zh_selects_chinese(self):
        zh = self.run_helper(['--rules'], 'zh')
        self.assertIn('缺少路径', zh.stderr)
        for lang in (None, '', 'en', 'C', 'C.UTF-8', 'en_US', 'zh_TW', 'zh_HK',
                     'zh_CN', 'zh.UTF-8'):
            result = self.run_helper(['--rules'], lang)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('--rules is missing a path', result.stderr)
            self.assertNotIn('缺少路径', result.stderr)

    def test_apply_argv_injects_normalized_ui_lang(self):
        for lang in ('zh', 'en'):
            d = Path(self.tmpdir.name) / f'apply-{lang}'
            d.mkdir(parents=True, exist_ok=True)
            body = (
                f'set -euo pipefail; '
                f'export CAPBOX_LANG={lang}; '
                f'export CAPBOX_DIR="{d}/cb"; '
                f'export CAPBOX_WORKSPACE="{d}/ws"; '
                f'export CAPBOX_LANDLOCK=on; '
                f'mkdir -p "$CAPBOX_DIR" "$CAPBOX_WORKSPACE"; '
                f'source "{I18N_SH}"; '
                f'source "{REPO}/lib/common.sh"; '
                f'source "{REPO}/lib/landlock.sh"; '
                'cmd=(/usr/sbin/bwrap --bind / / -- /bin/true); '
                '_landlock_apply_argv cmd; '
                'printf "UI=%s\\n" "$CAPBOX_UI_LANG"; '
                'i=0; while (( i < ${#cmd[@]} )); do '
                '  if [[ "${cmd[$i]}" == "--setenv" '
                '        && "${cmd[$((i+1))]}" == "CAPBOX_UI_LANG" ]]; then '
                '    printf "SET=%s\\n" "${cmd[$((i+2))]}"; '
                '  fi; '
                '  i=$((i+1)); '
                'done'
            )
            result = run_bash(body, env={'CAPBOX_LANG': lang})
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn(f'UI={lang}', result.stdout)
            self.assertIn(f'SET={lang}', result.stdout)


class SupervisorSeccompI18nTests(unittest.TestCase):
    """CLI help and SystemExit follow CAPBOX_LANG; supervisor _log stays a language-independent English literal."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='capbox-i18n-supervisor-')
        self.addCleanup(self.tmp.cleanup)

    def run_tool(self, tool, args, lang):
        return subprocess.run(
            [sys.executable, str(REPO / tool), *args],
            env={**base_env(), 'CAPBOX_LANG': lang},
            capture_output=True, text=True, timeout=15)

    def test_catalog_strings_locked_in_zh_and_en(self):
        zh = i18n.load_catalog('zh')
        en = i18n.load_catalog('en')
        self.assertEqual(zh['supervisor.pass_fd_must_be_gt_stderr'],
                         '--pass-fd 必须是大于 stderr 的描述符')
        self.assertEqual(en['supervisor.pass_fd_must_be_gt_stderr'],
                         '--pass-fd must be a file descriptor greater than stderr')
        self.assertNotIn('必须是大于', en['supervisor.pass_fd_must_be_gt_stderr'])
        self.assertEqual(zh['seccomp.lib_not_found'],
                         '未找到 libseccomp（请安装 libseccomp）')
        self.assertIn('libseccomp', en['seccomp.lib_not_found'])
        self.assertNotIn('未找到', en['seccomp.lib_not_found'])
        self.assertEqual(zh['seccomp.compat_needs_extra_restriction'],
                         'compat 需要显式附加限制')
        self.assertEqual(en['seccomp.compat_needs_extra_restriction'],
                         'compat requires an explicit extra restriction')
        self.assertEqual(zh['seccomp.unknown_profile'], '未知 seccomp 配置: {profile}')
        self.assertEqual(en['seccomp.unknown_profile'], 'unknown seccomp profile: {profile}')
        self.assertEqual(zh['seccomp.init_failed'], 'seccomp_init 失败')
        self.assertEqual(en['seccomp.init_failed'], 'seccomp_init failed')
        self.assertEqual(zh['seccomp.export_failed'], 'seccomp_export_bpf 失败: {rc}')
        self.assertEqual(en['seccomp.export_failed'], 'seccomp_export_bpf failed: {rc}')
        self.assertEqual(zh['seccomp.bpf_too_small'],
                         'BPF 过小 ({size})；libseccomp 导出失败')
        self.assertEqual(en['seccomp.bpf_too_small'],
                         'BPF too small ({size}); libseccomp export failed')
        self.assertEqual(zh['seccomp.unresolved_syscalls'],
                         'seccomp-gen 配置={profile} 未解析系统调用: {missing}')
        self.assertEqual(en['seccomp.unresolved_syscalls'],
                         'seccomp-gen profile={profile} unresolved syscalls: {missing}')
        self.assertEqual(zh['seccomp.help_out'], 'BPF 输出路径')
        self.assertEqual(en['seccomp.help_out'], 'BPF output path')
        self.assertTrue(zh['seccomp.tool_description'].startswith(
            '为 CapBox untrusted/strict 配置生成 seccomp BPF。'))
        self.assertTrue(en['seccomp.tool_description'].startswith(
            'Generate a seccomp BPF for a CapBox untrusted/strict profile.'))
        self.assertNotIn('为 CapBox', en['seccomp.tool_description'])
        for catalog in (zh, en):
            self.assertNotIn('supervisor.ready', catalog)
            self.assertNotIn('supervisor.missing_child_argv', catalog)
            self.assertNotIn('supervisor.starting', catalog)
            self.assertNotIn('supervisor.max_restarts', catalog)

    def test_seccomp_generated_placeholders_match_call_and_render(self):
        """Catalog placeholders are {rules}/{bytes}, matching the call kwargs."""
        zh = i18n.load_catalog('zh')
        en = i18n.load_catalog('en')
        self.assertEqual(
            zh['seccomp.generated'],
            'seccomp-gen 配置={profile} arch={arch} rules={rules} bytes={bytes}')
        self.assertEqual(
            en['seccomp.generated'],
            'seccomp-gen profile={profile} arch={arch} rules={rules} bytes={bytes}')
        for catalog in (zh, en):
            self.assertIn('{rules}', catalog['seccomp.generated'])
            self.assertIn('{bytes}', catalog['seccomp.generated'])
            self.assertNotIn('{added}', catalog['seccomp.generated'])
            self.assertNotIn('{size}', catalog['seccomp.generated'])
        self.assertEqual(
            i18n.fmt(zh, 'seccomp.generated',
                     profile='untrusted', arch='x86_64', rules=18, bytes=256),
            'seccomp-gen 配置=untrusted arch=x86_64 rules=18 bytes=256')
        self.assertEqual(
            i18n.fmt(en, 'seccomp.generated',
                     profile='untrusted', arch='x86_64', rules=18, bytes=256),
            'seccomp-gen profile=untrusted arch=x86_64 rules=18 bytes=256')
        src = (REPO / 'lib/seccomp-gen.py').read_text()
        self.assertIn(
            'i18n.t("seccomp.generated", profile=profile, arch=arch, rules=added, bytes=size)',
            src)
        self.assertNotIn('rules={added}', src)
        self.assertNotIn('bytes={size}', src)

        out_zh = Path(self.tmp.name) / 'zh.bpf'
        out_en = Path(self.tmp.name) / 'en.bpf'
        zh_run = self.run_tool('lib/seccomp-gen.py',
                               ['--profile', 'untrusted', '--out', str(out_zh)], 'zh')
        en_run = self.run_tool('lib/seccomp-gen.py',
                               ['--profile', 'untrusted', '--out', str(out_en)], 'en')
        self.assertEqual(zh_run.returncode, 0, zh_run.stderr)
        self.assertEqual(en_run.returncode, 0, en_run.stderr)
        zh_line = zh_run.stderr.strip().splitlines()[-1]
        en_line = en_run.stderr.strip().splitlines()[-1]
        zh_match = re.fullmatch(
            r'seccomp-gen 配置=untrusted arch=(\S+) rules=(\d+) bytes=(\d+)', zh_line)
        en_match = re.fullmatch(
            r'seccomp-gen profile=untrusted arch=(\S+) rules=(\d+) bytes=(\d+)', en_line)
        self.assertIsNotNone(zh_match, zh_run.stderr)
        self.assertIsNotNone(en_match, en_run.stderr)
        self.assertEqual(zh_match.group(1), en_match.group(1))
        self.assertEqual(zh_match.group(2), en_match.group(2))
        self.assertEqual(zh_match.group(3), en_match.group(3))
        self.assertNotIn('{added}', zh_run.stderr + en_run.stderr)
        self.assertNotIn('{size}', zh_run.stderr + en_run.stderr)
        self.assertNotIn('{rules}', zh_run.stderr + en_run.stderr)
        self.assertNotIn('{bytes}', zh_run.stderr + en_run.stderr)
        self.assertNotIn('配置=', en_run.stderr)

    def test_hardcoded_cli_literals_are_gone_and_log_is_english(self):
        supervisor = (REPO / 'lib/service-supervisor.py').read_text()
        seccomp = (REPO / 'lib/seccomp-gen.py').read_text()
        for needle in (
            '未找到 libseccomp（请安装 libseccomp）',
            'compat 需要显式附加限制',
            '未知 seccomp 配置:',
            'help="BPF 输出路径"',
            'seccomp-gen 配置={profile} arch={arch} rules={added}',
        ):
            self.assertNotIn(needle, seccomp, f'seccomp-gen.py still hardcodes {needle!r}')
        self.assertNotIn('ap.error("--pass-fd 必须是大于 stderr 的描述符")', supervisor)
        self.assertIn('i18n.t("supervisor.pass_fd_must_be_gt_stderr")', supervisor)
        # _log is a language-independent English literal, like log_debug; not catalogized.
        for needle in (
            '_log(log, "ready: ok")',
            '_log(log, "ready: timeout")',
            '_log(log, f"stop timed out after {stop_timeout}s → SIGKILL")',
            '_log(args.log, "supervisor: missing child argv")',
            '_log(args.log, f"supervisor: starting {\' \'.join(child[:3])}...")',
            '_log(args.log, "exceeded max restarts after ready failure")',
            '_log(args.log, f"health check failed {fails}/{args.health_retries}")',
            '_log(args.log, "health: giving up → restart/stop")',
            '_log(args.log, "supervisor: stopped")',
            '_log(args.log, f"child exited rc={rc}")',
            '_log(args.log, "exceeded max restarts")',
        ):
            self.assertIn(needle, supervisor, f'_log literal was changed: {needle!r}')
        self.assertEqual(supervisor.count('i18n.t('), 1)
        for old in (
            '_log(log, "ready: 就绪")',
            '_log(log, "ready: 超时")',
            '_log(log, f"停止超时 {stop_timeout}s → SIGKILL")',
            '_log(args.log, "supervisor: 缺少子进程 argv")',
            '_log(args.log, f"supervisor: 启动 {\' \'.join(child[:3])}...")',
            '_log(args.log, "就绪失败后超过最大重启次数")',
            '_log(args.log, f"健康检查失败 {fails}/{args.health_retries}")',
            '_log(args.log, "health: 放弃 → 重启/停止")',
            '_log(args.log, "supervisor: 已停止")',
            '_log(args.log, f"子进程退出 rc={rc}")',
            '_log(args.log, "超过最大重启次数")',
        ):
            self.assertNotIn(old, supervisor, f'Chinese _log text still present: {old!r}')

    def test_supervisor_cli_and_seccomp_errors_follow_lang(self):
        log = Path(self.tmp.name) / 'svc.log'
        pid = Path(self.tmp.name) / 'svc.pid'
        common = ['--name', 'demo', '--log', str(log), '--pidfile', str(pid),
                  '--pass-fd', '1']
        zh = self.run_tool('lib/service-supervisor.py', common, 'zh')
        en = self.run_tool('lib/service-supervisor.py', common, 'en')
        self.assertNotEqual(zh.returncode, 0, zh.stderr)
        self.assertNotEqual(en.returncode, 0, en.stderr)
        self.assertIn('--pass-fd 必须是大于 stderr 的描述符', zh.stderr)
        self.assertIn('--pass-fd must be a file descriptor greater than stderr', en.stderr)
        self.assertIn('错误:', zh.stderr)
        self.assertIn('error:', en.stderr)
        self.assertNotIn('必须是大于', en.stderr)
        self.assertNotIn('must be a file descriptor', zh.stderr)

        zh_help = self.run_tool('lib/service-supervisor.py', ['--help'], 'zh')
        en_help = self.run_tool('lib/service-supervisor.py', ['--help'], 'en')
        self.assertEqual(zh_help.returncode, 0, zh_help.stderr)
        self.assertEqual(en_help.returncode, 0, en_help.stderr)
        self.assertIn('用法:', zh_help.stdout)
        self.assertIn('usage:', en_help.stdout)
        self.assertNotIn('usage:', zh_help.stdout)
        self.assertNotIn('用法:', en_help.stdout)

        # Missing child argv goes through _log; both languages keep the English literal.
        zh_miss = self.run_tool(
            'lib/service-supervisor.py',
            ['--name', 'demo', '--log', str(log), '--pidfile', str(pid)], 'zh')
        en_miss = self.run_tool(
            'lib/service-supervisor.py',
            ['--name', 'demo', '--log', str(log), '--pidfile', str(pid)], 'en')
        self.assertEqual(zh_miss.returncode, 2, zh_miss.stderr)
        self.assertEqual(en_miss.returncode, 2, en_miss.stderr)
        self.assertIn('supervisor: missing child argv', zh_miss.stderr)
        self.assertIn('supervisor: missing child argv', en_miss.stderr)
        self.assertEqual(zh_miss.stderr, en_miss.stderr)
        self.assertNotIn('缺少子进程 argv', zh_miss.stderr + en_miss.stderr)

        zh_err = self.run_tool(
            'lib/seccomp-gen.py',
            ['--profile', 'compat', '--out', str(Path(self.tmp.name) / 'x.bpf')], 'zh')
        en_err = self.run_tool(
            'lib/seccomp-gen.py',
            ['--profile', 'compat', '--out', str(Path(self.tmp.name) / 'x.bpf')], 'en')
        self.assertNotEqual(zh_err.returncode, 0)
        self.assertNotEqual(en_err.returncode, 0)
        self.assertIn('compat 需要显式附加限制', zh_err.stderr)
        self.assertIn('compat requires an explicit extra restriction', en_err.stderr)
        self.assertNotIn('需要显式附加限制', en_err.stderr)

        zh_help = self.run_tool('lib/seccomp-gen.py', ['--help'], 'zh')
        en_help = self.run_tool('lib/seccomp-gen.py', ['--help'], 'en')
        self.assertEqual(zh_help.returncode, 0, zh_help.stderr)
        self.assertEqual(en_help.returncode, 0, en_help.stderr)
        self.assertIn('用法:', zh_help.stdout)
        self.assertIn('BPF 输出路径', zh_help.stdout)
        self.assertIn('为 CapBox untrusted/strict 配置生成 seccomp BPF。', zh_help.stdout)
        self.assertIn('usage:', en_help.stdout)
        self.assertIn('BPF output path', en_help.stdout)
        self.assertIn('Generate a seccomp BPF for a CapBox untrusted/strict profile.',
                      en_help.stdout)
        self.assertNotIn('BPF 输出路径', en_help.stdout)
        self.assertNotIn('用法:', en_help.stdout)


class DaemonStopMarkerTests(unittest.TestCase):
    """Guest writes a fixed English stop marker; host temporarily also accepts the old phrase."""

    MARKER = 'received stop request'
    OLD_PHRASE = '收到停止请求'
    HOST_GREP = "grep -q -e 'received stop request' -e '收到停止请求'"

    def test_guest_emits_english_marker(self):
        guest = (REPO / 'lib/guest/daemon.sh').read_text()
        self.assertIn(
            f'log "{self.MARKER}, waiting for running jobs to finish (limit ${{STOP_WAIT}}s)"',
            guest)
        self.assertNotIn(self.OLD_PHRASE, guest)
        self.assertNotIn('等待在跑任务完成', guest)
        # Marker is a fixed English literal, not catalogized.
        self.assertNotIn('i18n.t', guest)
        self.assertNotRegex(guest, r'i18n_[A-Za-z0-9_]+.*received stop request')

    def test_host_criterion_matches_the_new_marker_and_old_phrase(self):
        host = (REPO / 'lib/daemon.sh').read_text()
        self.assertIn(self.HOST_GREP, host)
        self.assertEqual(host.count('grep -q'), 1)
        self.assertIn(f'会往 daemon.log 写「{self.MARKER}」', host)
        self.assertIn('一次升级兼容', host)
        self.assertIn(f'「{self.OLD_PHRASE}」', host)
        self.assertIn('新服务端只写英文标记', host)

    def test_marker_is_not_a_catalog_key_or_value(self):
        for lang in ('zh', 'en'):
            catalog = i18n.load_catalog(lang)
            self.assertNotIn(self.MARKER, catalog)
            for key, value in catalog.items():
                self.assertNotIn(
                    self.MARKER, key, f'catalog key {key!r} contains marker')
                self.assertNotIn(
                    self.MARKER, value,
                    f'catalog {lang}:{key} contains marker')

    def test_host_grep_matches_new_and_old_guest_lines_only(self):
        log_prefix = '[capbox-daemon] '
        guest_line = (
            f'{log_prefix}{self.MARKER}, waiting for running jobs to finish (limit 30s)\n'
        )
        old_line = f'{log_prefix}{self.OLD_PHRASE}，等待在跑任务完成（上限 30s）\n'
        other_line = (
            f'{log_prefix}received termination signal (TERM/INT), preparing graceful shutdown\n'
        )
        warn_line = 'Server did not acknowledge the stop request within 5s\n'

        def greps(text):
            result = subprocess.run(
                ['grep', '-q', '-e', self.MARKER, '-e', self.OLD_PHRASE],
                input=text, text=True, capture_output=True)
            return result.returncode

        self.assertEqual(greps(guest_line), 0)
        self.assertEqual(greps(old_line), 0)
        self.assertEqual(greps(other_line), 1)
        self.assertEqual(greps(warn_line), 1)



class LogDebugEnglishTests(unittest.TestCase):
    """Remaining log_debug and supervisor _log lines are English literals, not catalog keys."""

    CJK = re.compile(r'[\u4e00-\u9fff]')
    LOG_DEBUG_FILES = {
        'lib/common.sh': (
            'log_debug "host has no flock, skipping lock: $name"',
            'log_debug "refreshed $dst"',
            'log_debug "$distro rootfs has no CA certificates, falling back to http mirror: $url"',
            'log_debug "daemon heartbeat expired (${age}s > ${ttl}s), treating as not running"',
            'log_debug "daemon already exited before stop (rc=3), continuing cleanup"',
        ),
        'lib/fsguard.sh': (
            'log_debug "rootfs: overlay RW upper=$u (lower layer RO)"',
        ),
        'lib/landlock.sh': (
            'log_debug "Landlock prefix added helper=$helper"',
        ),
        'lib/resources.sh': (
            'log_debug "DISK_MAX applied: $bytes -> guest:$guest via state loop (priv=$mode)"',
            'log_debug "resource limits applied via cgroup: $cg (mem=${CAPBOX_RESOURCES_APPLIED_MEMORY:-} cpu=${CAPBOX_RESOURCES_APPLIED_CPU:-} pids=${CAPBOX_RESOURCES_APPLIED_PIDS:-})"',
        ),
        'lib/rootfs.sh': (
            'log_debug "tar --numeric-owner failed (rc=$rc), retrying without it"',
            'log_debug "injected proxy file: $prof"',
            'log_debug "no bootstrap.sh, skipping first-boot bootstrap"',
        ),
    }
    ENGLISH_LITERALS = (
        'host has no flock, skipping lock:',
        'rootfs has no CA certificates, falling back to http mirror:',
        'daemon heartbeat expired',
        'daemon already exited before stop (rc=3), continuing cleanup',
        'Landlock prefix added helper=',
        'DISK_MAX applied:',
        'resource limits applied via cgroup:',
        'tar --numeric-owner failed',
        'injected proxy file:',
        'no bootstrap.sh, skipping first-boot bootstrap',
        'ready: ok',
        'ready: timeout',
        'stop timed out after',
        'supervisor: missing child argv',
        'supervisor: starting',
        'exceeded max restarts after ready failure',
        'health check failed',
        'health: giving up → restart/stop',
        'supervisor: stopped',
        'child exited rc=',
        'exceeded max restarts',
    )

    def _prod_files(self):
        skip_parts = {'.git', 'os', 'logs', 'state', 'test', '__pycache__'}
        for path in REPO.rglob('*'):
            if not path.is_file():
                continue
            rel = path.relative_to(REPO)
            if any(part in skip_parts for part in rel.parts):
                continue
            if path.suffix in {'.sh', '.py'} or path.name == 'capbox':
                yield path, rel

    def test_log_debug_literals_are_english_and_not_catalogized(self):
        for rel, needles in self.LOG_DEBUG_FILES.items():
            text = (REPO / rel).read_text()
            for needle in needles:
                self.assertIn(needle, text, f'missing {needle!r} in {rel}')
                self.assertNotIn('i18n_get', needle)
                self.assertNotIn('i18n_fmt', needle)
                self.assertNotIn('i18n.t', needle)
                self.assertNotIn('i18n_t', needle)

    def test_english_log_strings_are_not_catalog_keys(self):
        for lang in ('zh', 'en'):
            catalog = i18n.load_catalog(lang)
            self.assertEqual(len(catalog), 1154)
            for literal in self.ENGLISH_LITERALS:
                self.assertNotIn(literal, catalog)
                for key, value in catalog.items():
                    self.assertNotIn(
                        literal, key,
                        f'catalog key {key!r} contains log literal {literal!r}')
                    self.assertNotIn(
                        literal, value,
                        f'catalog {lang}:{key} contains log literal {literal!r}')

    def test_no_chinese_remains_in_log_debug_or_supervisor_log_arguments(self):
        found = []
        for path, rel in self._prod_files():
            lines = path.read_text(encoding='utf-8').splitlines()
            i = 0
            while i < len(lines):
                raw = lines[i]
                stripped = raw.lstrip()
                if (stripped.startswith('#')
                        or stripped.startswith('def _log')
                        or stripped.startswith('log_debug()')):
                    i += 1
                    continue
                if (re.search(r'\b(log_debug|_log)\s*(\(|")', raw)
                        or re.search(r'\b_log\(', raw)):
                    block = [raw]
                    j = i

                    def unclosed(s):
                        esc = in_dq = in_sq = False
                        for ch in s:
                            if esc:
                                esc = False
                                continue
                            if ch == '\\':
                                esc = True
                                continue
                            if not in_sq and ch == '"':
                                in_dq = not in_dq
                            elif not in_dq and ch == "'":
                                in_sq = not in_sq
                        return in_dq or in_sq

                    blob = '\n'.join(block)
                    opens = blob.count('(') - blob.count(')')
                    while (opens > 0 or unclosed(blob)) and j + 1 < len(lines):
                        j += 1
                        block.append(lines[j])
                        blob = '\n'.join(block)
                        opens = blob.count('(') - blob.count(')')
                    if self.CJK.search(blob):
                        found.append(f'{rel}:{i + 1}: {blob.strip()}')
                    i = j + 1
                    continue
                i += 1
        self.assertEqual(
            found, [],
            'Chinese remains in log_debug/_log arguments:\n' + '\n'.join(found))



class GuestDaemonLogEnglishTests(unittest.TestCase):
    """Guest daemon.sh log lines are English literals and are not catalogized."""

    CJK = re.compile(r'[\u4e00-\u9fff]')
    GUEST = 'lib/guest/daemon.sh'
    LOG_LITERALS = (
        'log "received termination signal (TERM/INT), preparing graceful shutdown"',
        'log "unable to create IPC directory: $D (is /workspace bound into the container?)"',
        'log "a daemon is already running (heartbeat fresh, ${_hb_age}s ago), this instance exiting"',
        'log "found stale lock (heartbeat stale for ${_hb_age}s), taking over"',
        'log "unable to acquire daemon lock, exiting"',
        'log "daemon started (pid=$$ hostname=$HOSTN distro=$DISTRO max jobs=$MAXJOBS tick=${TICK}s)"',
        'log "IPC directory: $D"',
        'log "cancelled timed-out request $_kid (process group $_kpg)"',
        'log "concurrency at max $MAXJOBS, deferring new requests this tick"',
        'log "received stop request, waiting for running jobs to finish (limit ${STOP_WAIT}s)"',
        'log "jobs still running at drain limit ${STOP_WAIT}s, forcing exit (those requests will be cancelled)"',
        'log "daemon exiting (ran $(( $(_now) - STARTED ))s, processed $TICKN ticks)"',
    )
    # Distinctive phrases checked against catalog keys/values. Omit
    # "IPC directory:" because the host catalog already has daemon.ipc_directory.
    ENGLISH_LITERALS = (
        'received termination signal (TERM/INT), preparing graceful shutdown',
        'unable to create IPC directory:',
        'a daemon is already running (heartbeat fresh,',
        'found stale lock (heartbeat stale for',
        'unable to acquire daemon lock, exiting',
        'daemon started (pid=',
        'cancelled timed-out request',
        'concurrency at max',
        'waiting for running jobs to finish (limit',
        'jobs still running at drain limit',
        'daemon exiting (ran',
    )

    def test_guest_daemon_log_literals_are_english_and_not_catalogized(self):
        text = (REPO / self.GUEST).read_text()
        for needle in self.LOG_LITERALS:
            self.assertIn(needle, text, f'missing {needle!r} in {self.GUEST}')
            self.assertNotIn('i18n_get', needle)
            self.assertNotIn('i18n_fmt', needle)
            self.assertNotIn('i18n.t', needle)
        self.assertNotIn('i18n.t', text)
        self.assertNotRegex(text, r'\bi18n_[A-Za-z0-9_]+\b')
        bootstrap = (REPO / 'lib/guest/bootstrap.sh').read_text()
        for needle in self.LOG_LITERALS:
            self.assertNotIn(needle, bootstrap)

    def test_guest_daemon_log_strings_are_not_catalog_keys(self):
        for lang in ('zh', 'en'):
            catalog = i18n.load_catalog(lang)
            self.assertEqual(len(catalog), 1154)
            for literal in self.ENGLISH_LITERALS:
                self.assertNotIn(literal, catalog)
                for key, value in catalog.items():
                    self.assertNotIn(
                        literal, key,
                        f'catalog key {key!r} contains guest log literal {literal!r}')
                    self.assertNotIn(
                        literal, value,
                        f'catalog {lang}:{key} contains guest log literal {literal!r}')

    def test_no_chinese_remains_in_guest_daemon_log_arguments(self):
        text = (REPO / self.GUEST).read_text()
        found = []
        for i, line in enumerate(text.splitlines(), 1):
            stripped = line.lstrip()
            if stripped.startswith('#'):
                continue
            if re.search(r'\blog\s+"', line) and self.CJK.search(line):
                found.append(f'{self.GUEST}:{i}: {line.strip()}')
        self.assertEqual(
            found, [],
            'Chinese remains in guest daemon log arguments:\n' + '\n'.join(found))
        self.assertIn('received stop request', text)
        self.assertNotIn('收到停止请求', text)



if __name__ == '__main__':
    unittest.main()
