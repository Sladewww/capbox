---
name: capbox
description: 工作区内持久化的 root Linux 系统，用 capbox 命令驱动。要装系统软件包、要 root 或 mount、要跑不宜污染宿主的命令、要跨调用保留状态的系统环境、要长期存活的容器服务时用它。不可信命令用 capbox init --agent（untrusted + NET=none）。pkg install 和 pkg update 会出网；其它出网要在当次命令加 --net。常驻进程用 capbox up --systemd，没有用户 systemd 时才放进活过工具调用的后台任务。只读查看、文件编辑、宿主一条命令能做完的事直接用 bash，不要绕道。
---

# CapBox

工作区里的一台 Linux。`init --agent` 之后是加固档：容器内仍是 root。`untrusted` 保留 `CAP_SYS_ADMIN`，靠 seccomp 挡住 mount/unshare/io_uring；工作区里的 `.ssh` `.gnupg` `.aws` `.azure` `.kube` `.docker` 被遮住。`strict` 在此之上默认开启 Landlock（`CAPBOX_LANDLOCK` 未设置时；`on`/`off` 可显式覆盖），在挂载完成之后限制 VFS，不限制 TCP 端口。
状态落在 `.capbox/os/<distro>/`，是工作区里的普通目录，所以跨调用、跨会话都在。
人工调试可以不带 `--agent`（默认 `compat` + `NET=open`，全 capability、无 seccomp）。不要用默认档跑来路不明的命令。

入口：把 CapBox 装到 PATH（一份模板），或用项目内 `.capbox/bin/capbox`。
**项目数据在当前会话/项目的 `.capbox/`**；宿主控制文件在工作区外，升级备份在持久宿主私有状态目录。PATH 上的模板负责为各项目提供运行文件。

- 会话里还没有 `.capbox` 时：`capbox init --agent`（脚手架到当前目录的 `.capbox/`，下载 rootfs，并写成 untrusted + NET=none）。
- 也可先 `capbox bootstrap` 只脚手架、不下载。
- 不要把仓库克隆进每个项目当作唯一安装方式；也不要把模板树本身当成工作区（尤其不要装在 `$HOME` 下当全局状态目录）。

## 先判断：这条任务该不该用

**直接用宿主 bash / 文件工具**（默认选择）：

- 读文件、grep、glob、改代码
- 跑一两条普通命令看输出
- 宿主已有它需要的工具

**用 CapBox**：

- 要装系统级软件包、要 root、要改 `/etc`、要 mount
- 命令可能污染宿主：装全局依赖、改系统配置、跑来路不明的脚本
- 要一个反复进入、状态跨会话保留的环境
- 要一个活过单次工具调用的服务或进程

判据：如果宿主 bash 一条命令就能得到同样的输出，用宿主。CapBox 是为了解决"宿主做不到或不该做"，不是为了提高仪式感。

## 硬约束：工具调用结束可能会杀掉整棵进程树

不少 agent 的 bash 工具在外层加了 `bwrap --die-with-parent`。调用返回时，那棵树里的进程都会死，包括 `nohup`、`setsid`、`disown`。这条决定了常驻容器怎么起：

| 需求 | 做法 |
|---|---|
| 跑完就走的命令 | `capbox exec -- CMD` |
| 活过这次工具调用的容器 | `capbox up --systemd`（用户 systemd 在工具沙箱外面）。没有 user bus 时，把 `capbox up` 放进该工具提供的后台任务（例如 `run_in_background: true`），不要在前台调用里 `&` |
| 活过多次调用的单个服务 | `capbox service start`（独立 bwrap，不依赖 `up`） |
| 多次 `exec --daemon` 共享同一台机 | 先让 `up` 活着，再 `capbox exec --daemon -- …` |

判据不是"能不能用 `&`"，而是**进程挂在谁的树上**。一次性 `exec` 里的 `nohup CMD &` 挂在这次调用上，调用结束就没了。`exec --daemon` 里的后台进程挂在守护容器上，守护容器还在就还在。

