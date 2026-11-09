# CapBox

中文 · [副本](README.zh-CN.md)

使用 bubblewrap 和用户命名空间，在独立项目目录中提供持久化 Linux 环境，供 coding agent 或可信开发任务装包、运行命令和服务。

<!-- generated:version -->
开发中的 CLI：**0.4.2**。正式版本与迁移说明见 [Releases](https://github.com/Sladewww/capbox/releases)。
<!-- /generated:version -->

guest root 不等于宿主 root；两者共用内核。`/workspace` 是宿主项目的可写视图，guest 能修改项目代码。无关密钥留在工作区外，宿主执行修改后的代码前仍需审查。[安全模型](SECURITY.md)。

## 环境工具（setup / bundle / MCP）

`setup check/plan` 生成宿主依赖和升级计划；`bundle pack/verify/check/restore` 保存并校验可携带的 rootfs、包锁和配方；`mcp serve` 在固定工作区与权限内提供 stdio 工具。用法和范围见 [环境工具](docs/envkit.md)。可克隆的约五分钟日常路径（CapBox 作为 Claude Code / Codex 类 Agent 的外层 Linux 沙箱：isolated + untrusted + 无网络）见 [五分钟路径](docs/envkit.md#5-five-minute-path-capbox-as-an-outer-linux-sandbox-claude-code--codex)。

## 离线审计可视化

`capbox audit report --output /path/outside/project/audit.html` 生成可直接打开的 HTML 报告，包含事件趋势、失败统计、搜索、筛选、分页与详情。无需服务或联网。数据范围、导出选项与分享注意见 [审计报告](docs/audit-reports.md)。

## 宿主要求

Linux、Bash 4.4+、bubblewrap **≥ 0.12.0**。安装后检查 `bwrap --version`；发行版自带的旧版本可能不满足要求。宿主还必须允许相应用户命名空间。

Alpine 包安装脚本需要宿主 Python 3.10+ 和 libseccomp。升级、严格包锁及部分辅助功能也使用 Python 3.10+。Landlock 和身份辅助程序需要可用的 `gcc -static` 工具链。`doctor` 用来核对实际能力；CI 兼容范围见 [测试](docs/testing.md)。

普通运行无需宿主 root；磁盘配额另需宿主 loop/mount 授权，仅覆盖指定 guest 数据目录。CPU、内存和进程限额依赖 cgroup 委派；`require` 会拒绝无法兑现的已配置额度。

## 安装模板

模板应在所有业务工作区之外。下面目标不存在时执行：

```sh
mkdir -p "$HOME/.local/share"
git clone https://github.com/Sladewww/capbox.git "$HOME/.local/share/capbox"
export PATH="$HOME/.local/share/capbox/bin:$PATH"
capbox version
bwrap --version
```

需要跨终端保留时，将 PATH 设置加入自己的 shell 配置。安装正式版时选择对应 tag 或发行包，并校验提供的 SHA256。

## 分开选择运行预设

在独立项目目录执行，不能把 `$HOME` 或 `/` 当工作区。

**Agent / 不可信任务：**

```sh
cd /path/to/project
capbox init --agent --distro alpine
capbox doctor
capbox exec -- id -u
```

`--agent` 设置 `untrusted`、`NET=none`、`IDMAP=off`、`RESOURCES_MODE=require`。预设不会替你选择资源数值。宿主具备 cgroup 委派后，按任务设置额度并核实：

```sh
capbox config set MEMORY_MAX 512M
capbox config set CPU_MAX 50%
capbox config set PIDS_MAX 256
capbox doctor
capbox metrics --json
```

**可信开发，需要共享宿主网络：**

```sh
capbox init --trusted --distro alpine
capbox pkg install curl
capbox exec -- curl --version
```

`--trusted` 设置 `compat/open`、自动 ID 映射及资源模式 `warn`。两个显式预设都会覆盖各自的四项设置。裸 `init` 保留已有配置；全新裸初始化沿用历史 compat/open 默认值。需要 Ubuntu 时使用 `--distro ubuntu`。

## 网络、服务与状态

| 模式 | 行为 |
|---|---|
| `none` | 独立网络命名空间，无通用网络访问 |
| `restricted` | 独立网络空间加 HTTP(S) 白名单代理，需要 `NET_ALLOW` |
| `open`（`host`） | 共享宿主网络 |

`pkg install/update` 即使在 none 下也可为本次装包出网。Alpine 优先使用 `capbox pkg`，直接运行 apk 不经过安装脚本兼容封装。其它命令的出网按次声明，例如 `capbox exec --net restricted -- CMD`。

服务定义为 `.capbox/services/NAME.env`，`service start` 无需先 `up`。日志使用 `service logs NAME`。rootfs、配置、业务数据在项目中；宿主启动器、进程身份、过滤器和辅助程序在工作区外的私有 `0700` 目录。

需要跨调用共享整机时用 `capbox up --systemd`，随后 `capbox exec --daemon -- CMD`。无 systemd 用户总线时，使用能够跨调用存活的后台托管。

## 本地 Agent 任务

`capbox task start -- CMD` 返回持久 task ID，支持重连、按游标读取日志和取消。`task start --isolate` 创建独立工作文件与 rootfs 副本，结束后导出 diff 供审阅。`policy show` / `policy check URL` 解释请求的策略及网络规则。

接口、超时语义、隔离范围和审阅示例见 [本地 Agent 工作流](docs/agent-workflows.md)。

## 配置校验与包锁

```sh
capbox recipe check capbox.recipe
capbox recipe apply capbox.recipe
capbox image lock save
capbox image lock verify
# 按记录的精确包版本重建：
capbox recipe apply --locked /path/to/package.lock capbox.recipe
```

配方中的未知键、重复键及无效行会报错；全部配置值校验通过后才加锁一次写回，并保留配置文件 inode。后续 rootfs 初始化和装包仍可能失败，它们不属于可统一回滚的配置提交。

包锁记录发行版、架构和完整已安装版本集合。精确版本不可用或恢复后集合不符时失败，不替换成其它版本。长期复现还需要保留 rootfs 镜像或软件源快照。[包锁说明](docs/package-locks.md)。

## 更新已有项目

先用旧 CLI 停止全部 service、daemon 和其它 exec。再从新模板调用：

```sh
"$HOME/.local/share/capbox/bin/capbox" --root /path/to/project upgrade check --from "$HOME/.local/share/capbox"
"$HOME/.local/share/capbox/bin/capbox" --root /path/to/project upgrade apply --from "$HOME/.local/share/capbox"
# 需要时：
"$HOME/.local/share/capbox/bin/capbox" --root /path/to/project upgrade rollback
```

升级会比较运行文件、验证整套 bin/lib、保存私有备份并在替换失败后恢复；中断后普通命令拒绝启动，先回滚恢复。操作需要停机维护，无法协调仍在并发执行的旧版 CLI。[升级说明](docs/upgrades.md)。

## 文档与验证

| 文档 | 用途 |
|---|---|
| [生成的 CLI 参考](docs/cli-reference.md) | 实际命令帮助 |
| [生成的配置默认值](docs/configuration.md) | 实际内置默认 |
| [架构](docs/architecture.md) | 模块边界与启动策略 |
| [测试](docs/testing.md) | CI 矩阵与能力要求 |
| [Wiki](https://github.com/Sladewww/capbox/wiki) | 按版本维护的中文运维与应用示例 |
| [贡献指南](CONTRIBUTING.md) | 提交前检查 |

<!-- generated:tests -->
验收用例：**41**（T01–T41）。框架自测验证测试工具；真实 guest 与宿主边界回归单独运行。
<!-- /generated:tests -->

MIT — [LICENSE](LICENSE)。

### 宿主凭据代理

真实 API key 留在宿主私有目录；guest 只看到 `capbox-sec-…` 占位符。`restricted` 网络下由宿主代理按 `NET_ALLOW` 授权域名改写请求头（不含 body/query）。详见 [docs/credentials.md](docs/credentials.md)。日常 MCP 入口是 `mcp serve`（默认 isolated/untrusted/none）；需要凭据时代理时显式加 `--net restricted`，见 [docs/envkit.md](docs/envkit.md) 与 [examples/](examples/)。
