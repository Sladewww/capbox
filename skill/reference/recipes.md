# CapBox 配方

SKILL.md 只留了指针。这里是"要做一个具体东西"的成套步骤。
所有命令都在工作区根目录下执行；写成 `.capbox/bin/capbox`。

---

## 起一个长期服务（nginx / python / 任意 daemon）

这是唯一需要常驻容器的场景。核心问题不是"怎么起服务"，是"进程的父进程必须活过单次工具调用"。

### 首选：daemon 容器 + 容器内后台化

服务挂在**守护容器**的进程树上。守护容器由 DSH background job 托管，所以客户端 `exec` 调用结束、后续多次独立工具调用，都不影响它。

完整序列，四步都要走：

```sh
# ① background job（run_in_background: true），命令仅此一条。不要加 nohup/&。
.capbox/bin/capbox up
```

```sh
# ② 等它就绪：轮询到 running 再往下（up 是阻塞的，别在同一个调用里等）
.capbox/bin/capbox status
# daemon.running 不是 true → 等几秒重查；仍是 false 就去看 logs，别起服务
```

```sh
# ③ 起服务。三条硬规则：nohup 后台化、日志重定向进 /workspace、command 里别等它返回。
.capbox/bin/capbox pkg install nginx
.capbox/bin/capbox exec --daemon -- sh -c \
  'nohup nginx -g "daemon off;" > /workspace/.capbox/logs/nginx.log 2>&1 & echo started'
```

```sh
# ④ 验证（关键：不要不看就宣布完成）
sleep 1
.capbox/bin/capbox exec --daemon -- sh -c 'ps ax | grep -c "[n]ginx"'
.capbox/bin/capbox exec --daemon -- curl -fsS --max-time 5 http://localhost:80/ | head -3
```

**完成判据**：`ps` 数 ≥ 1，**且**容器内 `curl` 拿到响应。两条都成立才算起来。
只有 `started` 回显不算 —— 后台化命令的退出码永远是 0，它只说明 shell 派生了子进程。

**为什么这条不违反 die-with-parent**：被杀的是"那次 bash 调用"派生的树。这里服务是守护容器（属于另一个 background job）的子孙，不在那次 `exec` 的树里。反过来，一次性 `exec` 里这样写必死。

三条配套约束，缺一就埋坑：

- **日志必须进 `/workspace`**。容器内 `/tmp`、`/root` 对 agent 不透明，宿主读不到。`/workspace` 是双向通道。
- **必须先 `up` 且确认 running**，否则 `exec --daemon` 返回 3，服务根本没起。
- **`capbox down` 会连服务一起杀**（服务就在守护容器的进程树里）。`down` 不是"关个 shell"，是"停整台机"。只想停单个服务用 `pkill`。

**端口可达性**：先用容器内自测（`exec --daemon -- curl localhost:PORT`）——这条永远成立。
`CAPBOX_NET=host`（默认）时容器不隔离网络命名空间，宿主 `127.0.0.1:PORT` 通常也能直连；
`CAPBOX_NET=none` 时 `--unshare-net` 生效，**两边都不通**，此时任何 curl 失败都不是服务的问题，先去 `capbox config list` 看网络模式。

### 备选：background job 前台跑服务

只有当上面的后台化确实没存活（④ 的 `ps` 数是 0）才用这个 —— 少一层间接，只依赖"background job 活着"这一个已验证事实：

```sh
# run_in_background: true，命令是：
.capbox/bin/capbox exec -- nginx -g 'daemon off;'
```

service 进程就是这个 job 的前台进程。验证方式同上。代价：一个服务占一个 background job，多个服务要多个 job。

### 停服务

```sh
.capbox/bin/capbox exec --daemon -- sh -c 'pkill nginx'   # 只停这一个服务
.capbox/bin/capbox down                                    # 停整台机，容器内所有进程一起没
```

**`down` 会杀掉容器内全部进程，包括你起的服务**。这是最常见的误判：以为 `down` 只是关掉一个壳。
只想停单个服务用 `pkill`；确认整台机不再需要，再 `down`。

**完成判据**：容器内 `curl localhost:PORT` 失败、`ps` 对应进程归零。

---

## Python HTTP 服务（最常用的临时服务）

```sh
.capbox/bin/capbox up                                  # ① background job，仅此一条
.capbox/bin/capbox status                              # ② 确认 daemon.running: true
```

```sh
# ③ alpine 需要先装 python3；cd /workspace 是刻意的，服务根目录用工作区
.capbox/bin/capbox pkg install python3
.capbox/bin/capbox exec --daemon -- sh -c \
  'cd /workspace && nohup python3 -m http.server 8000 > /workspace/.capbox/logs/http.log 2>&1 & echo started'
```

```sh
# ④ 验证
sleep 1
.capbox/bin/capbox exec --daemon -- sh -c 'ps ax | grep "[h]ttp.server"'
.capbox/bin/capbox exec --daemon -- curl -fsS --max-time 5 http://localhost:8000/ | head -3
```

