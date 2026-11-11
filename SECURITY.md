# CapBox 安全说明与威胁模型

CapBox 的信任边界是：**容器内是 root，但不是宿主 root**。guest 拥有完整的容器内权限（装包、改 `/etc`、写 `/workspace`），宿主内核与宿主家目录密钥仍应留在边界之外。

本文件描述 CapBox **声称**防护的内容、已知边界，以及调用方必须自己负责的部分。

## 信任边界

| 在边界内（guest 可见/可控） | 在边界外（不应落入 guest） |
|---|---|
| 工作区 `/workspace`（RW bind） | 宿主家目录中未 bind 的路径 |
| rootfs `os/<distro>/`（按配置 RO/RW） | 宿主真实 root、宿主机其它用户文件 |
| 容器内 uid 0 + 配置档允许的 capability | 宿主 uid 0 / 宿主内核密钥 |
| 显式白名单环境变量 | 宿主 shell 中的密钥与令牌 |

**默认档 `compat` 优先兼容，不是加固档。** 不可信负载请使用 `CAPBOX_SECURITY_PROFILE=untrusted|strict`。

## 环境变量清空（强制）

所有经 `bwrap` 启动的路径（`exec` / `shell` / `service start` / `capbox up` daemon）在构造参数时：

1. **无条件**先加 `--clearenv`，丢弃宿主环境；
2. 再按白名单 `--setenv` 重建最小集合。

白名单主要包括：

- 基础：`HOME=/root`、`PATH`（容器标准路径）、`TERM`、`LANG`
- 网络：仅当用户配置了 `CAPBOX_PROXY`，或 `CAPBOX_NET=restricted` 的桥接代理时，注入 `http(s)_proxy` / `HTTP(S)_PROXY` / `no_proxy` 等
- 安全档：`CAPBOX_SECURITY_PROFILE`（以及 seccomp 相关标记）
- daemon：`CAPBOX_DAEMON_DIR`、`CAPBOX_DISTRO`、`CAPBOX_VERSION`、心跳/并发等运行参数

**不会**透传例如：

- `SSH_AUTH_SOCK`、`GPG_AGENT_INFO`
- `AWS_*`、`*_TOKEN`、`*_KEY`、`OPENAI_API_KEY`、`GITHUB_TOKEN`
- 宿主 `USER`/`LOGNAME`、编辑器/agent 注入的私有变量

实现位置：`lib/launch.sh` 的 `build_bwrap_args`；daemon 的 `_daemon_bwrap_args` 也委托同一实现。`doctor` 含一项 live 探针：若哨兵变量仍能进入 guest，则 **FAIL**。

`image docker run` 会在 `--clearenv` 之后追加镜像自己的 `Env`，且只通过 `bwrap --setenv`。这些值不 `export` 到宿主 shell。`exec --image` 不套用镜像 `Env`。镜像里的 `Entrypoint` / `Cmd` 只作为 guest argv，不在宿主执行。不可信镜像仍应使用 `untrusted` 或 `strict`；`compat` 不会因为来源是 Docker 镜像而自动收紧。

> 同类根因先例：调用方省略 bwrap `--clearenv` 导致沙箱继承宿主密钥（例如公开记录的 mini-swe-agent 环境继承问题）。这不是 bwrap 本身的缺陷，而是参数构造责任。

## bubblewrap 最低版本

`doctor` 和每一次会创建 bwrap 的入口（`exec` / `shell` / `service start` / `up`，含 `build_bwrap_args` 与 daemon 委托入口 `_daemon_bwrap_args`）都要求 `bwrap --version` **不低于 0.12.0**。版本不够或无法解析时，`doctor` 记 **FAIL** 并退出 **6**；启动直接拒绝，退出码同样是 6。二进制缺失仍是「依赖不可用」（退出码 5），不是基线 6。

0.12.0 修了 CVE-2026-87766：setup 阶段可以经 `/oldroot` 的符号链接写出沙箱。这是启动前的宿主写入，跟容器里 capability 大小无关，所以 **compat、untrusted、strict 一样拒绝**。CVE-2026-41163 只影响 setuid 的 0.11.0 与 0.11.1，0.11.2 已修。门槛放在 0.12.0，两处都盖住。CapBox 让 bwrap 在 rootfs 里创建 `/tmp`、`/proc`、`/dev` 等挂载点，而 rootfs 对 guest 经常可写，所以上面的 setup 缺陷在这条用法里成立。

