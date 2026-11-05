---
name: capbox
description: 工作区内持久化的 root Linux 系统，用 capbox 命令驱动。要装系统软件包、要 root 或 mount、要跑不宜污染宿主的命令、要跨调用保留状态的系统环境、要长期存活的容器服务时用它；常驻进程只能起在 DSH 后台 job 里。只读查看、文件编辑、宿主一条命令能做完的事直接用 bash，不要绕道。
---

# CapBox

工作区里的一台 Linux。容器内 `uid=0` 且 capability 全量：能 mount、能装包、能改任何文件。
状态落在 `.capbox/os/<distro>/`，是工作区里的普通目录，所以跨调用、跨会话都在。

入口：把 CapBox 装到 PATH（一份模板），或用项目内 `.capbox/bin/capbox`。
**状态永远在当前会话/项目目录的 `.capbox/`**，不是 PATH 上那份模板。

- 会话里还没有 `.capbox` 时：直接 `capbox init`（会从已安装模板脚手架 `bin/`/`lib/`/`skill/` 到当前目录的 `.capbox/`，再下载 rootfs）。
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

## 硬约束：每次 bash 调用结束都会杀掉整棵进程树

DSH 的 bash 工具每次调用都包一层 `bwrap --die-with-parent`，调用返回时杀掉**那棵树**。这条决定了一切：

| 需求 | 做法 |
|---|---|
| 跑完就走的命令 | `capbox exec -- CMD`。进程随调用结束而死，正确 |
| 活过多次调用的容器 | bash 工具 `run_in_background: true` 跑 `capbox up`（它前台阻塞、不返回，是正常的） |
| 活过多次调用的服务 | `run_in_background: true` 跑 `capbox up`，再 `capbox exec --daemon -- sh -c 'nohup CMD > /workspace/x.log 2>&1 &'` |
| 兜底（少一层间接） | 整条服务命令扔进 background job：`run_in_background: true` + `capbox exec -- CMD` |

判据不是"能不能用 `&`"，而是**进程挂在谁的树上**：

- 一次性 `exec` 里 `nohup CMD &` → 挂在那次调用的树上 → **必死**。`setsid`、`disown` 也救不回来，杀的是整棵树。
- `exec --daemon` 里 `nohup CMD &` → 挂在**守护容器**的树上，而守护容器由 DSH background job 托管 → **跨调用存活**。

所以常驻的东西，父进程链必须最终接到一个 DSH background job 上。细节见 `reference/recipes.md`。

**实测补充**：常驻容器的存活取决于**承载它的 job 是否还活着**，而不是「每次调用结束就死」。
正确做法是用 bash 工具的 `run_in_background: true` 起 `capbox up`（它前台阻塞、永不返回，这是正常的）：

```sh
# 用 run_in_background 起，命令体只有这一条
capbox up
```

之后在任意调用里 `capbox exec --daemon -- CMD` 都能连上同一个容器（实测跨多次调用稳定存活，
8 并发无串扰）。用 `capbox down` 或结束该后台 job 来收尾。

**唯一的坑**：不要用 `nohup ... &` / `setsid ... &` 在普通前台调用里起 `up` ——
那次调用一结束，`--die-with-parent` 就会杀掉整棵进程树。

判断容器是否还活着，看 `capbox status --json` 的 `daemon.running`；若为 false，
查 `run/daemon/daemon.log` 有没有「收到停止请求」：有 = 有人正常停过它，没有 = 进程被强杀。

只是想在容器里算完就走，忽略本节。

## 1. 初始化（每个工作区一次）

首次在该会话/项目使用时（哪怕目录里还没有 `.capbox`）：

```sh
capbox init --distro alpine
capbox doctor
```

`init` 会：① 若缺 `.capbox/bin`/`lib`，从 PATH 上的 CapBox 模板脚手架到 `$PWD/.capbox`；② 下载并解包 rootfs。
不要先手动 `git clone` 进项目——那只是可选的开发/离线安装方式。

**完成判据**：`doctor` 每行 PASS 且退出 0；`capbox status --json` 里 `rootfs_bytes` 大于 0。

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

## 3. 装系统软件包

```sh
capbox pkg update
capbox pkg install curl git python3
capbox exec -- curl --version
```

**完成判据**：`exec -- <cmd> --version`（或等价命令）能跑通。

`pkg` 已按发行版分派并处理好 `APT::Sandbox::User=root` 与镜像源。
装包时 `dpkg`/`apk` 打的 `chown ... Invalid argument` 警告**是本环境的正常现象**（userns 只映射一个 uid），忽略它，不要因为警告改命令或反复重试。

## 4. 常驻容器（需要跨调用保留进程/服务时才用）

只有在"要留个东西一直跑"时才走这节，否则用第 2 节。

```sh
# ① bash 工具 run_in_background: true，命令只有这一条：
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

- `up` 不返回是设计如此：它活着，容器就活着；background job 结束，容器就没了。
- 没起容器就用 `--daemon` 会返回 **3**，这是状态提示不是故障：去起 `up`。
- `--daemon` 的所有请求进的是**同一个**容器，`/root` 下的写入在后续 `--daemon` 调用里都读得到。
- 常驻容器的 `/tmp`、`/run` 由 `.capbox/run/tmp/` 承载，容器活着期间保留。
- **`down` 不是"关个 shell"，是"停整台机"**：容器内所有进程一起没，包括你起的服务。只想停单个服务用 `exec --daemon -- pkill NAME`。
- 这里 `nohup CMD &` 是**对**的：它挂在守护容器树上，而守护容器由 background job 托管。一次性 `exec` 里则必死（见上面的硬约束）。

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
| 3 | 常驻容器未运行 | 用 background job 起 `capbox up` |
| 4 | rootfs 不存在 | `capbox init` |
| 5 | 依赖缺失（如 `bwrap`） | 环境问题，重试无用，报告给用户 |
| 124 | 容器内命令超时 | 加大 `--timeout`，或改成 background job |
| 其他 | 容器内命令自己的退出码，原样透传 | 按那条命令的语义处理 |

## 低于本页面的细节

这两份按需读，不要一开始就全读：

- `reference/recipes.md` —— 要**做成某个东西**时读：起 nginx / python 服务（完整四步序列 + 三条配套约束）、装 Node/Python/Go 工具链、长任务与超时策略、选 alpine 还是 ubuntu、构建产物带回工作区、投入真实任务前的一次性环境验证。
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

