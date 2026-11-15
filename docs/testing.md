# 验证范围

CI 按层检查行为。通过“能力不可用时的兜底测试”不等于该能力真的成功了。

| Job | 范围 | 要求行为 |
|---|---|---|
| bash -n + selftest | 语法、harness 故障检测、配置事务、升级恢复、严格锁、策略/MCP 协议与 setup 预览、宿主边界与生成文档 | 无失败检查 |
| Offline audit report (Chromium) | Ubuntu 24.04；真实 file:// 报告：筛选、详情、JSON 下载、分页、移动端、惰性日志文本与 CSP | 无浏览器错误、CSP 违规或网络请求 |
| acceptance (bubblewrap) | T01–T41 选测，外加真实加固的 service/daemon/网络集成与 task/重连/隔离、HTTPS 凭据注入代理、bundle 往返与 MCP 执行回归（Alpine） | 真实沙箱执行；不吞掉 doctor 失败 |
| Compatibility matrix | x86_64 / aarch64 Ubuntu 22.04 宿主上的 Alpine 与 Ubuntu guest | 真实 exec、strict 配置、网络隔离、服务与锁校验；不允许 skip |
| Multi-UID mapping (required) | 明确有从属 UID/GID 委派的 runner | 必须拿到 multi 映射并通过 chown、非 root exec 与服务；不允许兜底或 skip |
| Default host policy | Ubuntu 26.04，不改 userns/AppArmor sysctl | bwrap 能跑就成功执行，否则明确报告宿主拒绝；拒绝后绝不能报“执行成功” |
| Compatibility coverage | 覆盖所有兼容性 job 的聚合门禁 | 每个依赖 job 都必须成功，含矩阵条目 |
| Security | C/Python CodeQL、仓库密钥模式、钉死的 Alpine 包扫描与 SBOM | 工作流定义的失败会阻断 |

主验收 fixture 会在临时 runner 上故意打开无特权用户命名空间。默认策略 job 不改宿主策略；摘要会区分“执行成功”与“显式测到的拒绝”。拒绝结果不是“这台宿主能跑沙箱”的证明。

旧 harness 仍保留依赖能力的用例：T15/T16 需要其 daemon 选项，T19 需要 slow 选项，T27 在 multi 不可用时可测 single-UID。独立兼容性 job 覆盖成功路径，不用那些 skip 当证据。