```sh
# 优先：脱离当前进程树
capbox up --systemd
# 没有 systemd --user 时，用工具的后台任务，命令体只有这一条：
capbox up
```

之后在任意调用里 `capbox exec --daemon -- CMD` 都能连上同一个容器。用 `capbox down` 收尾（`--systemd` 起的会停掉对应的 user unit）。

判断容器是否还活着，看 `capbox status --json` 的 `daemon.running`。

只是想在容器里算完就走，忽略本节。

## 1. 初始化（每个工作区一次）

首次在该会话/项目使用时（哪怕目录里还没有 `.capbox`）：

```sh
capbox init --agent --distro alpine
capbox doctor
```

`init --agent` 会脚手架（如需）、下载 rootfs，并写入 `untrusted`、`NET=none`、`IDMAP=off`、`RESOURCES_MODE=require`。内存、CPU、进程额度需单独设置，并用 doctor/metrics 核对兑现。
`pkg install` 和 `pkg update` 会出网。`exec`、`shell`、`up`、`service` 默认没有网。需要出网时在当次命令声明，不根据 `pip`、`npm`、`git` 这些名字自动打开：

```sh
capbox config set CAPBOX_NET_ALLOW 'example.com,*.python.org,github.com:22'
capbox exec --net restricted -- pip install -q requests
capbox up --net restricted
```

`--net open` 是当次共享宿主网络。`--net restricted` 用上面的 allowlist：没写端口只放行 80/443；子域要显式写 `*.example.com`；任意端口加 `:*`。显式网段放行后，端口规则仍然生效。解析到非 global 地址会被拒绝：回环、链路本地、私网、CGNAT（`100.64.0.0/10`）、IPv4-mapped。那个地址自己在 allowlist 里才放行。原始 TCP 没有路由，只有走注入的 `http_proxy` 才能出去。`--net` 不写进 config.env。`shell --daemon` 改不了已经起来的守护容器的网络。

可信的人工调试可用 `capbox init --trusted --distro alpine`（`compat` + `NET=open`）。不要把这个默认档当成 agent 的档。

`init` 会：① 若缺 `.capbox/bin`/`lib`，从 PATH 上的 CapBox 模板脚手架到 `$PWD/.capbox`；② 下载并解包 rootfs。
不要先手动 `git clone` 进项目——那只是可选的开发/离线安装方式。

**完成判据**：`doctor` 没有 FAIL（WARN 可以有）。`CAPBOX_NET=none` 时 doctor 报告容器内无网络，这是预期。要出网再写 allowlist 并用 `--net restricted`。`capbox status --json` 里 `rootfs_bytes` 大于 0。

`init` 幂等，rootfs 已存在时再跑不会重复下载。`ubuntu` 更大更慢，非必要不用；用 `--distro ubuntu` 换。
缺 rootfs 时 `exec`/`pkg` 默认退出 4 并提示 init；若设置 `CAPBOX_AUTO_INIT=1` 才会在首次 exec 时自动 init（默认关，避免惊喜下载）。

## 2. 跑一次性命令（默认路径）

```sh
capbox exec -- id -u                          # 期望 0
capbox exec -- sh -c 'ls /etc | head'         # 任意 shell 片段
capbox exec --timeout 1800 -- make -j8        # 长任务显式放宽
capbox exec --cwd /root -- pwd                # 指定容器内工作目录
```

- 容器内命令写在 `--` 之后；`--timeout` / `--cwd` / `--daemon` 是给 capbox 的，别混进命令里。
- 默认超时 600 秒，超时返回 **124**。
- stdout 只有容器内命令的输出，可以直接管道消费；capbox 自己的日志走 stderr。
- 退出码原样透传容器内命令的退出码。

**完成判据**：拿到容器内的输出，且退出码是你预期的那个。

