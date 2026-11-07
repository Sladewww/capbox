# CapBox

[English](README.md) | 中文

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4.4%2B-green.svg)](bin/capbox)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](#依赖)
[![Tests](https://img.shields.io/badge/tests-T01–T41-informational.svg)](test/run.sh)
[![CI](https://github.com/Sladewww/capbox/actions/workflows/ci.yml/badge.svg)](https://github.com/Sladewww/capbox/actions/workflows/ci.yml)

项目目录里的一台 root Linux。不用 Docker，不用 sudo。`capbox init` 之后容器里是 uid 0，全部状态就是 `.capbox/`。

AI agent 经常要装系统包、改 `/etc`、编译进 `/usr`。直接在宿主做，要么没权限，要么弄脏系统。外层沙箱里又常常没有 Docker。CapBox 用 [bubblewrap](https://github.com/containers/bubblewrap) 和 user namespace：`os/<distro>/` 是容器的 `/`，工作区挂到 `/workspace`。

- 容器里的 root 不是宿主 root。写 `/` 写的是 `.capbox/os/<distro>/`。
- 每个项目一份 `.capbox/`。Alpine 3.24.4 或 Ubuntu，官方 tarball 按 SHA256 钉扎，x86_64 与 aarch64。
- `capbox init --agent` 设置 `untrusted`、`CAPBOX_NET=none`、`CAPBOX_IDMAP=off` 和 `CAPBOX_RESOURCES_MODE=require`。`pkg install` 与 `pkg update` 仍出网；其它出网必须在当次命令上写 `--net`。
- `.capbox/logs/`（含 `audit.jsonl`）对 guest 只读。

这是共享内核，不是虚拟机。

## 快速开始

需要 Linux 和 `bwrap` **>= 0.12.0**。更旧的版本直接拒绝（退出码 6），`compat` 也不豁免。

```sh
git clone https://github.com/Sladewww/capbox.git ~/.agents/capbox
ln -s ~/.agents/capbox/bin/capbox ~/.local/bin/capbox

cd /path/to/your-project
capbox init --distro alpine          # 或 capbox init --agent --distro alpine
capbox doctor
capbox exec -- id -u                 # 0
```

不要把工作区设成 `$HOME` 或 `/`。整棵树会以读写方式挂到 `/workspace`。

要让进程活过本次调用：优先 `capbox up --systemd`。没有 systemd --user 时，用会活下去的后台任务跑 `capbox up`，然后 `capbox exec --daemon -- …`。

## 文档

| | |
|---|---|
| [Wiki](https://github.com/Sladewww/capbox/wiki) | 运维手册：服务、网络、备份 |
| [快速开始](https://github.com/Sladewww/capbox/wiki/快速开始) | bootstrap、init、doctor、第一个 service |
| [SECURITY.md](SECURITY.md) | 威胁模型 |
| [skill/SKILL.md](skill/SKILL.md) | Agent skill |
| [AGENTS.md](AGENTS.md) | 在本仓库里给 agent 的说明 |

## 网络

| 模式 | 行为 |
|---|---|
| `open`（别名 `host`） | 共享宿主网络。人在键盘前时的默认。 |
| `none` | `bwrap --unshare-net`。容器内无网络。 |
| `restricted` | `--unshare-net` 加域名 allowlist 的 HTTP 代理。原始 TCP/UDP 没有路由。不假装 bwrap 能按域名过滤。 |

未知取值直接失败，不会当成 `open`。名字解析到回环、链路本地（含云元数据）或私网地址时拒绝，除非那个地址自己写在 allowlist 里。

语法和 agent 预设见 [网络与端口](https://github.com/Sladewww/capbox/wiki/网络与端口)。

## 配方

项目根的 `capbox.recipe` 是 `KEY=value`，不会被 source。

```sh
capbox recipe apply    # 写配置，按需 init，再 pkg install
capbox recipe show
```

## 资源限额

`CAPBOX_MEMORY_MAX`、`CAPBOX_CPU_MAX`、`CAPBOX_PIDS_MAX`、`CAPBOX_DISK_MAX` 优先走 cgroup v2。`CAPBOX_RESOURCES_MODE=warn`（默认）在限额落不下去时警告。`require` 失败即关闭。`DISK_MAX` 只覆盖 `/var/lib/capbox-data`，要宿主能挂载，不是 rootless。细节见 [资源限额](https://github.com/Sladewww/capbox/wiki/资源限额)。

`CAPBOX_SECURITY_PROFILE` 为 `compat`（默认）、`untrusted` 或 `strict`。`CAPBOX_LANDLOCK=on|off`；不写时只有 `strict` 开启。Landlock 在挂载之后限制路径，不过滤 TCP 端口。

## 命令

| 命令 | |
|---|---|
| `init [--distro D] [--agent]` | 安装 rootfs。`--agent` 写 untrusted + `NET=none`。 |
| `exec [--daemon] [--net MODE] [--timeout N] -- CMD` | 在容器内执行。 |
| `pkg install`、`update`、`remove`、`list` | apk / apt。会话是 `none` 时，install 和 update 仍会出网。 |
| `up [--systemd] [--net MODE]` / `down` | 常驻容器。 |
| `service start`、`stop`、`status`、`logs`、`list` | `.capbox/services/*.env` 里的服务。 |
| `doctor` | 有 FAIL 则退出 1。bwrap 低于 0.12.0 时退出 6。放行也不会变成 PASS。 |

退出码：`0` 成功，`1` 错误，`2` 用法，`3` 常驻容器未运行，`4` 没有 rootfs，`5` 缺依赖，`6` bwrap 基线，`124` 超时。其余是容器内退出码。

## 服务

`.capbox/services/<name>.env` 是 `KEY=value`，不会被 source。宿主服务控制文件保存在工作区外的私有目录；日志用 `capbox service logs NAME` 读取。`CMD` 是要执行的命令，不是环境变量。`USER`、`CWD` 和其它键在 `--clearenv` 之后 `--setenv`。`service start` 是独立的 bwrap，不依赖 `capbox up`。

见 [服务运维](https://github.com/Sladewww/capbox/wiki/服务运维)。

## 边界

- 工作区是信任边界。不要把 `$HOME` 当工作区。
- `bin/`、`lib/`、`config.env` 对 guest 只读，避免容器改写宿主下次会执行的 CLI。
- `logs/` 对 guest 只读。`FS_BINDS` 不能挂到这个目录上。`audit.jsonl` 是符号链接或目录时拒绝启动。
- `capbox cp` 拒绝用 `..` 逃出 rootfs。
- 常见前提是：宿主自己已经在沙箱里。

## 测试

```sh
bash -n bin/capbox lib/*.sh lib/guest/*.sh
bash test/selftest/run-selftest.sh
./test/run.sh
```

CI：[`.github/workflows/ci.yml`](.github/workflows/ci.yml)。

## License

MIT — 见 [LICENSE](LICENSE)。