发行版若把补丁打进 0.11.x 再撤回，`bwrap --version` 仍报 0.11.x。这种包不达标。Ubuntu 26.04 的 `0.11.1-1ubuntu0.3` 撤回了 CVE-2026-87766 补丁，需要换成上游 0.12.0 或更新的二进制。Debian/Ubuntu 可先试 `sudo apt install --only-upgrade bubblewrap`；发行版没有 0.12.0 时从源码或更新的仓库安装。

放行只有两条，都要留下审计（`logs/audit.jsonl` 的 `event` 为 `old_bwrap_bypass`，含版本、命令、`scope` 为 `once` 或 `persist`）。`CAPBOX_AUDIT=off` 也写这条。没有环境变量绕过。

- 单次：`capbox --allow-old-bwrap <command>`。只对这一次调用生效，不写 `config.env`，不改变 `doctor` 的结论。
- 持久：`capbox config set --yes CAPBOX_ALLOW_OLD_BWRAP 1`。之后的启动放行，每次在 stderr 警告。`doctor` 仍是 **FAIL**（退出码 6），不会因为放行变成 PASS。

版本探测结果缓存在 `state/bwrap-version`，按二进制的 dev、inode、mtime、size 失效。该文件对 guest 钉成 `--ro-bind /dev/null`。缓存里没有「已达标」位，是否达标按存下来的版本号重算。

## 文件系统

- `/workspace` 是工作区 RW 视图：guest 能读写项目文件；**不要把密钥只靠“不在环境变量里”来保护——文件在工作区同样可见。**
- `untrusted`/`strict` 会遮盖工作区内默认敏感相对路径（如 `.ssh`），并可用 `CAPBOX_FS_HIDE` 扩展。
- CLI / `config.env` / `services/` 对 guest **只读覆盖绑定**，降低“改 CLI = 下次宿主 RCE”的路径。
- **缺失即预占**：不仅保护已存在的配置文件，还对**启动时缺失、但宿主 CLI 会读取的配置路径**施加预占保护。标准 `…/.capbox` 布局下整树只读（`run/`/`cache/` 再 RW 挂回），并对 `config.env` 钉 `--ro-bind /dev/null`；`config_save` 对已存在文件**就地覆盖**以保留 inode，避免长寿 daemon 挂载因 `mv` 换名失效。仓库即状态布局则回退为逐项保护 `bin/`/`lib/`/`config.env`/`services/`。两种布局都再把 `logs/`（含 `logs/audit.jsonl`）显式 `--ro-bind`；标准布局里这一步放在 `run/`、`cache/` 的可写挂回之后，并且在 `FS_BINDS` 与 `CAPBOX_BWRAP_EXTRA` 之后再挂一次，保证最后盖住 `logs/` 的是只读绑定。`FS_BINDS` 的 guest 路径若等于 `logs/` 或其内部路径，启动直接失败。`logs` 或 `logs/audit.jsonl` 是符号链接、或 `audit.jsonl` 是目录时拒绝启动；宿主追加审计时若发现符号链接或目录也拒绝写入。guest 可以读审计日志。宿主写日志走宿主路径，不受这条挂载影响。`doctor` 会让 guest 尝试追加 `audit.jsonl`，写成则 **FAIL**。`compat` 保留 `CAP_SYS_ADMIN` 且没有 seccomp，父挂载有可能被卸掉；`untrusted` 与 `strict` 的 seccomp 挡住 `mount`。compat 下的卸载不作为已经验证过的利用。这与 CVE-2026-25725 的修复语义一致。
- `CAPBOX_FS_BINDS` 拒绝工作区外的任意 bind。
- 符号链接形式的受保护路径无法作为 bwrap 挂载目标；`doctor` 会警告，请改为普通文件/目录。

## 宿主控制面（0.3.5 起）

服务启动脚本、NUL 分隔的启动参数、PID 身份记录、systemd 单元记录、锁、网络代理脚本/套接字、UID 映射握手、seccomp BPF 和静态 helper 都放在工作区之外的宿主私有目录。优先使用安全且路径足够短的 `$XDG_RUNTIME_DIR` 或 `/run/user/UID`，否则使用 sticky `/tmp`。目录形态为 `capbox-UID/<项目路径的 SHA256 前 32 位>/`；父目录和项目目录必须由当前用户拥有、权限为 `0700`，符号链接或不安全权限直接拒绝。找不到安全目录时失败，不回退到 guest 可写的 `.capbox/run`。

`run/` 仍可承载 guest 数据与 daemon IPC，但宿主不再从中执行服务脚本或读取服务 PID。guest 只获得服务 `/run` 子目录，以及只读的 `/run/capbox-net` 就绪信号目录；宿主控制文件和代理 socket 不挂入 guest。服务日志通过 `capbox service logs NAME` 读取，不再依赖 `.capbox/run/services/` 路径。

