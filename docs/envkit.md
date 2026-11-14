# 环境工具（setup、bundle、MCP）

这些命令需要宿主 Python 3.10+。它们建立在 [运行时升级](upgrades.md)、[严格包锁](package-locks.md) 与 [本地任务](agent-workflows.md) 之上。

## 1. 检查安装与升级需求

在模板或已初始化项目上：

```sh
capbox setup check --json
capbox setup check --probe --json
capbox setup plan --json
capbox --root /path/to/project setup plan --from /path/to/new-template --json
```

`setup check` 报告宿主、架构、依赖及最低版本。JSON 保留 `dependencies_ready`，它只衡量必选依赖。新增 `checks` 给出 bwrap 状态和 rootfs 准备情况。rootfs 缺失时，按 `capbox init --distro …` 准备，再运行 `capbox doctor`。

`--probe` 额外验证当前会话的用户命名空间、按配置需要的隔离网络命名空间，以及现有 cgroup v2 委派。宿主拒绝时显示 bwrap 的错误，便于检查 AppArmor、user namespace 或外层容器策略。cgroup 检查创建并移除临时子 cgroup，检查额度对应的控制器文件，不启用控制器；实际额度是否可兑现仍以真实启动为准。strict/Landlock 使用的静态 C 工具链也在此模式下检查，编译产物留在临时目录并销毁。

`python-safe-extract` 组件检查安全导入器的 Python 能力（`tarfile.data_filter` 与 `os.path.ALLOW_MISSING`）。请保持 Python 安全更新；较旧的 3.10+ 补丁版仍可能缺这些能力，此时 bundle restore 会失败关闭。

`setup plan` 为识别到的 Debian/Ubuntu、Alpine、Fedora/RHEL、Arch 家族输出包管理器 argv。它从不执行安装器、不下载脚本、不改 AppArmor/sysctl、不授予特权。包可用性与 bubblewrap 版本随发行版变化；审阅提议命令，自行完成合适的宿主安装，再重复 check。包管理器计划是指引，不是额外测试过的宿主矩阵。

带 `--from` 时，计划含既有 upgrade check/apply/rollback 命令。即使检查的是旧项目运行时，setup 与 upgrade 也使用新模板代码。应用运行时升级前，用旧 CLI 停掉 service、daemon、task 与其它 exec。私有备份与回滚协议不变。

## 2. 入门配方与严格重放

`recipes/` 下附带三份入门配方：Python、Node 与原生构建工具。模板在项目外时请用完整路径：

```sh
capbox recipe check /path/to/template/recipes/python.recipe
capbox recipe apply /path/to/template/recipes/python.recipe
capbox image lock save
capbox image lock verify
# 精确包版本；版本不可用则失败：
capbox recipe apply --locked /path/to/package.lock /path/to/template/recipes/python.recipe
```

入门配方是初始包选择，不是已锁定环境。任务资源额度需显式配置。`recipe export FILE` 返回已校验的 `capbox.recipe.v1` JSON，不 source、不执行配方。严格包重放仍依赖软件源上的版本可用性；已准备好的 rootfs 需要离线搬运时用 bundle。

## 3. 可携带、内容锁定的环境包

打包前停掉写入方。选择**工作区外的新目录**：

```sh
capbox bundle pack /path/outside/project/python-environment --recipe /path/to/template/recipes/python.recipe
capbox bundle verify /path/outside/project/python-environment
capbox bundle check /path/outside/project/python-environment
```

bundle 含固定文件名：

| 文件 | 用途 |
|---|---|
| `manifest.json` | bundle schema、发行版、宿主架构、源运行时版本、可携带配置与各产物 SHA256 |
| `rootfs.tar.gz` | 当前物理 rootfs 完整归档 |
| `package.lock` | 已装包名与精确版本 |
| `recipe.env` | 规范可携带配置，`INIT=0` |

