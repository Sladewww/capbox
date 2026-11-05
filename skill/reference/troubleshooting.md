# CapBox 故障排查

SKILL.md 只留了指针，细节在这里。按症状查。

---

## 装包时满屏 `chown ... Invalid argument` 警告

**正常现象，忽略。** 不影响安装结果。

原因：容器是 bwrap userns，`/proc/self/uid_map` 只有一行 `0 1000 1`——**只映射了一个 uid**。
`dpkg`/`apk` 在安装脚本里 `chown root:adm`、`chown root:shadow` 这类第二个 uid 的操作必然 `EINVAL`。
包内容本身已经装好，只是文件属组没改成它想要的值。

**判据**：看 `pkg install` 的退出码和最后一行，不看中间的告警行。
验证方式是装完直接跑一次：

```sh
.capbox/bin/capbox exec -- curl --version
```

**不要**因此做这些事：重试安装、加 `--force`、改用 `fakeroot` 包住 pacman、手动 `chown`。
真要 chown 语义时用 `fakeroot`，但那不是修包安装的手段。

---

## `su` / `setgroups` 报 "can't set groups"

**设计如此。容器内只支持 root 单用户。**

userns 只映射一个 uid，`setgroups` 被 deny。所以：

- 不要 `su otheruser`、不要 `useradd` 后切换、不要 `sudo -u`
- 需要以非 root 身份跑（某些构建脚本拒绝 root）时，用 `fakeroot`，或改脚本
- 一切以 root 跑；需要降权语义的地方 rethink，而不是绕 userns

---

## https 装包失败 / CA 证书报错

**症状**：`apt-get update` 报 `Certificate verification failed`，`curl: (60)`，`apk` 提示证书问题。
原因：精简 rootfs（ubuntu-base）里没有 `/etc/ssl/certs`。

推荐处理顺序：

1. **优先用 http 镜像**。`capbox init` 注入的镜像源通常用 `http://`，避开精简镜像缺 CA 的阶段。这是默认路径，通常什么都不用做。
2. 需要 https 时，先装 CA：`capbox pkg install ca-certificates`（走 http 源），装完 https 就能用。
3. 还不行，说明宿主有证书而容器没有：把宿主 `/etc/ssl/certs` ro-bind 进容器（由 CLI 内部处理）。这是 CLI 的职责，agent 不要手写 bwrap。

**判据**：`capbox exec -- sh -c 'ls /etc/ssl/certs | head -3'` 有输出。

---

## `apt-get` 下载失败

`apt-get` 默认以 `_apt` 用户下载，userns 内该用户起不来，下载阶段直接失败。

CLI 应自己加 `-o APT::Sandbox::User=root`（并写进 `/etc/apt/apt.conf.d/99capbox`），`capbox pkg` 已经处理。

所以：**装包走 `capbox pkg install`，不要自己 `exec -- apt-get install`**。手工调用时记得带这个参数：

```sh
.capbox/bin/capbox exec -- apt-get -o APT::Sandbox::User=root install -y curl
```

---

## `bwrap` 相关报错

这些是 CLI 的实现细节，出现即说明 CLI 有 bug —— **不要自己拼 bwrap 命令**，那会绕过全部约定。已知的坑（供定位）：

| 症状 | 原因 |
|---|---|
| `--hostname` 报错 | 必须同时 `--unshare-uts` |
| `--overlay ... Invalid argument` | 本环境不支持 overlay，直接 bind rootfs 为 `/` |
| 解析 DNS 失败 / `resolv.conf` 报错 | 宿主 `/etc/resolv.conf` 是符号链接（→ `/mnt/wsl/resolv.conf`），不能直接 bind；必须先复制成普通文件到 `.capbox/state/resolv.conf` 再 ro-bind |
| `/run`、`/tmp` 挂不上 | rootfs 里目录不存在，要先 `--dir` 建出来 |
| 进程莫名消失 | `--die-with-parent`（见 SKILL.md 硬约束节） |

处置：跑 `capbox doctor` 拿到 PASS/FAIL 明细，把 FAIL 行连同命令一起报告给用户，不要自己改 `lib/`。

---

## 常驻容器起不来 / 一用就没了

**最常见的原因：`capbox up` 没跑在 DSH background job 里。**

`up` 是前台阻塞的守护进程。用普通 bash 调用跑它，那个调用会挂到超时；用 `nohup ... &` 跑它，调用返回时整棵进程树被杀，容器立刻消失，而 `.capbox/run/daemon/daemon.json` 可能残留。

