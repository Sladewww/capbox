# 本机实时监控

在 Linux 宿主机上用 Python 3.10+ 启动。指定一个已初始化的 CapBox 项目目录。已有工作区的项目 CLI 需要支持 `service status NAME --json`。可用 `capbox --root PROJECT upgrade check --from TEMPLATE` 检查版本。

```sh
python3 tools/monitor.py --root /path/to/project
```

打开 [http://127.0.0.1:8765/](http://127.0.0.1:8765/)。用 `--port` 更换端口。按 Ctrl+C 停止。后台只监听 IPv4 回环地址。同一宿主机上能够访问此端口的进程也能读取监控数据。

| 面板 | 数据来源 | 采样间隔 |
| --- | --- | --- |
| 概览 | `status --json` | 15 秒 |
| 资源限制 | `metrics --json` | 15 秒 |
| 任务和服务 | `task list --json` 与 `service status NAME --json` | 2 秒 |
| 审计事件 | `.capbox/logs/audit.jsonl` | 1 秒 |
| 实时用量 | 显式指定的 cgroup v2 目录 | 1 秒 |

浏览器通过 SSE 接收最新快照。采集失败时保留最后一次成功读数，并在面板上标记失败。页面最多显示最近 100 个任务和 100 条审计事件。审计只显示时间、类型、结果、退出码和耗时。任务与服务日志仍可通过现有的 `capbox task logs` 和 `capbox service logs` 查看。

要采集 CPU、内存和 PID 用量，追加 `--cgroup /sys/fs/cgroup/…` 并选择该工作区独占的 cgroup v2 目录。可从本工作区的 `resources` 审计事件的 `detail` 字段查到启动时分配的 cgroup 路径。用量对应指定目录，按不同 cgroup 启动的多个实例需分别采集。CPU 百分比以一个逻辑核为 100%，第一帧需要等待第二次采样。没有指定目录时，用量显示不可用。资源限制展示工作区配置值，是否实际生效取决于该实例启动时的资源配置与宿主机权限。