pack 会拒绝仍在跑的受管负载、非空 overlay upper 与绝对宿主 bind 规格。其它直接 exec 与外部写入也须停掉。它捕获物理 rootfs，不是合并后的 overlay，也不是在线数据库快照。业务工作区文件不进此归档。配置凭据/代理、宿主特有 bwrap 路径与 UID 映射范围不拷进可携带配方。若提供的配方请求不可携带宿主设置，或与当前环境不符，打包失败。

**rootfs 本身可能含凭据、代理文件、缓存或应用数据。** 分享前请检查并清理。产物私有创建，不会自动上传。哈希提供内容完整性，不是发布者认证。pack 打印 manifest digest；经可信渠道保存该 digest，并在 check/restore 时钉住：

```sh
capbox bundle verify /path/to/environment --manifest-sha256 SHA256_FROM_PACK
```

`verify` 在报告成功前检查 schema、发行版、架构、哈希、规范配方与归档路径/类型。`check` 额外比对活动包清单与可携带配置，漂移则非零退出。两者都不会静默更新锁或安装更新包。

### 恢复到全新目标

使用尚无 rootfs 的全新独立项目，并先选好 bundle 的发行版。以 Alpine 为例：

```sh
capbox --root /path/to/fresh-project bootstrap
capbox --root /path/to/fresh-project config set SECURITY_PROFILE untrusted
capbox --root /path/to/fresh-project config set NET none
capbox --root /path/to/fresh-project config set IDMAP off
capbox --root /path/to/fresh-project config set RESOURCES_MODE require
capbox --root /path/to/fresh-project bundle restore /path/to/environment --manifest-sha256 SHA256_FROM_PACK
capbox --root /path/to/fresh-project bundle check /path/to/environment
```

Ubuntu 还需在 restore 前设 `DISTRO=ubuntu`。项目目录必须已存在。目标必须是全新的；已有 rootfs 数据不会被替换。输入拷到私有暂存区，再校验，经过滤的镜像导入器解压。归档发布是原子的、不替换。恢复后的包清单经 untrusted、无网络、单 UID 启动检查；失败只删除新提升的 rootfs。

目标安全与资源配置保留。`config_applied` 为 false。显式应用源设置前，先审阅 `configuration_drift` 与附带的 `recipe.env`；不要为了压掉漂移报告而导入更松的配置。工作区数据、运行时安装、宿主委派与内核支持仍是各自独立的问题。

bundle 使用既有安全镜像解压语义（含权限/属主净化）；不承诺 ACL、属主、构建结果或运行进程状态逐位相同。限制：每产物 4GiB、声明展开数据 8GiB、归档成员 200,000。原子目录提升需要 Linux `renameat2`。请按此规划磁盘与拷贝时间。

## 4. 固定范围的 stdio MCP 适配器

先初始化并准备项目 rootfs。以非 root 用户从工作区外的可信模板启动 MCP：

```sh
/path/to/template/bin/capbox --root /path/to/project mcp serve
```

MCP 执行与 CLI `task start --isolate` 共用宿主策略。工作区副本沿用 Git 脏树、非 Git 遍历和 overlay 合并规则。每个任务默认至多运行 600 秒，每路流保留 8 MiB。服务端可配置 `--max-timeout`，工具请求只可在这个上限内选择任务超时。

使用 `mcpServers` 块的客户端示例：

```json
{
  "mcpServers": {
    "capbox": {
      "command": "/absolute/path/to/template/bin/capbox",
      "args": ["--root", "/absolute/path/to/project", "mcp", "serve"]
    }
  }
}
```

仓库内副本见 [examples/mcpServers.capbox.json](../examples/mcpServers.capbox.json)。

`capbox_policy` 显示启动预览。以 `capbox_status` 和任务审计记录查看启动结果。MCP 参数 `--profile`、`--net`、`--workspace-mode` 只接受 `strict`、`none`、`isolated`；旧客户端配置中的 `untrusted`、`restricted`、`shared` 参数需移除。工具参数 `net_allow` 在无网策略下返回错误。