**正确做法**：bash 工具 `run_in_background: true` 跑 `capbox up` 这一条命令，然后用普通调用做后续操作。

排查顺序：

```sh
.capbox/bin/capbox status            # daemon.running 是什么
.capbox/bin/capbox logs -n 50        # 守护容器自己说了什么
ls .capbox/run/daemon/               # daemon.json / req/ / out/ 是否在
```

- `daemon.json` 在但 `status` 说 stopped：pid 已死，是 stale 状态文件 → `capbox down` 清理，再重新 `up`。
- 有 `req/<id>.sh` 一直不被消费 → 服务端没在跑（同上）。
- 有 `out/<id>.log` 但没 `.rc` → 容器内任务还在跑，或服务端死了。先看 log。

**退出码 3** = 容器未运行，不是故障。

---

## 代理与镜像源

`capbox config list` 看当前生效值；`capbox config set KEY VALUE` 改（写 `.capbox/config.env`）。环境变量优先于文件。

```sh
.capbox/bin/capbox config set CAPBOX_PROXY http://127.0.0.1:7890
.capbox/bin/capbox exec -- printenv http_proxy
```

- 改代理后**一次性 exec 立即生效**；常驻容器要 `down` + 重新 `up` 才拿到新环境变量。
- `socks5://` 代理：`curl`/`git`/`ssh` 支持 `socks5h://`，但 **apt 不原生支持 socks**。ubuntu 上同时配 socks 代理时 `doctor` 会打 WARN。改用 http 代理。
- 镜像源选错（慢、超时）：`capbox distros` 看支持的发行版与镜像 URL；`CAPBOX_MIRROR=global` 换官方源，`none` 表示不动容器内已配好的源。
- 国内已验证可达的镜像（tuna / aliyun / ustc / npmmirror / pypi-tuna）。**容器内 pip/npm 不走 `capbox pkg` 的镜像注入**，要自己配：

```sh
.capbox/bin/capbox exec -- pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
.capbox/bin/capbox exec -- npm config set registry https://registry.npmmirror.com
```

---

## 网络不通

```sh
.capbox/bin/capbox exec -- sh -c 'cat /etc/resolv.conf'
.capbox/bin/capbox exec -- curl -I --max-time 10 https://mirrors.tuna.tsinghua.edu.cn
.capbox/bin/capbox config list          # CAPBOX_NET 是否为 none
```

`CAPBOX_NET=none` 时容器被 `--unshare-net`，**没有网络是预期行为**。需要网络就设回 `host`。

---

## root 权限的真实边界

容器内 `id -u` 是 0 且 `CapEff` 全量，但这不是宿主 root：

- **容器内**：能写 rootfs 任意位置、能 `mount -t tmpfs`、能改 `/etc`、能装包 —— 真的能。
- **碰不到宿主**：userns 隔离。容器内写 `/` 写的是 `.capbox/os/<distro>/`，不会写到宿主 `/`。
- **能力上限受宿主 DSH 沙箱约束**：宿主本身已在 bwrap userns 内（`CapEff=0`），工作区外只读。所以容器内也写不到工作区外的宿主路径。
- **不能加载内核模块、不能改宿主 sysctl、不能提权到宿主 root**。

判据：`capbox exec -- id -u` 是 0，且 `capbox exec -- sh -c 'chmod 4755 /tmp/x'` 成功 —— 这就是全部权限，没有更多。

---

## `doctor` 逐项解读

`doctor` 退出 0 才代表环境可用（有 FAIL 就退出 1）。

| 检查项 | FAIL 说明与处置 |
|---|---|
| bwrap 可用 | 环境缺依赖（退出码 5）。重试无用，报告用户 |
| userns 全权限 | 沙箱配置问题，容器内拿不到 `--cap-add ALL`。报告用户 |
| rootfs 存在 | 还没 `init`，或 `clean --all` 把它删了 |
| 网络 / 镜像源连通 | 看上面「网络不通」「代理与镜像源」 |
| daemon 状态 | daemon 没起是常态，不是 FAIL；FAIL 指状态不一致（stale json） |

---

## 磁盘与清理

rootfs 是工作区里的真实目录，会占工作区空间。

```sh
.capbox/bin/capbox status --json      # rootfs_bytes
.capbox/bin/capbox clean              # 清缓存/日志、停 daemon
.capbox/bin/capbox clean --all        # 连 rootfs 一起删（装的包全没）
```

`clean --all` 不可逆，删之前确认没有还需要的东西放在 rootfs 里 —— 产物应该在 `/workspace`。
