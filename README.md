# CapBox

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4.4%2B-green.svg)](bin/capbox)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](#)
[![Tests](https://img.shields.io/badge/tests-T01–T22-informational.svg)](test/run.sh)
[![CI](https://github.com/Sladewww/capbox/actions/workflows/ci.yml/badge.svg)](https://github.com/Sladewww/capbox/actions/workflows/ci.yml)

工作区里的一台 Linux。不需要 Docker、不需要 sudo。`capbox init` 之后，你就有了一个
**在容器内拥有完整 root 权限** 的持久环境 —— 全部状态就是项目下的 `.capbox/` 目录。

<p align="center">
  <img src="docs/assets/demo-commands.gif" alt="CapBox common commands demo" width="880" />
</p>

## 为什么会有这个东西

AI agent 经常需要「只有 root 才能做」的事：装系统包、改 `/etc`、挂载、编译到 `/usr`。
直接在宿主做要么没权限，要么弄脏系统；Docker 在部分受限环境又跑不了。

CapBox 用 `bwrap`（bubblewrap）+ user namespace：把 `os/<distro>/` bind 成容器的 `/`，
容器内 `id -u` 为 0 且 capability 全量；工作区挂到 `/workspace`。适合已经跑在外层沙箱里的 coding agent。

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
capbox init --distro alpine   # 自动在本目录生成 .capbox/ 并下载 rootfs
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

<p align="center">
  <img src="docs/assets/demo-quickstart.gif" alt="CapBox quickstart demo" width="880" />
</p>

常用命令见上方第一张演示 GIF（`exec` / `pkg` / `cp` / `status`）。

`init` 幂等。再要 ubuntu：`capbox init --distro ubuntu`（更大），用
`capbox config set CAPBOX_DISTRO ubuntu` 切换。

跨多次调用保活（起服务、留进程）：

```sh
# 必须在后台任务里跑；前台阻塞是设计如此
capbox up
capbox exec --daemon -- sh -c 'nohup sleep 3600 &'
capbox down
```

## 命令速查

| 命令 | 用途 |
|---|---|
| `bootstrap` | 在当前目录脚手架 `.capbox/`（不下载） |
| `init [--distro D] [--from URL] [--force]` | 脚手架（如需）+ 安装 rootfs |
| `status [--json]` | distro / rootfs / daemon / 网络 |
| `exec [--daemon] [--timeout N] [--cwd DIR] -- CMD` | 容器内执行 |
| `shell [--daemon]` | 交互 shell |
| `pkg install\|remove\|update\|list PKG...` | apk / apt |
| `cp SRC DST` | 宿主 ↔ 容器（`guest:` / `host:`） |
| `up` / `down` / `logs` | 常驻容器 |
| `ls` / `ps` | 容器内目录 / 进程 |
| `doctor` | 自检（有 FAIL 则退出 1） |
| `config get\|set\|list` | 读写配置 |
| `clean [--all]` | 清缓存；`--all` 含 rootfs |

全局选项：`--root DIR`（工作区根）、`--debug`。

退出码：`0` 成功，`1` 一般错误，`2` 用法错误，`3` 常驻容器未运行，`4` rootfs 不存在，
`5` 依赖缺失，`124` 超时；其余透传容器内退出码。

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
CAPBOX_NET=host             # host | none
CAPBOX_EXEC_TIMEOUT=600
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
./test/run.sh                  # T01–T22
./test/run.sh T21 T22            # 安全边界 + 自动脚手架
CAPBOX_TEST_SLOW=1 ./test/run.sh T19   # ubuntu 慢测
CAPBOX_TEST_DAEMON=1 ./test/run.sh T15 T16  # 需先后台 capbox up
```

GitHub Actions：见 [`.github/workflows/ci.yml`](.github/workflows/ci.yml)。推送后可在仓库 Actions 页查看运行结果。

## 演示 GIF

源文件在 [`docs/assets/`](docs/assets/)。有 [vhs](https://github.com/charmbracelet/vhs) 时：

```sh
vhs docs/tapes/quickstart.tape
```

否则：

```sh
bash docs/assets/render-demo-gifs.sh   # 需要 Pillow + ffmpeg
```

## 常见问题

**装包时一堆 `chown ... Invalid argument`？**  
正常。只映射一个 uid，不影响安装。看退出码即可。

**`exec --daemon` 返回 3？**  
常驻容器没起。用后台任务跑 `capbox up`。

**`拒绝：工作区解析为危险路径`？**  
工作区等于 `$HOME` 或 `/`。改用项目内 `.capbox/` 或 `capbox --root /path/to/project`。

## License

MIT — see [LICENSE](LICENSE).
