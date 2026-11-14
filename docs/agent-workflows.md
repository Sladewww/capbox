# 本地 Agent 工作流

`task` 与 `policy` 需要宿主 Python 3.10+，并走普通 CapBox exec 启动器。guest 命令得到与 `exec` 相同的命名空间、清环境、配置与资源检查。任务有自己的宿主监督器；不需要先 `capbox up`。

## 启动、重连与取消

在已初始化的项目中执行。响应是 schema `capbox.agent.v1` 的 JSON；请保存其中的 `task_id`：

```sh
capbox task start --timeout 600 --net none -- sh -c 'echo started; sleep 2; echo done'
# 把 TASK_ID 换成响应里的 task_id：
capbox task list --json
capbox task status TASK_ID
capbox task logs TASK_ID --stream stdout --offset 0 --limit 65536 --json
capbox task attach TASK_ID
capbox task wait TASK_ID --timeout 30
capbox task cancel TASK_ID
capbox task rm TASK_ID
```

`start` 在监督器确认提交后返回；命令准备仍可能失败。用 `wait`/`status` 看实际退出码。`wait` 与 `attach` 返回任务退出码：执行超时 124，显式取消 143，监督器状态丢失 125。**客户端 wait** 超时也返回 124，但不会取消任务。`cancel` 只确认收到请求；用 `wait` 确认结束。运行中的任务不能被删除或在其下升级。

任务执行截止从监督器启动算起，含 CLI 启动。准备/拷贝隔离工作区在该截止之前。超时会取消 CLI 进程组，宽限期后升为 SIGKILL。子 CLI 有父进程死亡处理；监督器死亡记为 `lost`，绝不当成功。运行时目录或外层宿主会话被删仍可能结束任务。分离运行逃不出外层工具/容器监督器。这不是重启存活，也不是内存检查点。