`capbox-drop-priv` 仅在宿主私有目录构建，再只读绑定到 guest `/run/capbox-drop-priv`。宿主不向 guest 可修改的 rootfs 复制或 chmod 该 helper，因此安装不会跟随 rootfs 中的符号链接写到宿主。daemon 启动时绑定 helper，升级后必须重启已有 daemon。

服务 supervisor 显式保留 seccomp FD，并在每次重启前重置 BPF 文件偏移。实际启动失败或 readiness 失败会让 `service start` 返回非零。停止服务前核对宿主进程的 PID namespace 和启动时间，避免仅凭复用的 PID 操作其它进程。

## 用户命名空间与 capability

- guest uid 0 ≠ 宿主 uid 0；权限来自 user namespace 映射。
- `compat`：`--cap-add ALL`，无 seccomp。
- `untrusted`/`strict`：显式 `--cap-drop` + 真实 seccomp BPF；多 UID idmap 启用时跳过 `--disable-userns`（与 bwrap `userns-block-fd` 不兼容，属 Linux/bwrap 边界，见 `doctor`）。

## Landlock

`CAPBOX_LANDLOCK=on|off`。没写的时候，`strict` 默认开启，`compat` 和 `untrusted` 默认关闭。显式的 `on` 或 `off` 覆盖这个默认。空值仍然走默认。

开启之后，每次 `exec` / `shell` / `service start` / `up` 都会在 **bwrap 挂载完成之后** 把容器内命令放进 Landlock。静态 helper `capbox-landlock` 用宿主 `gcc -static` 构建，放在工作区外的上述宿主私有项目目录的 `landlock/`，再只读绑到 guest 的 `/run/capbox-landlock`。挂载点放在已经准备好的 `/run` 上，避免 bwrap 在可写 rootfs 里留下空文件。不能把 Landlock 套在 bwrap 进程外面：规则集一旦处理文件系统，内核就拒绝这个进程 `mount` / `pivot_root`，bwrap 的 setup 会直接失败。

规则按挂载后的 guest 路径写：

- 可写：`/workspace`、`/tmp`、`/run`、`/dev`、`/proc`，以及磁盘配额的 guest 路径（若配置了 `CAPBOX_DISK_MAX`）
- rootfs 顶层目录：只读挂载时只读；`ROOTFS_RO=0` 或 overlay 合并层可写时，规则同样给写，否则装包和写 `/etc` 会被这一层挡住

允许目录的子路径不能再单独拒绝。`FS_HIDE` 仍然靠 tmpfs 遮盖。绑到允许目录里面的内容，Landlock 沿父目录放行。规则没有覆盖的路径（例如被跳过的 `/sys`）会被拒绝。这一层不限制 TCP 端口。

内核不支持 Landlock，或宿主没有 `gcc -static` 时，已启用的启动 **失败**（退出码 5），`doctor` 记 **FAIL**。不会假装已经限制。

## 网络

| `CAPBOX_NET` | 含义 |
|---|---|
| `open`（默认，`host` 别名） | 共享宿主网络；出站能力 ≈ 宿主 |
| `none` | `--unshare-net`，容器内无网络 |
| `restricted` | `--unshare-net` + 域名 allowlist HTTP 代理；**不假装** bwrap 能过滤原始 TCP。`exec` 与 `capbox up` 共用这套桥（不同 sock，互不拆掉）。无端口的规则只放行 80/443；`example.com` 不含子域；解析到回环、链路本地或私网地址会被拒绝，除非该地址显式在 allowlist 中。未知 `CAPBOX_NET` 失败，不会当成 `open` |

`open` 下若 guest 被投毒，仍可能用工作区文件或网络外泄数据——环境清空挡住的是**宿主环境里的密钥**，不是 guest 自己读到的工作区机密。

## 资源限额

`MEMORY_MAX` / `CPU_MAX` / `PIDS_MAX` / `DISK_MAX` 优先 cgroup v2；无法兑现时 `warn` 降级或 `require` 硬失败。磁盘配额需要宿主授权的 loop/mount，不是 rootless 保证。

## 非目标（明确不承诺）

- 防御已获得工作区写权限的恶意 guest 篡改项目代码
- 在 `CAPBOX_NET=open` 下阻止 guest 访问宿主可达的网络服务
- 替代机密管理系统（Vault/云 IAM）；密钥不应长期放在工作区明文或宿主环境里再指望 CapBox 擦除
- 对抗有意弱化配置（`compat` + 工作区存放生产密钥）的运营失误

## 报告问题