本机已有 `docker save` 或 OCI 镜像文件时，用 `capbox image docker import FILE --name NAME`，再 `capbox exec --image NAME -- CMD`。`capbox image docker run FILE -- CMD` 会按镜像的 Entrypoint/Cmd/User/Env 启动。两条路径都不连接 Docker daemon，也不替换项目的 Alpine/Ubuntu rootfs。不可信镜像加 `--profile untrusted`。

## 3. 装系统软件包

```sh
capbox pkg update
capbox pkg install curl git python3
capbox exec -- curl --version
# curl 访问网络要当次声明；装包本身不用
capbox exec --net restricted -- curl -fsS --max-time 10 https://example.com/
```

**完成判据**：`exec -- <cmd> --version`（或等价命令）能跑通。

`pkg` 已按发行版分派并处理好 `APT::Sandbox::User=root` 与镜像源。
`chown ... Invalid argument` **不是**一律可以忽略。先看 `capbox doctor` 的 UID 映射：`multi` 时这是真失败；`single` / `blocked` 时才是单 uid 映射的边界，换 uid 会 EINVAL。细节见 `reference/troubleshooting.md`。

## 4. 常驻容器（需要跨调用保留进程/服务时才用）

只有在"要留个东西一直跑"时才走这节，否则用第 2 节。

```sh
# 优先
capbox up --systemd
```

```sh
# 没有 systemd --user 时：用后台任务，命令只有这一条
capbox up
```

```sh
# ② 之后的调用都在普通前台 bash 里：
capbox status                                 # 看 daemon 是否 running
capbox exec --daemon -- id -u                 # 走常驻容器执行
capbox exec --daemon -- sh -c 'ps ax | head'
capbox logs -n 50                             # 守护容器日志
capbox down                                   # 用完停掉
```

- `up` 不带 `--systemd` 时不返回是设计如此：它活着，容器就活着。
- `--systemd` 提交单元后就会返回；容器活在 user systemd 里，不活在这次工具调用里。
- 没起容器就用 `--daemon` 会返回 **3**，这是状态提示不是故障：去起 `up`。
- `--daemon` 的所有请求进的是**同一个**容器，`/root` 下的写入在后续 `--daemon` 调用里都读得到。
- 常驻容器的 `/tmp`、`/run` 由 `.capbox/run/tmp/` 承载，容器活着期间保留。
- **`down` 不是"关个 shell"，是"停整台机"**：容器内所有进程一起没，包括你起的服务。只想停单个服务用 `exec --daemon -- pkill NAME`。
- 这里 `nohup CMD &` 只有在守护容器已经活着时才是对的。一次性 `exec` 里则随那次调用死掉。

**完成判据**：`status` 显示 running → `exec --daemon -- echo ok` 返回 0 → 用完 `down` 后 `status` 显示 stopped。

## 5. 交换产物

容器内 `/workspace` 就是宿主工作区本体，双向、即时、无需拷贝。

- 产物一律写 `/workspace/...`，宿主立刻可见，后续 agent 也读得到。
- 容器内**非** `/workspace` 的路径用 `cp` 取放，容器侧路径以 rootfs 为根，或写 `guest:` / `host:` 前缀：

```sh
capbox cp guest:/root/report.txt ./report.txt
capbox cp ./data.csv guest:/root/data.csv
```

## 持久化契约：什么留得住

| 位置 | 生命周期 |
|---|---|
| `/`（rootfs，宿主 `.capbox/os/<distro>/`） | 持久。装的包、`/etc` 改动、`/root` 下的文件，跨调用跨会话都在 |
| `/workspace` | 宿主工作区本体，双向即时。产物放这里 |
| `/tmp`、`/run`（一次性 exec） | 每次调用新建 tmpfs，返回即丢 |
| `/tmp`、`/run`（`--daemon`） | 由 `.capbox/run/tmp/` 承载，容器活着期间保留 |
| 进程 | 一次性 exec 的进程随调用死；要跨调用 → 常驻容器或 background job |