任务元数据、原始命令参数与日志是工作区外的私有宿主数据，与其它控制记录同属经验证的运行时层级。其中可能含敏感命令输出。不会自动发布。第一版在 `task rm` 前保留已完成任务；若原始输出或补丁需在宿主运行时清理后保留，请显式导出。已记录的任务终态与请求策略可用 [audit query](audit-reports.md#按任务-id-查询与导出) 从项目审计流查询。`lost` 记录需人工确认宿主会话，不会自动删除。

### 输出约定

- `start`、`list`、`status`、`wait`、`cancel`、`rm` 与 policy 命令输出 JSON。适用处可显式加 `--json`。
- `logs --json` 返回 `stream`、`offset`、`next_offset`、`data_base64`。偏移是该流上的**字节**，不是字符，也不是全局事件号。人类可读的 `logs` 写出选定流原文。
- `attach --json` 先发 JSONL 输出事件，再发退出事件。用 `--stdout-offset` / `--stderr-offset` 续读。人类 attach 保持 stdout/stderr 分离。stderr 可含启动器诊断与 guest stderr。
- 默认每路流只保留前 **8MiB**。监督器继续排空多余字节，完成时报告 `dropped_bytes`。`--max-output-bytes` 允许每路 0–64MiB。单次 `logs` 最多读 1MiB。偏移相对保留数据。
- 每项目最多 8 个活动任务。restricted 网络任务使用独立的代理/桥会话名。共享项目任务仍共用可变 rootfs 与工作区；冲突写入请用隔离或串行化。

## 解释请求的启动策略

```sh
capbox policy show --json
capbox policy show --profile strict --net none
capbox policy check --net restricted https://example.com/
capbox policy check --net restricted --resolve https://example.com/
```

策略针对**新的 oneshot**，不是已在跑的 daemon。每个值标明来源（`default`、`file`、`env`、`command`，或由配置派生的默认）。内容含配置、网络、身份、rootfs/overlay 与请求的资源额度。它不声称请求的资源限额已生效：仍由普通启动检查决定。任务状态保留提交时的策略，即使项目配置后来变了。

网络检查复用代理的实际 host/port 与私有 IP 规则。只接受无 userinfo 的 HTTP(S) 目标；不回显 URL 路径、query 与凭据。没有 `--resolve` 时，白名单匹配是**有条件的**，因为尚未查 DNS。`--resolve` 显式查 DNS；不建 TCP 连接。DNS 与连通性可变，代理在连接时会再校验地址。`open` 报告共享宿主网络，不代表连通成功。拒绝退出码 1；用法错误退出码 2。

这些是确定性策略预览，不是完整的系统调用拒绝跟踪器。它们不改配置，也不自动学习放行规则。`pkg install/update` 的网络例外仍会显式报告。

## 隔离工作区与可审阅 diff

`--isolate` 把当前工作区视图拷进私有任务树，并做独立 rootfs 副本（不硬链到活动镜像）。对 Git 仓库根，包含已跟踪工作树内容**以及**仍被 `.gitignore` 允许的未跟踪文件；CapBox 凭据排除规则始终优先。对非 Git 目录只遍历普通文件（无 `.gitignore`）。非空 overlay upper 合并进私有 rootfs（copy-up + whiteout），而不是拒绝。拷贝活动 rootfs 前请停其它写入方、服务与 daemon；不做在线数据库一致性保证。

```sh
task_id=$(capbox task start --isolate --net none -- sh -c 'printf "task result\n" > task-result.txt' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["task_id"])')
capbox task wait "$task_id"
capbox task diff "$task_id" --json
patch_file=$(mktemp)
capbox task diff "$task_id" > "$patch_file"
printf 'Review patch: %s\n' "$patch_file"
# 审阅/导出结果后：
capbox task rm "$task_id"
```

MVP 导出支持二进制的 Git 补丁；**不会应用到原项目**。JSON 含 `changed_files`、`origin_changed`、`patch_base64`。读补丁、核对源基线并解决冲突后，再用你平时的 Git 审阅/应用流程。源基线被删或改、可执行位变化、或源文件与任务新建文件冲突都会报告。预览不是对未来原子应用的授权。

支持范围与限制：

- Git 根拷贝已跟踪 + 未忽略的未跟踪普通工作树文件；非 Git 项目只按 CapBox 排除规则遍历目录（无 `.gitignore`）。从不拷贝 Git 历史/配置。源路径相对钉死的目录描述符打开，不跟随链接。
- 排除 `.capbox`、`.git`、常见凭据路径（`.env`、`.env.*`、`.secrets`、`.ssh`、`.aws`、`.azure`、`.gnupg`、`.kube`、`.docker`）、PEM/密钥文件与 `id_rsa*`。无法识别全部密钥；提交前请审阅已跟踪文件。`.gitignore` 不是保密规则。
- 不支持符号链接、硬链接、特殊文件与子模块目录。枚举与 diff 会拒绝这类内容，而不是跟着链接进宿主。宿主 Git 使用 guest 外的私有元数据，并禁用外部 diff/textconv 与 hooks。
- 工作文件集上限 10,000 文件 / 100MiB；导出补丁上限 16MiB。非空 overlay upper 合并进私有 rootfs；宿主 upper 不动。rootfs 副本额外占盘与启动时间。是全量拷贝，不是瞬时快照；既有磁盘配额仍只覆盖其配置的 guest 数据路径。
- 脏 isolate 快照当前脏树；`task diff` 相对该快照基线，不是相对 `HEAD`。非 Git isolate 为此建合成裸索引。
- `diff` 仅在隔离任务结束后可用。`lost` 任务不能自动导出。私有 rootfs 上的改动可丢弃，不属于工作区补丁。
- 既有 exec/文件/绑定设置仍生效。指向原工作区的绝对绑定在私有副本中可能无效；不会静默授权访问源。

补丁应用仍留给可信宿主调用方。密钥不能进 guest 时，用 [宿主凭据代理](credentials.md)。可选的 [stdio MCP 适配器](envkit.md) 暴露本 CLI 的固定子集；不开网络监听。
