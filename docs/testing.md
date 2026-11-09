# 验证范围

CI 按层检查行为。通过“能力不可用时的兜底测试”不等于该能力真的成功了。

| Job | 范围 | 要求行为 |
|---|---|---|
| bash -n + selftest | 语法、harness 故障检测、配置事务、升级恢复、严格锁、策略/MCP 协议与 setup 预览、宿主边界与生成文档 | 无失败检查 |
| Offline audit report (Chromium) | Ubuntu 24.04；真实 file:// 报告：筛选、详情、JSON 下载、分页、移动端、惰性日志文本与 CSP | 无浏览器错误、CSP 违规或网络请求 |
| acceptance (bubblewrap) | T01–T41 选测，外加真实加固的 service/daemon/网络集成与 task/重连/隔离、bundle 往返与 MCP 执行回归（Alpine） | 真实沙箱执行；不吞掉 doctor 失败 |
| Compatibility matrix | x86_64 / aarch64 Ubuntu 22.04 宿主上的 Alpine 与 Ubuntu guest | 真实 exec、strict 配置、网络隔离、服务与锁校验；不允许 skip |
| Multi-UID mapping (required) | 明确有从属 UID/GID 委派的 runner | 必须拿到 multi 映射并通过 chown、非 root exec 与服务；不允许兜底或 skip |
| Default host policy | Ubuntu 26.04，不改 userns/AppArmor sysctl | bwrap 能跑就成功执行，否则明确报告宿主拒绝；拒绝后绝不能报“执行成功” |
| Compatibility coverage | 覆盖所有兼容性 job 的聚合门禁 | 每个依赖 job 都必须成功，含矩阵条目 |
| Security | C/Python CodeQL、仓库密钥模式、钉死的 Alpine 包扫描与 SBOM | 工作流定义的失败会阻断 |

主验收 fixture 会在临时 runner 上故意打开无特权用户命名空间。默认策略 job 不改宿主策略；摘要会区分“执行成功”与“显式测到的拒绝”。拒绝结果不是“这台宿主能跑沙箱”的证明。

旧 harness 仍保留依赖能力的用例：T15/T16 需要其 daemon 选项，T19 需要 slow 选项，T27 在 multi 不可用时可测 single-UID。独立兼容性 job 覆盖成功路径，不用那些 skip 当证据。

GitHub 托管 runner 标签见 [官方 runner 参考](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。更多发行版、WSL 特有行为、特权磁盘挂载以及应用层 Wiki 配方不在本矩阵内。支持某种 guest 发行版，不代表每个第三方包或服务组合都测过。
