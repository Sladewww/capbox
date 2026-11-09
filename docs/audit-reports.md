# 离线审计报告

需要宿主 Python 3.10+。生成或查看报告不需要服务、前端安装或网络。

```sh
mkdir -p "$HOME/capbox-reports"
capbox audit report --output "$HOME/capbox-reports/audit.html"
# 显式覆盖已有普通报告：
capbox audit report --output "$HOME/capbox-reports/audit.html" --force
```

在浏览器中打开 HTML。数据、样式与脚本均已嵌入。搜索、UTC 日期/类型/状态筛选、排序、分页、事件详情与筛选后的 JSON 导出在本地完成。趋势、类型分布与卡片同步更新。Escape 关闭详情；窄屏也可用。打印包含当前表格页。

## 选择导出范围

```sh
capbox audit report --output /path/outside/project/failures.html \
  --since 2026-11-08 --until 2026-11-09 \
  --kind exec --status fail --limit 5000 --json
capbox audit report --input /path/to/archived-audit.jsonl \
  --output /path/outside/project/archive.html
```

`--since` 含当日起点，`--until` 不含。日期表示 UTC 午夜；带时间的值必须带时区，例如 `2026-11-08T10:00:00+08:00`。可重复 `--kind` / `--status` 指定多个允许值。浏览器结束日筛选包含该整日 UTC。`--json` 打印生成元数据、覆盖范围与输出路径。

默认源是项目的 `logs/audit.jsonl`。默认源缺失时生成明确的空报告；显式 `--input` 缺失则失败。报告不会开启采集、不会执行已记录命令、不会收集新遥测，也不改源文件。采集仍由既有 `AUDIT` / `AUDIT_CMD` 控制。

只包含选定的 JSONL。其它项目、轮转文件与私有隔离任务副本不会自动汇总。事件数不是任务数：一次执行可产生多条策略/资源/exec 记录。报告不加任务关联 ID，也不声称未记录事件成功。

## 覆盖与统计

- 最多扫描源文件初始大小末尾的 **32MiB**。丢弃首条不完整记录。不无限追赶并发追加。
- 默认按文件顺序保留最后 **5,000** 条匹配记录；`--limit` 接受 1–20,000。展示顺序按时间戳。乱序时间戳不改变保留集。
- 超过 **64KiB** 的行、非法 JSON/UTF-8、重复键、必填字段非法、非 JSON 常量会被跳过。不完整尾行跳过并计入。记录需要 `ts`、`kind`、`status` 与带时区的时间戳。
- 已知文本字段在脱敏后截断到 **2,048** 字符。非法可选数字省略并计数。未知字段不嵌入。嵌入 JSON 上限 **32MiB**；超限时缩小记录/时间窗口。
- 失败指 `status=fail` 或记录的退出码非零；警告用 `status=warn`。start/stop/skip 不自动等于成功。近似秩 P95 只用带有效 `ms` 的 **exec** 记录；缺时长就缺。

覆盖信息记录源/扫描大小、丢弃前缀、省略的匹配记录、畸形/过大/不完整记录以及非法/截断/脱敏字段。这些计数描述扫描窗口；可见统计描述当前筛选下的保留事件。报告是有界观察，不是完整性或真实性证明。

## 文件与敏感数据

输出必须在**工作区外**，且父目录已存在。以私有模式 `0600` 创建。已有文件需要 `--force`；符号链接、特殊输出文件、以及输出与输入别名同一路径会被拒绝。源路径与祖先不得是符号链接；源必须是普通文件。发布是原子的，默认不替换。

嵌入 JSON 已转义，事件内容只用纯文本 DOM 操作。基于哈希的 Content Security Policy 只允许报告自身的 script/style，并禁止连接/外部资源。看起来像 HTML 的日志文本按数据显示。

常见凭据赋值/开关、Bearer/Basic 值与 HTTP URL userinfo 会再做尽力脱敏。无法识别全部密钥或机密路径。**即使浏览器筛选藏住了行，HTML 仍含保留数据。** JSON 导出只含当前匹配；原始 HTML 不变。分享前请审阅。本地报告不是上传，也不是签名审计归档。

## 开发检查

```sh
python3 test/security/test_audit_report.py
npm ci --prefix test/browser --ignore-scripts --no-audit --no-fund
test/browser/node_modules/.bin/playwright install chromium
npm --prefix test/browser test
```

钉死的浏览器依赖仅用于测试。Chromium 打开真实 `file://` 报告，覆盖筛选/详情/分页/下载/移动布局、惰性敌对文本、CSP 与零网络请求。用户除日常浏览器外，不需要再装浏览器包。
