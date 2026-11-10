#!/usr/bin/env python3
"""Generate command/default references and reject drift in documented contracts."""
import argparse
import difflib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
errors = []


def write_or_check(path, text):
    path = REPO / path
    previous = path.read_text() if path.exists() else ''
    if args.check:
        if previous != text:
            errors.append(str(path.relative_to(REPO)) + ': generated content is stale')
            print(''.join(difflib.unified_diff(previous.splitlines(True), text.splitlines(True),
                                              fromfile=str(path), tofile='generated'))[:4000])
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


with tempfile.TemporaryDirectory(prefix='capbox-docs-') as temporary:
    workspace = Path(temporary)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('CAPBOX_', '_CAPBOX_'))}
    env.update(CAPBOX_DIR=str(workspace / '.capbox'), CAPBOX_WORKSPACE=str(workspace))
    # 文档不随 locale 切换：cli-reference 固定以中文生成。
    help_env = dict(env, CAPBOX_LANG='zh')

    def cli(*command):
        return subprocess.check_output([str(REPO / 'bin/capbox'), '--root', str(workspace),
                                        *command], env=help_env, text=True)

    version = cli('version').split()[-1]
    count = len(list((REPO / 'test/cases').glob('t[0-9][0-9].sh')))
    sections = [('# CLI 参考\n\n由 `python3 tools/generate-docs.py` 生成；'
                 f'不要手改命令输出。CLI 版本：**{version}**。'
                 '本文件固定以 `CAPBOX_LANG=zh` 生成，不随 locale 切换'
                 '（仓库文档政策：README.md 英文，README.zh-CN.md 与 docs/ 中文）。\n')]
    for command in [('--help',), ('init', '--help'), ('upgrade', '--help'),
                    ('recipe', '--help'), ('image', '--help'), ('service', '--help'),
                    ('task', '--help'), ('task', 'start', '--help'),
                    ('policy', '--help'), ('setup', '--help'), ('bundle', '--help'), ('mcp', '--help'),
                    ('audit', '--help'), ('audit', 'report', '--help'), ('pkg', '--help')]:
        sections.append('\n## capbox ' + ' '.join(command) + '\n\n```text\n' +
                        cli(*command).rstrip() + '\n```\n')
    write_or_check('docs/cli-reference.md', ''.join(sections))
    raw = subprocess.check_output(['bash', '-c',
        'source "$1/lib/common.sh"; for k in "${CAPBOX_CFG_KEYS[@]}"; do '
        'printf "%s\\0" "$k"; _cfg_value_for_file "$k"; printf "\\0"; done',
        'generate-defaults', str(REPO)], env=env)
    fields = raw.decode().split('\0')[:-1]
    defaults = dict(zip(fields[::2], fields[1::2]))
    text = ('# 配置默认值\n\n由 `lib/config.sh` 生成；CLI 版本：'
            f'**{version}**。下列为裸初始化默认值。显式 `--agent` '
            '与 `--trusted` 预设会覆盖各自的四项设置。空额度表示 '
            '**尚未配置额度**。\n\n| 键 | 默认值 |\n|---|---|\n')
    for key, value in defaults.items():
        text += f'| `CAPBOX_{key}` | `{json.dumps(value, ensure_ascii=False)}` |\n'
    text += ('\n优先级：内置默认 < config.env < 显式环境变量。'
             '`ALLOW_OLD_BWRAP` 不能通过环境变量打开。'
             '配置文件与配方按数据解析，从不 source。\n'
             '\n`CAPBOX_LANG` 可选 `zh` / `en` 及其区域形式（如 `zh_CN`、`en_US`）。'
             '进程环境变量优先于 `config.env`，再才是 locale。'
             '未设置时：仅 `zh_CN`、`zh_CN.*` 与纯 `zh`（含 `zh.UTF-8`）为中文；'
             '其余（含未设置、`C`、`C.UTF-8`、`en_US`、`zh_TW`、`zh_HK`）为英文。'
             '非法值以固定中英各一句报错并退出。'
             '`docs/cli-reference.md` 始终以 `CAPBOX_LANG=zh` 生成，不随 locale 切换。\n')
    write_or_check('docs/configuration.md', text)
    for name in ['README.md', 'README.zh-CN.md', 'CONTRIBUTING.md']:
        path = REPO / name
        text = path.read_text()
        chinese = name != 'README.md'  # README.md English; README.zh-CN.md + CONTRIBUTING Chinese
        if '<!-- generated:version -->' in text:
            line = (f'开发中的 CLI：**{version}**。正式版本与迁移说明见 '
                    '[Releases](https://github.com/Sladewww/capbox/releases)。' if chinese else
                    f'Development CLI: **{version}**. Published releases and their migration notes '
                    'are listed in [Releases](https://github.com/Sladewww/capbox/releases).')
            text = re.sub(r'<!-- generated:version -->.*?<!-- /generated:version -->',
                          '<!-- generated:version -->\n' + line + '\n<!-- /generated:version -->',
                          text, flags=re.S)
        if name == 'CONTRIBUTING.md':
            line = f'验收用例：**{count}**（T01–T{count:02}）。以 `./test/run.sh --list` 的实际清单为准，不硬编码旧数量。'
        elif chinese:
            line = f'验收用例：**{count}**（T01–T{count:02}）。框架自测验证测试工具；真实 guest 与宿主边界回归单独运行。'
        else:
            line = (f'Acceptance cases: **{count}** (T01–T{count:02}). Framework selftests '
                    'validate the test harness; real guest and host-boundary regressions run separately.')
        text = re.sub(r'<!-- generated:tests -->.*?<!-- /generated:tests -->',
                      '<!-- generated:tests -->\n' + line + '\n<!-- /generated:tests -->',
                      text, flags=re.S)
        write_or_check(name, text)
    # Standalone fallback entry points and the fake CLI cannot import the full runtime.
    for name in ['lib/daemon.sh', 'lib/guest/daemon.sh', 'lib/guest/bootstrap.sh']:
        values = re.findall(r'CAPBOX_VERSION:([-=])([0-9.]+)', (REPO / name).read_text())
        if not values or any(value != version for _, value in values):
            errors.append(name + ': standalone version fallback is stale')
    fake_version = re.search(r'^VERSION="([0-9.]+)"$',
                            (REPO / 'test/selftest/fake-cli/capbox').read_text(), re.M)
    if not fake_version or fake_version[1] != version:
        errors.append('fake CLI version is stale')
    if f'assert_out_contains "{version}"' not in (REPO / 'test/cases/t01.sh').read_text():
        errors.append('T01 version assertion is stale')
    # Parse Shell examples without executing user-facing setup or cleanup commands.
    documents = [REPO / name for name in ['README.md', 'README.zh-CN.md', 'CONTRIBUTING.md']]
    documents += list((REPO / 'docs').glob('*.md'))
    for path in documents:
        text = path.read_text()
        for number, match in enumerate(re.finditer(r'^```(?:sh|bash)\s*\n(.*?)^```',
                                                   text, re.M | re.S), 1):
            result = subprocess.run(['bash', '-n'], input=match[1], text=True,
                                    capture_output=True)
            if result.returncode:
                errors.append(f'{path.name} block {number}: {result.stderr.strip()}')
        for target in re.findall(r'\]\(([^)]+)\)', text):
            if re.match(r'^(?:https?://|mailto:|#)', target):
                continue
            file = target.split('#')[0]
            if not (path.parent / file).exists():
                errors.append(f'{path.name}: broken local link {target}')

if errors:
    raise SystemExit('\n'.join(errors))
print(('Checked' if args.check else 'Generated') + ' CLI/default references, versions, links and Shell examples')