**完成判据**：`ps` 有 http.server 进程，且容器内 `curl` 返回 HTML。
`cd /workspace` 让服务吐出的文件直接落在工作区，宿主随时能看。

---

## 工具链安装

装完**必须**验证版本，装包成功 ≠ 工具可用（`PATH`、动态库、符号链接都可能错）。

### Node.js

alpine 的 node 在 `community` 源里（`init` 已配好）。

```sh
.capbox/bin/capbox pkg install nodejs npm
.capbox/bin/capbox exec -- sh -c 'node -v && npm -v'
.capbox/bin/capbox exec -- npm config set registry https://registry.npmmirror.com
```

**完成判据**：`node -v` 打印版本号。要更新的版本时用 `n` 或官方 tarball，别指望 apk 的版本。

### Python

```sh
.capbox/bin/capbox pkg install python3 py3-pip
.capbox/bin/capbox exec -- sh -c 'python3 -V && pip3 -V'
.capbox/bin/capbox exec -- pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
```

alpine 上 `pip install` 编译原生扩展会在半路失败（缺 `musl-dev gcc python3-dev`）。遇到再补：

```sh
.capbox/bin/capbox pkg install build-base python3-dev libffi-dev openssl-dev
```

**完成判据**：`python3 -V` 打印版本号；要的包能 `import`。

### Go

```sh
.capbox/bin/capbox pkg install go
.capbox/bin/capbox exec -- go version
.capbox/bin/capbox exec -- sh -c 'export GOPATH=/root/go && go env GOPATH'
```

编译产物写 `/workspace`，否则宿主拿不到。

### 通用纪律

- 工具链装进 rootfs，**跨调用跨会话保留**——装一次就够，不要每次任务重装。
- 装完立刻版本自检，不要假定安装成功。
- 大工具链（ubuntu + 一整套）很慢：优先 alpine，或直接 `run_in_background: true` 跑 `init`/`pkg`，别让前台调用超时。

---

## 长任务与超时

默认超时 600 秒，超时返回 **124**（容器内进程被杀）。

| 任务时长 | 做法 |
|---|---|
| < 10 分钟 | `exec -- CMD`，默认超时即可 |
| 10 分钟 ~ 1 小时 | `exec --timeout 3600 -- CMD` |
| > 1 小时 / 要盯进度 | `run_in_background: true` + `exec -- CMD`，产物写文件，之后读文件 |
| 不想算时长 | 一律 background job，日志重定向到 `/workspace/.capbox/logs/` |

```sh
# background job 里跑长构建
.capbox/bin/capbox exec -- sh -c 'cd /workspace/proj && make -j8 > /workspace/.capbox/logs/build.log 2>&1'
```

**完成判据**：job 结束后读 `build.log` 末尾与 job 退出码，两者一致才算成功。
超时（124）不是失败结论，是"换 background job 重跑"的信号。

---

## 编译 / 构建，产物带回工作区

容器内 `/.capbox/os/...` 之外的一切宿主都看不到，只有 `/workspace` 是通道。

```sh
.capbox/bin/capbox exec -- sh -c 'cd /workspace/proj && ./configure && make -j8'
.capbox/bin/capbox exec -- sh -c 'cp /workspace/proj/out/app /workspace/dist/'
```

**完成判据**：宿主 `ls -l dist/` 看到文件。

不需要拷的情形：直接 `cd /workspace/proj` 在容器里编译 —— 产物就在工作区里，宿主即时可见。**优先这样写。**

---

## 选发行版

| | alpine | ubuntu |
|---|---|---|
| 体积 | 3.4 MB | 30 MB |
| 装包 | `apk`，快 | `apt`，慢 |
| 定位 | 默认选择，够用就用它 | 需要 glibc 二进制、apt 工具链、更完整的包生态时 |
| 注意 | musl libc，glibc 预编译二进制跑不了 | 装包更慢，需要 `ca-certificates` 才能 https |

```sh
.capbox/bin/capbox init --distro ubuntu
.capbox/bin/capbox exec -- ldd --version        # glibc 版本
```

**决定点**：拿到一个预编译好的 glibc 二进制（很多商业工具、部分 release 包）→ 用 ubuntu。其余一律 alpine。

两个发行版可以共存于同一工作区（`os/alpine/`、`os/ubuntu/`），但**同一时刻只有当前 `CAPBOX_DISTRO` 生效**，切换用 `capbox config set CAPBOX_DISTRO ubuntu`。

---

## 一次性环境验证（不确定能不能跑时先跑这个）

在投入真正的任务前，30 秒确认容器真的能用：

```sh
.capbox/bin/capbox doctor
.capbox/bin/capbox exec -- id -u                                            # 0
.capbox/bin/capbox exec -- sh -c 'mount -t tmpfs none /mnt && echo mount-ok' # 全权限证明
.capbox/bin/capbox exec -- sh -c 'echo x > /root/t.txt' && .capbox/bin/capbox exec -- cat /root/t.txt   # 持久化
```

四条全过再往下做。任何一条失败，先按 `reference/troubleshooting.md` 定位，不要把失败带进真实任务里。
