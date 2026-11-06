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

实现位置：`lib/common.sh` 的 `build_bwrap_args`，以及 `lib/daemon.sh` 的 `_daemon_bwrap_args`（兜底路径）。`doctor` 含一项 live 探针：若哨兵变量仍能进入 guest，则 **FAIL**。

> 同类根因先例：调用方省略 bwrap `--clearenv` 导致沙箱继承宿主密钥（例如公开记录的 mini-swe-agent 环境继承问题）。这不是 bwrap 本身的缺陷，而是参数构造责任。

## bubblewrap 最低版本

`doctor` 和每一次会创建 bwrap 的入口（`exec` / `shell` / `service start` / `up`，含 `build_bwrap_args` 与 daemon 兜底 `_daemon_bwrap_args`）都要求 `bwrap --version` **不低于 0.12.0**。版本不够或无法解析时，`doctor` 记 **FAIL** 并退出 **6**；启动直接拒绝，退出码同样是 6。二进制缺失仍是「依赖不可用」（退出码 5），不是基线 6。

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
- **缺失即预占**：不仅保护已存在的配置文件，还对**启动时缺失、但宿主 CLI 会读取的配置路径**施加预占保护。标准 `…/.capbox` 布局下整树只读（`run/`/`cache/` 再 RW 挂回），并对 `config.env` 钉 `--ro-bind /dev/null`；`config_save` 对已存在文件**就地覆盖**以保留 inode，避免长寿 daemon 挂载因 `mv` 换名失效。仓库即状态布局则回退为逐项保护 `bin/`/`lib/`/`config.env`/`services/`。两种布局都再把 `logs/`（含 `logs/audit.jsonl`）显式 `--ro-bind`；标准布局里这一步放在 `run/`、`cache/` 的可写挂回之后。`logs` 是符号链接或普通文件时拒绝启动。guest 可以读审计日志。宿主写日志走宿主路径，不受这条挂载影响。`doctor` 会让 guest 尝试追加 `audit.jsonl`，写成则 **FAIL**。`compat` 保留 `CAP_SYS_ADMIN` 且没有 seccomp，父挂载有可能被卸掉；`untrusted` 与 `strict` 的 seccomp 挡住 `mount`。compat 下的卸载不作为已经验证过的利用。这与 CVE-2026-25725 的修复语义一致。
- `CAPBOX_FS_BINDS` 拒绝工作区外的任意 bind。
- 符号链接形式的受保护路径无法作为 bwrap 挂载目标；`doctor` 会警告，请改为普通文件/目录。

## 用户命名空间与 capability

- guest uid 0 ≠ 宿主 uid 0；权限来自 user namespace 映射。
- `compat`：`--cap-add ALL`，无 seccomp。
- `untrusted`/`strict`：显式 `--cap-drop` + 真实 seccomp BPF；多 UID idmap 启用时跳过 `--disable-userns`（与 bwrap `userns-block-fd` 不兼容，属 Linux/bwrap 边界，见 `doctor`）。

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
