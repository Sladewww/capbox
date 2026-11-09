# 升级与恢复

需要宿主 Python **3.10+**。

使用工作区外可信、完整的模板。模板本身用你平时的 Git 或已校验发行流程更新。应用或回滚前，用旧 CLI 结束或取消活动任务，停掉全部 service 与 daemon，并结束所有 exec。用 `task wait` 或 `task status` 确认任务结束。CapBox 会检查已知在跑的 task/service/daemon，并对遗留 service 记录保守拒绝；它无法协调任意并发使用的旧版 CLI。

```sh
capbox --root /path/to/project upgrade check --from /path/to/new-template --json
capbox --root /path/to/project upgrade apply --from /path/to/new-template
capbox --root /path/to/project upgrade rollback
```

升级旧项目时调用**新模板的 bin/capbox**。升级分发故意使用该模板的完整库，即使目标项目的库偏旧或不完整。

`check` 比较运行时内容与可执行位（含过时文件）。即使版本字符串相同也会报告差异，且可在停服务前运行。`apply` 替换完整 `bin` 与 `lib` 树（含本地改动）；先看比较结果。私有备份保留旧树供回滚。

## 提交与恢复

1. 校验普通文件与目录；拒绝符号链接的运行时输入与 guest 可见的升级源。
2. 在项目所在文件系统上把完整包拷到暂存区。校验内容哈希、shell 语法、模块完整性、版本与 help。
3. 把旧运行时拷到持久私有备份并校验。保存已 flush 的事务日志。
4. 标记项目处于维护，替换运行时目录并校验已安装包。
5. 替换/检查失败时恢复旧树。恢复成功后清除维护标记。

目录替换靠日志与补偿恢复，不是跨两棵树的一次原子文件系统操作。需要恢复时，标记会拦住新 CLI 的普通调用。进程或机器中断后，用完好的外部模板跑 `upgrade rollback`。rootfs、配置、服务定义与业务数据不在此操作中搬移。

## 备份位置

备份在 `$XDG_STATE_HOME/capbox/<project-hash>/upgrades/`；未设置 XDG_STATE_HOME 时为 `~/.local/state/capbox/<project-hash>/upgrades/`。目录须属当前用户，私有备份根用 `0700`，并留在工作区外。这些备份在运行时目录清理与普通重启后仍在。`check --json` 会报告位置。

当前实现保留最近一条回滚记录与先前备份目录。迁移项目或清理宿主状态前，先留好仍需要的备份；项目哈希跟其规范安装路径走。回滚在替换文件前检查备份哈希。

已有 rootfs 版本与 CLI 独立。对旧 Alpine 发行版，请保留备份并初始化新工作区，重装受支持包并迁移必要业务数据。CLI 升级不会修补已有 guest 包，也不做数据库版本迁移。