GitHub 托管 runner 标签见 [官方 runner 参考](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。更多发行版、WSL 特有行为、特权磁盘挂载以及应用层 Wiki 配方不在本矩阵内。支持某种 guest 发行版，不代表每个第三方包或服务组合都测过。

### Agent 启动保护的 Linux 检查

在已有 Alpine rootfs 的工作区之外，用可信安装目录中的 CapBox 运行以下命令。procfs 测试只读取 sysctl，并在每个用例结束时核对值。

```sh
uname -r
id -u
/usr/bin/bwrap --version
python3 test/security/test_agent_procfs.py
./bin/capbox --root /path/to/project doctor --agent --json
CAPBOX_TEST_ROOTFS="$PWD/os/alpine" python3 test/security/test_agent_workflows.py
```

| 本地实测环境 | 观测 |
| --- | --- |
| Linux 6.18.57 x86_64，UID 1000，Bubblewrap 0.12.0 | Bubblewrap 对新 procfs 的 `sys`、`sysrq-trigger`、`irq`、`bus` 做条件式只读自绑定。本机实测 `sys`、`irq`、`bus` 仍在可写的 proc 挂载视图中，`sysrq-trigger` 不存在。 |
| 同一环境，追加 `--remount-ro /proc` | guest 中的 procfs 挂载为只读。能看到的四条受检查路径均为只读。 |
| 同一环境，外层用私有只读 tmpfs 覆盖 `/proc/irq` | 内层 fresh procfs 挂载返回 EPERM，命令未执行。测试也接受内层 Linux 允许建立只读 fresh procfs 时的成功结果。 |
| 同一环境，实际隔离任务 | 外层阻止 Bubblewrap 建立 loopback 所需的 NETLINK_ROUTE 套接字。退出码为 5，记录 `bubblewrap_or_landlock_setup`，命令未执行。通过独立探针也确认该环境缺少 Landlock。 |

CI 的 acceptance 作业会在其实际安装的 Bubblewrap 版本下复跑。若发行版自带版本低于 0.12.0，CI 使用已固定校验和的 0.13.1。

### HTTPS 凭据注入的端到端检查

acceptance 作业在真实 Alpine rootfs 和 AF_UNIX 代理套接字上运行以下命令。CI 的 `setup-runtime` 安装 `python3-cryptography`；本地复跑需要同一依赖和可用的 Unix socket。

```sh
python3 test/security/test_credentials.py
```

`HttpsCredentialInjectionTests` 启动本地 HTTPS 上游、两套测试 CA 和真实的 `lib/net-proxy.py` 进程，逐项核对：

- 上游证书链不受信，或证书主机名不匹配时，代理中止上游握手，上游收不到应用请求，测试密钥不会被发送。
- 链与主机名校验通过后，占位符只在 `inject.json` 配置的请求头中替换为测试密钥。
- 查询串和请求体保留占位符，不写入测试密钥。
- 占位符出现在未配置的请求头时返回 403，上游收不到请求。
- `https_only` 凭据不会在明文 HTTP 中注入。
- 未绑定的主机即使走 HTTPS，也只能收到占位符。

该文件其余用例覆盖宿主密钥库权限、`prepare` 的显式授权子集、guest 环境变量只含占位符，以及代理拒绝审计只记录目标和原因。

### 隔离任务 cgroup v2

在具备 systemd、cgroup v2 委派、可用 Bubblewrap 和 Alpine rootfs 的 Linux 主机上，
从仓库根目录用普通用户运行：

```bash
sudo systemd-run --wait --pipe --collect --uid="$(id -u)" --property=Delegate=yes \
  --working-directory="$PWD" bash test/security/run-delegated-agent-tests.sh
```

默认从 `os/alpine` 取 rootfs。使用其他位置时可在 `systemd-run` 命令里加
`--setenv=CAPBOX_TEST_ROOTFS=/absolute/path/to/alpine`。测试直接读取
`cpu.max`、`memory.max`、`pids.max`、`memory.swap.max`、`cgroup.procs` 和
`/proc/<pid>/cgroup`，打印额度、归属、宿主 PID 和清理结果。
缺委派路径单独运行：

```bash
python3 test/security/test_agent_workflows.py PolicyTests.test_missing_cgroup_delegation_refuses_before_execution
```

### 隔离任务的输入范围

```sh
python3 test/security/test_agent_workflows.py InputSelectionTests
python3 test/security/test_envkit.py MCPTests
CAPBOX_TEST_ROOTFS="$PWD/os/alpine" python3 test/security/test_agent_workflows.py \
  TaskTests.test_selected_inputs_in_concurrent_guest_builds
```

第一条测试宿主范围、Git 复制规则、路径替换、并发副本和部分补丁。有宿主 C 编译器时还会从选中的文件编译并运行程序。第三条需要支持 Agent 强隔离的 Linux 宿主和已准备好的 Alpine rootfs。两个 guest 用各自的输入打包，并检查只读输入、私有输出和二进制补丁。

## Bubblewrap 内核面探针

在普通 Linux 用户会话安装 Bubblewrap 0.12.0 或更新版、libseccomp、Python、Node/npm、Go 和 apt，运行：

```sh
bash test/seccomp-compat.sh
```

脚本以只读方式使用宿主运行时，在临时目录写入 fixture。它分别运行无 CapBox 过滤器的对照和两种加固档的生成产物，检查生效的过滤器数量、若干拒绝规则、线程、离线 npm、apt 模拟和 Unix socket。损坏的 BPF 必须在执行 guest 标记命令前被拒绝。网络探针检查命名空间标识、回环、宿主监听器和外部路由，并记录继承的描述符。该脚本直接运行 bwrap，结果应与配置了对应安全档和 `CAPBOX_NET=none` 的实际 CapBox 工作负载一起验证。

| 宿主 | 实测 |
|---|---|
| Debian 13 x86_64、Linux 6.18.57、glibc 2.41、Bubblewrap 0.12.0，外层已有一个过滤器 | Python 3.12.14 线程、Node 24.22.1 Worker、npm 11.9.0 离线安装、apt 3.0.3 模拟检查通过。加固档观察到第二个过滤器。损坏的 BPF 被拒绝。 |
| 同一宿主 | 外层拒绝创建 AF_UNIX 和 NETLINK_ROUTE socket。Unix socket 与 `net=none` 成功路径未验证。未取得可用 Go 工具链。未读到 AppArmor 状态或 guest 标签。 |
| Ubuntu 24.04/26.04、aarch64、Alpine/musl | 待实测。 |

在上述受限宿主复跑已通过的子集：

```sh
CAPBOX_PROBE_SKIP_IPC=1 CAPBOX_PROBE_SKIP_GO=1 CAPBOX_PROBE_NETWORK=0 bash test/seccomp-compat.sh
```

这台宿主上三档的 `clone3(NULL, 0)` 均返回 `EINVAL`，线程负载通过。保留现有 `clone3` 行为。后续可跨 glibc、musl 和架构验证 `ENOSYS` 回退，以及传统 `clone` 的命名空间标志限制。按地址族过滤也待有完整网络和 IPC 实测后评估。

显式打开的宿主 FD 9 在启用 PID namespace 的 bwrap guest 中仍可见。用 `untrusted`、单 UID、`net=open` 的 CapBox `exec` 也观察到了同一结果。`net=none` 通过 `--unshare-net` 请求新网络命名空间，不启用 restricted 专用的代理目录挂载。共享启动器的描述符清理应在宿主策略入口合入后验证。需要覆盖原有 stdio、seccomp、UID 映射及启动握手使用的 FD，并测试继承的宿主 socket 和普通 FD。

真实 CLI 的加载失败探针可在已初始化的一次性项目中复跑。项目用 `untrusted`、单 UID 和当前宿主支持的网络模式，临时运行目录要在工作区外：

```sh
(
  export XDG_RUNTIME_DIR="$(mktemp -d /tmp/cb.XXXX)"
  trap 'rm -rf -- "$XDG_RUNTIME_DIR"' EXIT
  capbox exec -- /bin/sh -c 'test -e /proc/self/fd/9 && echo "FD 9 visible"' 9</dev/null
  bpf="$(find "$XDG_RUNTIME_DIR" -name seccomp-untrusted.bpf -print -quit)"
  test -n "$bpf" || exit 1
  printf 'invalid\n' > "$bpf"
  if capbox exec -- /bin/sh -c ': > /workspace/seccomp-payload-ran'; then exit 1; fi
  test ! -e seccomp-payload-ran
)
```

本次 CapBox `exec` 返回 1，bwrap 报告 `PR_SET_SECCOMP` 返回 `EINVAL`，guest 标记未创建。`EINVAL` 也可能来自其他加载条件，诊断保留 bwrap 的原始输出。

### AppArmor 诊断

`capbox doctor` 分别报告当前会话可读的宿主 AppArmor 状态、实际 bwrap user namespace 探针及 guest shell 的 AppArmor 标签。guest 探针没有运行或属性不可读时，标签未知。bwrap 失败时根据原始错误和内核日志判断原因。

- Ubuntu 24.04 及之后，检查 `sysctl kernel.apparmor_restrict_unprivileged_userns`、`sudo aa-status` 与 `sudo journalctl -k -b`。核对拒绝事件、实际 bwrap 路径和附着的策略。发行版说明见 [Ubuntu AppArmor 文档](https://documentation.ubuntu.com/security/security-features/privilege-restriction/apparmor/)。
- Debian，先用 `sudo aa-status` 和 `sudo journalctl -k -b` 确认加载状态及拒绝事件。若运行于容器内，另在外层核对安全策略和日志。