客户端配置格式各异。本服务器实现 [stdio 传输](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[初始化/版本协商](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle) 与 [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)。支持协议版本 `2025-11-25` 与 `2025-06-18`；未知版本协商到已支持的最新版。不宣告 MCP 可选的 task 增强协议：task ID 是 CapBox 工具结果。

| 工具 | 范围 |
|---|---|
| `capbox_execute` | 有界非交互 guest argv；返回 task ID |
| `capbox_status` | 任务状态与退出码 |
| `capbox_logs` | 流文本加结构化字节游标/base64 数据 |
| `capbox_cancel` | 异步取消；轮询 status 确认 |
| `capbox_diff` | 导出已完成隔离任务的补丁；不应用 |
| `capbox_policy` | 服务器固定的请求启动策略 |

只接受 `/workspace` 及其子路径作为 cwd。服务器不暴露宿主装包、升级、配置变更、任意宿主文件或 shell 命令。status、logs、cancel 和 diff 沿用项目的任务 ID 范围，包括此项目由本地 CLI 管理的既有任务。

消息是 UTF-8 JSON-RPC 行，单条输入最多 1MiB。非法 JSON、过大消息、未知工具/参数、坏 ID 与策略覆盖尝试会被拒绝。stdout 只含协议消息；诊断走 stderr。工具侧失败用 `isError`；日志游标仍是字节偏移。超出 MCP 结果预算的大 diff 请用本地 CLI 导出。请求串行处理，带有界 CLI 调用超时；服务器不另维护执行引擎。

关闭 MCP 连接不会请求取消已接受的任务。它们仍受普通宿主寿命与外层监督器限制。需要时用客户端 UI 的工具审阅控件与 CapBox 取消；日志与补丁仍是不可信任务数据。

<a id="5-five-minute-path-capbox-as-an-outer-linux-sandbox-claude-code--codex"></a>
## 5. 外层 Linux 沙箱路径（Claude Code / Codex）

把 CapBox 接到 Claude Code / Codex 这类 Agent 前面，作为外层 Linux 沙箱。不需要 Docker 或 KVM。guest 使用固定 MCP 默认；补丁先导出，再在宿主侧审阅应用。

### 步骤（约 5 分钟）

1. **安装模板**到业务工作区外并放入 `PATH`（见 [README](../README.md#安装模板)）。确认 `capbox version` 与 `bwrap --version`（≥ 0.12.0）。MCP 需要宿主 Python 3.10+。

2. **初始化项目工作区**（不要用 `$HOME` 或 `/`）：

```sh
cd /path/to/project
capbox init --agent --distro alpine
capbox doctor
# 预构建 / 恢复 rootfs，guest argv 才能跑（仅 init 不够执行）：
# 例如 recipe apply，或把已知 Alpine rootfs 拷进 .capbox/os/alpine 做本地冒烟。
```

3. **接入 MCP 客户端**：复制 [examples/mcpServers.capbox.json](../examples/mcpServers.capbox.json)，填入模板可执行文件与项目的绝对路径。

4. **从客户端运行 guest 任务**：

   - 用 `capbox_policy` 查看 `mcp.workspace_mode=isolated`、`profile=strict`、`net=none`。
   - 用 `capbox_execute` 运行 argv，例如 `["sh","-c","printf ok"]`，并设置较短的 `timeout`。
   - 用 `capbox_status` 查询结果，通过 `capbox_logs` 查看输出。
   - 用 `capbox_cancel` 取消任务，通过 `capbox_diff` 导出补丁到宿主侧审阅并应用。

回归锁：`test/security/test_envkit.py` 里的 `test_default_mcp_entry_runs_bounded_guest_task` 启动裸 `mcp serve`，断言固定策略块，执行有界 guest 命令，并检查 status/logs 成功。
