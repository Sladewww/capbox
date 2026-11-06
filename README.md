# CapBox

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4.4%2B-green.svg)](bin/capbox)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](#)
[![Tests](https://img.shields.io/badge/tests-T01–T38-informational.svg)](test/run.sh)
[![CI](https://github.com/Sladewww/capbox/actions/workflows/ci.yml/badge.svg)](https://github.com/Sladewww/capbox/actions/workflows/ci.yml)

工作区里的一台 Linux。不需要 Docker、不需要 sudo。`capbox init` 之后，你就有了一个
**在容器内拥有完整 root 权限** 的持久环境 —— 全部状态就是项目下的 `.capbox/` 目录。


## 为什么会有这个东西

AI agent 经常需要「只有 root 才能做」的事：装系统包、改 `/etc`、挂载、编译到 `/usr`。
直接在宿主做要么没权限，要么弄脏系统；Docker 在部分受限环境又跑不了。

CapBox 用 `bwrap`（bubblewrap）+ user namespace：把 `os/<distro>/` bind 成容器的 `/`，
容器内 `id -u` 为 0 且 capability 全量；工作区挂到 `/workspace`。适合已经跑在外层沙箱里的 coding agent。

## 网络三档（CAPBOX_NET）

| 模式 | 行为 | 说明 |
|------|------|------|
| `open`（别名 `host`） | 共享宿主网络 | 人类调试的默认；与历史行为一致 |
| `none` | `bwrap --unshare-net` | 容器内无网络 |
| `restricted` | `--unshare-net` + 域名 allowlist HTTP 代理 | **不假装** bwrap 能过滤域名。原始 TCP/UDP 无路由；仅尊重 `http(s)_proxy` 的客户端可出站。一次性 `exec` 和 `capbox up` 都挂这条桥 |

`restricted` 前置：`python3`、`nsenter`（util-linux）、非空 `CAPBOX_NET_ALLOW`。
未知取值直接失败，不会当成 `open`。

allow 语法（逗号分隔）：

| 写法 | 含义 |
|------|------|
| `example.com` | 只这个主机，只 80 和 443，不含子域 |
| `*.example.com` | 子域，不含 apex；同样只 80/443 |
| `github.com:22` | 只这个端口 |
| `example.com:*` | 任意端口 |
| `10.0.0.0/8` | 显式网段 |

名字解析到回环、链路本地（含云元数据）或私网地址时拒绝，除非那个地址自己写在 allowlist 里。

```sh
capbox config set CAPBOX_NET restricted
capbox config set CAPBOX_NET_ALLOW 'pypi.org,files.pythonhosted.org,*.python.org'
capbox exec -- curl -I https://pypi.org/
capbox exec --net none -- curl -I https://example.com/   # 仅本次覆盖为无网
```

给 coding agent 用 `capbox init --agent`：写入 `CAPBOX_SECURITY_PROFILE=untrusted` 和 `CAPBOX_NET=restricted`（还要自己填 allowlist）。默认档仍是 `compat` + `open`，那是兼容，不是加固。

## 声明式配方（recipe）

项目根目录放 `capbox.recipe`（纯 `KEY=value`，**不会被 source**）：

```sh
DISTRO=alpine
NET=restricted
NET_ALLOW=mirrors.aliyun.com,pypi.org
MEMORY_MAX=512M
PIDS_MAX=256
CPU_MAX=50%
PACKAGES=curl,git
```

```sh
capbox recipe apply              # 写 config → 按需 init → pkg install
capbox recipe show
```

## 资源限额

`CAPBOX_MEMORY_MAX` / `CAPBOX_CPU_MAX` / `CAPBOX_PIDS_MAX` / `CAPBOX_DISK_MAX`：优先 cgroup v2（`memory.max` / `cpu.max` / `pids.max` / `io.max`）。
`CAPBOX_RESOURCES_MODE=warn|require`：

- `warn`（默认）：无 cgroup 委派时 **WARN**；内存可降级为 `prlimit` 的 `RLIMIT_AS`（**近似，不是** `memory.max`）。
- `require`（fail-closed）：任一已配置限额无法按 cgroup/精确机制兑现则 **硬失败**。

`CAPBOX_CGROUP_ROOT`（可选）：显式指定已委派的 cgroup v2 **空父目录**（子 cgroup 须能出现 `memory.max`/`cpu.max`/`pids.max`）。指定后严格使用该路径，不会回退其它候选；不可写或缺控制器时明确失败。`require` 下 fail-closed；即使 `warn` 也不会在该覆盖失败时悄悄降级 `prlimit`。不要用 `CAPBOX_RUN_DIR` 指定 cgroup（会被运行时覆盖）。WSL 上可在用户切片下预建例如 `.../user@UID.service/capbox-parent`，先 `echo +cpu +memory +pids > cgroup.subtree_control`，再导出 `CAPBOX_CGROUP_ROOT` 指向它。

**不会**用 `RLIMIT_NPROC` 冒充 PIDs。

`CAPBOX_DISK_MAX`（例 `64M`）：在能 `losetup` + `mkfs.ext4` + `mount` 时兑现——把稀疏镜像挂成 ext4，经 `mount --bind -o rw` 的私有 rootfs 树挂到 guest **`/var/lib/capbox-data`**（可用 `CAPBOX_DISK_GUEST_PATH` 覆盖），再 `bwrap --bind` 该树。**不**把宿主块设备当配额盘塞进 guest；限额**只**覆盖该路径，不含整个 rootfs 或 `/workspace`。需要宿主授权（root，或 `sudo -n` / 等价 mount 能力），**不是** rootless。否则 `metrics`/`doctor` 明确 `unavailable`，`require` 模式硬失败，绝不假装已限额。

## 安全档（CAPBOX_SECURITY_PROFILE）

| 档 | 行为 |
|----|------|
| `compat`（默认） | 不削弱现有兼容：全量 capability、无 seccomp |
| `untrusted` | capability drop + **真实** seccomp BPF（libseccomp，含 `unshare`/`setns`/`io_uring_*`）+ 遮盖 `.ssh` 等；多 UID idmap 时跳过 `--disable-userns`。doctor 会说明：**不可信负载不要和 idmap 一起开** |
| `strict` | 更严 seccomp；默认倾向 `ROOTFS_RO=1`（overlay 可用时写 upper） |

`capbox exec --profile untrusted -- …` 可单次覆盖。负向测试见 T30。

## 文件系统与快照

- `CAPBOX_FS_HIDE=rel,…`：相对 `/workspace` 的路径用 tmpfs 遮盖
- `CAPBOX_FS_BINDS=host:/guest:ro|rw`：**仅允许工作区内** host 路径，拒绝任意宿主 bind / `..` 逃逸
- `CAPBOX_ROOTFS_RO=1`：只读根；overlay 实测通过才启用可写层
- `capbox snapshot create|restore` / `capbox image export|import`：tar `--numeric-owner` + SHA256；import 默认旁路不破坏现有 rootfs

## 可观测性

- `CAPBOX_AUDIT=off|summary|full`：JSONL 写入 `.capbox/logs/audit.jsonl`（命令默认可摘要，脱敏 password/token）
- `capbox audit tail|path|clear`、`capbox metrics [--json]`：真实 cgroup/disk/服务状态，无假数据


## 安装

需要 Linux + [`bubblewrap`](https://github.com/containers/bubblewrap)（`bwrap`）。

```sh
# Debian/Ubuntu
sudo apt install bubblewrap
# Alpine: apk add bubblewrap
# Fedora: sudo dnf install bubblewrap
```

**推荐：全局一份模板 + 每项目自动 `.capbox`**

```sh
# 1) 克隆本仓库为全局模板（不当工作区状态）
git clone https://github.com/Sladewww/capbox.git ~/.agents/capbox
ln -s ~/.agents/capbox/bin/capbox ~/.local/bin/capbox   # 确保 ~/.local/bin 在 PATH
# Agent skill（按你的 skills 目录二选一）：
#   ln -s ~/.agents/capbox/skill ~/.agents/skills/capbox
#   ln -s ~/.agents/capbox/skill ~/.dsh/skills/capbox

# 2) 任意项目/会话目录里第一次使用
cd /path/to/your-project
capbox init --distro alpine   # 自动在本目录生成 .capbox/ 并下载 rootfs（官方 tarball，SHA256 钉扎；x86_64 与 aarch64）
capbox init --agent --distro alpine   # 同上，并写成 untrusted + restricted
capbox doctor
capbox exec -- id -u          # → 0
```

持久数据在 **当前项目的 `.capbox/`**（rootfs、config、daemon）。`~/.agents/capbox` 只提供 `bin/`+`lib/`+`skill/` 模板。
也可只脚手架、稍后再下载：`capbox bootstrap`。

离线/开发可选：把仓库直接放进项目的 `.capbox/` 再跑 `init`（效果相同）。

显式指定工作区根：

```sh
capbox --root /path/to/your-project exec -- id -u
# 等价于
CAPBOX_ROOT=/path/to/your-project capbox exec -- id -u
```

> **不要**把「状态工作区」设成 `$HOME` 或 `/`（会把整棵树 RW bind 进容器）。
> 模板可以放在 `~/.agents/capbox`，但请在**项目目录**里执行 `capbox init`，不要在 `$HOME` 下 init。

## 30 秒上手（quickstart）

```sh
capbox bootstrap                 # 在当前目录生成 .capbox/
capbox init --distro alpine      # ~3.4 MB
capbox exec -- id -u             # → 0
```


`init` 幂等。再要 ubuntu：`capbox init --distro ubuntu`（更大），用
`capbox config set CAPBOX_DISTRO ubuntu` 切换。

跨多次调用保活（起服务、留进程）：

```sh
# 必须活过本次调用：优先交给用户 systemd
capbox up --systemd
# 没有 systemd --user 时，用会活下去的后台任务跑（前台阻塞是设计如此）
capbox up
capbox exec --daemon -- sh -c 'nohup sleep 3600 &'
capbox down
```

## 命令速查

| 命令 | 用途 |
|---|---|
| `bootstrap` | 在当前目录脚手架 `.capbox/`（不下载） |
| `init [--distro D] [--from URL] [--force] [--agent]` | 脚手架（如需）+ 安装 rootfs。`--agent` 写 untrusted + restricted |
| `status [--json]` | distro / rootfs / daemon / 网络 |
| `exec [--daemon] [--timeout N] [--cwd DIR] -- CMD` | 容器内执行 |
| `shell [--daemon]` | 交互 shell |
| `pkg install\|remove\|update\|list PKG...` | apk / apt |
| `cp SRC DST` | 宿主 ↔ 容器（`guest:` / `host:`） |
| `up [--systemd]` / `down` / `logs` | 常驻容器。`--systemd` 交给 systemd --user |
| `service start\|stop\|status\|logs\|list` | 配置化服务（`.capbox/services/*.env`） |
| `ls` / `ps` | 容器内目录 / 进程 |
| `doctor` | 自检（有 FAIL 则退出 1） |
| `config get\|set\|list` | 读写配置 |
| `clean [--all]` | 清缓存；`--all` 含 rootfs |

全局选项：`--root DIR`（工作区根）、`--debug`。

退出码：`0` 成功，`1` 一般错误，`2` 用法错误，`3` 常驻容器未运行，`4` rootfs 不存在，
`5` 依赖缺失，`124` 超时；其余透传容器内退出码。

## 配置化服务

在 `.capbox/services/<name>.env` 写纯 `KEY=value`（不会被 source）：

```sh
CMD='nginx -g "daemon off;"'
USER=www-data          # 或 UID=/GID=
CWD=/
REQUIRE_IDMAP=0        # sshd 等需要 setgroups 时设 1
```

```sh
capbox service start nginx
capbox service status nginx
capbox service logs nginx -n 50
capbox service stop nginx
```

`start` 使用独立 bwrap（不依赖 `capbox up`），并去掉 `--die-with-parent` 以便活过启动命令本身。

## 目录结构


```
<project>/
└── .capbox/
    ├── bin/capbox           CLI
    ├── lib/                 common / rootfs / sandbox / daemon / guest
    ├── os/<distro>/         容器的 "/" —— 持久 rootfs
    ├── cache/               下载的 rootfs 压缩包
    ├── run/                 daemon IPC
    ├── state/               resolv.conf 等
    ├── logs/
    └── config.env           KEY=value 白名单（不会被 source）
```

容器内 `/workspace` = 宿主项目目录，双向即时可见。

## 配置

`.capbox/config.env` 只接受 `CAPBOX_*` 的 **KEY=value**（单引号安全形式），**不会**被 shell source。
环境变量优先于文件：

```sh
CAPBOX_DISTRO=alpine        # alpine | ubuntu
CAPBOX_MIRROR=cn            # cn | global | none
CAPBOX_PROXY=               # 空=直连；http(s):// / socks5h://
CAPBOX_NET=host             # host | none | open | restricted
CAPBOX_EXEC_TIMEOUT=600
CAPBOX_IDMAP=auto           # auto | on | off（多 UID；需 newuidmap + subuid）
CAPBOX_EXEC_UID=0           # 默认容器初始 uid；可被 exec --uid 覆盖
CAPBOX_EXEC_GID=0
```

也可用 `capbox config set CAPBOX_PROXY http://127.0.0.1:7890`。

## 安全边界

**容器内是 root，但不是宿主 root。**

- 写 `/` 写的是 `.capbox/os/<distro>/`，不是宿主根。
- 工作区整树 RW bind 到 `/workspace` —— **工作区是信任边界**；不要把 `$HOME` 当工作区。
- `bin/`、`lib/`、`config.env` 对 guest **只读**，防止容器改写 CLI 导致下次宿主执行变成 RCE。
- `capbox cp` 的 guest 路径会做 `realpath` 越界检查，拒绝 `..` 逃出 rootfs。
- 设计前提常常是：宿主本身已在受限沙箱中（工作区外只读、无额外 capability）。
- `CAPBOX_NET=none` 可断网。

Agent 使用说明见 [`AGENTS.md`](AGENTS.md)。

## 测试与 CI

```sh
# 语法检查
bash -n bin/capbox lib/*.sh lib/guest/*.sh

# 测试框架自测（假 CLI，无需 rootfs）
bash test/selftest/run-selftest.sh

# 验收用例（需 bubblewrap；首次会 init alpine）
./test/run.sh                  # T01–T38
./test/run.sh T21 T22            # 安全边界 + 自动脚手架
CAPBOX_TEST_SLOW=1 ./test/run.sh T19   # ubuntu 慢测
CAPBOX_TEST_DAEMON=1 ./test/run.sh T15 T16  # 需先后台 capbox up
./test/slow/run-slow.sh                  # Nginx/Redis/MariaDB/sshd 等真实服务（需已装包的 ubuntu 工作区）
```

GitHub Actions：见 [`.github/workflows/ci.yml`](.github/workflows/ci.yml)。推送后可在仓库 Actions 页查看运行结果。

## 常见问题

**装包时一堆 `chown ... Invalid argument`？**  
若 `doctor` 显示 UID 映射 `multi`，这不应再成批出现；若仍是 `single`/`blocked`，属单 UID 限制。
`capbox pkg install` 结束后会跑 `dpkg --audit` 并明确报告 iU/iF，不会把半截安装当成功。
启用多映射：安装 `uidmap`，确保 `/etc/subuid` 有条目，`capbox config set CAPBOX_IDMAP auto`（默认）。

**`exec --daemon` 返回 3？**  
常驻容器没起。用后台任务跑 `capbox up`。

**`拒绝：工作区解析为危险路径`？**  
工作区等于 `$HOME` 或 `/`。改用项目内 `.capbox/` 或 `capbox --root /path/to/project`。

## License

MIT — see [LICENSE](LICENSE).