一句话：**装的包和 `/root` 留得住，一次性 exec 的 `/tmp` 留不住，产物写 `/workspace`。**

## 退出码 → 下一步动作

| 码 | 含义 | 你要做的 |
|---|---|---|
| 0 | 成功 | — |
| 1 | 一般错误（内部失败、下载失败） | 读 stderr，跑 `capbox doctor` 定位 |
| 2 | 用法错误 | 检查子命令/选项拼写，别重试同一行 |
| 3 | 常驻容器未运行 | `capbox up --systemd`，或把 `capbox up` 放进后台任务 |
| 4 | rootfs 不存在 | `capbox init` |
| 5 | 依赖缺失（如 `bwrap`） | 环境问题，重试无用，报告给用户 |
| 6 | 安全基线不满足（bwrap 低于 0.12.0） | 升级 bubblewrap。接受风险才用当次 `--allow-old-bwrap`，或 `config set --yes CAPBOX_ALLOW_OLD_BWRAP 1`。不要 export 变量绕过。`doctor` 仍是 FAIL |
| 124 | 容器内命令超时 | 加大 `--timeout`，或改成 background job |
| 其他 | 容器内命令自己的退出码，原样透传 | 按那条命令的语义处理 |

## 低于本页面的细节

这两份按需读，不要一开始就全读：

- `reference/recipes.md` —— 要**做成某个东西**时读：起 nginx / python 服务（优先 `service`；共享守护容器时才 `up`）、装 Node/Python/Go 工具链、长任务与超时策略、选 alpine 还是 ubuntu、构建产物带回工作区、投入真实任务前的一次性环境验证。
- `reference/troubleshooting.md` —— 命令**出了意外**时读：装包的 chown 警告、CA 证书、apt 沙箱、bwrap 参数坑、代理与镜像源、网络不通、root 权限到底能到哪、`doctor`/`status`/`logs` 逐项怎么读、清理磁盘。

其余命令（`shell` / `ls` / `ps` / `distros` / `config` / `clean`）用得少，需要时跑 `capbox --help` 看当前选项，不要凭记忆写。

## 改 `.capbox/lib/` 下任何脚本时

**跑起来验证，不要只看 diff。** 本项目的实测统计：15 个已修 bug **没有一个**是靠通读代码发现的，
全部来自「运行 + 观察异常」。原因是 shell 的正确性依赖运行时语义，代码里看不出来：

- `os/alpine/bin/sh` 是容器内绝对符号链接，宿主侧重解析会误判 rootfs 缺失
- 每次 bash 调用是独立 PID namespace，`kill -0` 判活会命中自己
- 心跳/状态文件有写入顺序窗口，清早了会让服务端把 `hb` 写回来
- `stop_wait` 若被当循环次数用，只等 6 秒却打印「上限 30s」——日志在撒谎

改完至少跑一遍：`capbox doctor` → `exec -- id -u` → 起 `up` → `exec --daemon` → `down`。
涉及 daemon 的用例要独占窗口（先确认 `status` 为 false 且 `run/daemon` 空），并校验 `iid` 前后一致——
否则分不清「daemon 挂了」和「被别人清了」。

（路径相对本 skill 目录。）


## 运行文件升级与配置检查

升级项目之前，先用旧 CLI 停止所有 service/daemon 和其它 exec；再从完整且位于工作区外的新模板调用 `capbox --root PROJECT upgrade check|apply --from TEMPLATE`。不要只更新模板后假定项目副本已升级。apply 会成套替换 bin/lib（包含自定义修改）；先检查差异。失败或中断后可从完整模板运行 `upgrade rollback`，备份在持久宿主状态目录。rootfs 与业务数据需单独迁移。

使用 `recipe check` 校验配方。未知键、重复键、无效行或非法值会导致失败，校验失败不写回部分配置。严格包锁用 `image lock save|verify|restore`；`recipe apply --locked FILE` 按精确版本重建并校验。上游版本不可用时明确失败，不做无版本回退。