请在 GitHub Issues 描述复现步骤、`capbox doctor` 输出与相关配置（可打码）。不要在公开 issue 里粘贴真实密钥。

## 基础镜像与持续检查

新建 Alpine rootfs 固定为 **3.24.4 / v3.24**，x86_64 与 aarch64 各自校验官方 SHA256。已有 rootfs 不自动覆盖或跨版本升级；需先备份，并在新工作区初始化受支持版本后迁移必要数据。发行版支持周期见 [Alpine 官方发布表](https://alpinelinux.org/releases/)。

`capbox init --agent` 设置 `untrusted`、`NET=none`、`IDMAP=off` 和 `RESOURCES_MODE=require`。资源限额需显式配置；设置后若无法兑现，则拒绝启动。普通交互初始化仍保留 compat/open 的兼容语义，不适合直接运行不可信负载。

CI 包含 T41 Landlock、宿主边界回归、加固服务重启、daemon 和网络桥测试。Security 工作流检查 C/Python、仓库密钥、固定基础镜像的可修复 HIGH/CRITICAL 包漏洞，并导出 CycloneDX SBOM；每周重新检查。Actions 使用完整 SHA，工作流默认只有 contents:read，CodeQL job 单独获得 security-events:write。

升级部署前，使用旧版 CLI 停止所有 service 和 daemon，再更新模板及每个项目的 `.capbox/bin`、`.capbox/lib`，然后重新启动。旧运行目录中的脚本、PID 和缓存不会导入新的宿主控制面。私有运行目录属于该宿主，移动整个项目到另一台机器后需重新启动服务；不要复制运行记录。

本仓库 main 已配置 PR、六项必需 CI/Security 检查、讨论解决、管理员约束，并禁止强推与删除。个人维护场景不强制另一位维护者审批。Dependabot 漏洞告警和自动安全修复已启用，密钥扫描与推送保护保持启用。仓库设置与工作流需共同维护。

## Alpine APK 安装脚本与宿主 AppArmor

Ubuntu 26 等宿主可能允许创建可执行 memfd，却由 AppArmor 拒绝执行匿名脚本。APK 3 在这种情况下会让安装触发器失败，即使软件文件已经解包。

`capbox pkg install/remove` 在 Alpine 下需要宿主 `python3` 和 `libseccomp`，并在所选安全档已有规则之外追加一条限制：显式请求可执行 memfd 的创建返回 ENOSYS，让 APK 使用自身的磁盘脚本回退路径。普通非可执行 memfd 不受这条规则影响。安装脚本仍会运行，错误码仍透传；宿主 AppArmor、已有 seccomp 规则和 capability 限制都保留。直接在 shell 内运行 apk 不经过这个兼容封装，仍可能受宿主匿名脚本策略影响。

## 0.3.6 配置提交、升级与严格包锁

配方先完整解析并校验所有键值，未知键、重复键及无效行直接失败。校验失败不会写回部分配置；合法批次通过进程间锁串行提交，并保留已有 config.env inode，维持长寿 guest 的只读绑定。提交不是跨断电的原子替换，后续初始化和装包也不属于配置事务。隐式 ROOTFS_RO 默认值不会因修改其它配置而写成显式可写，保留 strict 的默认只读语义；旧文件中已有 ROOTFS_RO=0 仍受尊重，需要只读根时请显式设为 1。配置处理在 `lib/config.sh`；启动参数在 `lib/launch.sh`，缺少必需运行模块时拒绝启动。

`init --trusted` 显式选择兼容开发设置；`--agent` 选择加固、无网、单 UID 与资源 require。两者都不会自动选择资源数值。裸初始化保留既有配置与历史兼容默认值。

`upgrade` 只更新已停止项目的 bin/lib。新模板必须在工作区外并由用户信任；暂存时验证完整文件集合和冒烟检查。备份及恢复日志放在工作区外的持久私有宿主状态目录（XDG_STATE_HOME，默认 ~/.local/state/capbox），替换失败时补偿恢复。中断标记会阻止新 CLI 的普通命令，需从完整外部模板回滚。升级无法协调仍在运行的旧版 CLI 调用，需要停机维护；不会自动升级 rootfs 或业务数据。

严格包锁绑定发行版、架构及完整已安装包版本集合。它仅生成校验过的精确版本参数，经现有包管理封装安装后重新比较；版本不可用或不匹配会失败。锁文件是数据，不能证明包文件未被篡改，也不能保存上游已删除的软件版本。长期重建需另存可信软件源快照或 rootfs 镜像。详见 [升级](docs/upgrades.md)、[包锁](docs/package-locks.md)、[CI 范围](docs/testing.md)。
