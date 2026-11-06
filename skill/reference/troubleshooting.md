# CapBox 故障排查

SKILL.md 只留了指针，细节在这里。按症状查。

---

## 装包时满屏 `chown ... Invalid argument` 警告

先看 `capbox doctor` 的 **UID 映射** 行：

- **multi**：已用 `newuidmap` 映射 subuid；`chown`/`setgroups`/`setuid` 应可用。若仍有个别失败，看具体包的 postinst。
- **single / blocked**：当前环境只能把宿主一个 uid 映射进容器。此时 `chown` 到其它 uid 必然 `EINVAL`。
  - `CAPBOX_IDMAP=auto`（默认）会在可能时启用 multi，否则诚实回退。
  - `CAPBOX_IDMAP=on` 在不可用时**直接失败**，不会假装多用户可用。
  - 需要：`uidmap` 包（`newuidmap`/`newgidmap` 且 setuid）、`/etc/subuid` 有当前用户条目。

`capbox pkg install` 在 ubuntu 上装完会跑 `dpkg --audit` 并扫描 iU/iF；有残留会明确报错，不把半截安装当成功。

验证：

```sh
.capbox/bin/capbox doctor
.capbox/bin/capbox exec -- sh -c 'touch /tmp/t; chown 33:33 /tmp/t; ls -ln /tmp/t'
.capbox/bin/capbox exec -- curl --version
```

---

## `su` / `setgroups` 报 "can't set groups"

若 UID 映射是 **multi** 且 `CAPBOX_SETGROUPS=allow`（默认），`setgroups`/`setuid` 应可用；sshd 密钥登录可测。

若仍是 **single**：容器内只有一个映射 uid，`setgroups` 被 deny。此时：

- `capbox exec --uid 33` / `--user www-data` 可把**初始进程**降到该身份（单映射时是把宿主 uid 映射成该 guest uid）
- 不要期望在同一容器里再 `su` 到另一个未映射用户
- 装 `uidmap` 并保证 subuid 后，`CAPBOX_IDMAP=auto` 应升到 multi

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

**正确做法**：优先 `capbox up --systemd`（user systemd 在工具调用的进程树外面）。没有 `systemctl --user` 时，用工具的后台任务跑 `capbox up` 这一条命令，然后用普通调用做后续操作。不要在会被 `--die-with-parent` 收掉的前台调用里 `nohup capbox up &`。

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

`CAPBOX_NET=none` 时容器被 `--unshare-net`，没有网络是预期。`restricted`（`init --agent` 的档）同样没有原始路由：先看 `CAPBOX_NET_ALLOW` 是否盖住目标主机和端口（没写端口只有 80/443；非 global 地址，含 CGNAT `100.64.0.0/10` 和 IPv4-mapped，默认拒绝）。不要为了排障把 `CAPBOX_NET` 改成 `open`。只有这次任务就是要共享宿主网络时，才改。

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

---

## 安全档 untrusted/strict 启动失败

1. 看是否缺 `python3` / `libseccomp`（`seccomp-gen.py` 必须能导出真实 BPF；**不会**伪实现）。
2. 多 UID（`CAPBOX_IDMAP=auto/on` 且 multi）时，bwrap **不能**同时用 `--disable-userns` 与 `--userns-block-fd`。CapBox 会跳过 `disable-userns` 并在 doctor 标明该 Linux 边界。
3. 用户没有显式写过 `ROOTFS_RO` 时，`strict` 默认 `ROOTFS_RO=1`。overlay 探测失败则写入 `/` 失败，可 `capbox config set CAPBOX_ROOTFS_RO 0`，或回到 `untrusted`/`compat`。

验证：

```sh
capbox exec --profile untrusted -- sh -c 'mount -t tmpfs none /mnt; echo RC=$?'
# 期望 permission denied / RC=32
```

---

## 资源限额 WARN / require 失败

`capbox metrics` 查看 `cgroup_status`：

- `denied`：有 cgroup v2 但当前用户不能建子目录，或子 cgroup 无控制器接口（例如进程所在 scope 上写 `subtree_control` 得到 EBUSY）。`warn` 模式 MEMORY 可能降级 prlimit（近似）；`require` 模式硬失败。
- 可设 `CAPBOX_CGROUP_ROOT` 指向已启用 cpu/memory/pids 的空父 cgroup；该覆盖失败时不 silently 降级 prlimit。
- `DISK_MAX` 需要能建立 loop+ext4 并 `mount`（root 或 `sudo -n`；可写 `/dev/loop-control` 不够）。镜像在 `.capbox/state/disk/`，只把 `mnt` bind 到 guest `/var/lib/capbox-data`，不改 rootfs 挂载。否则明确 `unavailable`，`require` 硬失败。卸载失败会留下该目录，不要对仍挂着的 `mnt` 做 `rm`。

---

## exec --uid 报 BusyBox setpriv / cannot drop privileges

Alpine 默认只有 BusyBox `setpriv`（无 `--reuid`），且 `/etc/passwd` 常无 uid 33，`su 33` 会失败。CapBox 在宿主用 `gcc -static` 从 `lib/guest/capbox-drop-priv.c` 构建数字 uid helper，装入 rootfs 的 `/usr/libexec/capbox-drop-priv`（不改系统包、不加账户）。`capbox init` / 首次 `--uid` 会构建；doctor 会报告 helper 状态。回退仍保留 GNU setpriv / python3 / chpst / su。

---

## FS_BINDS 被拒绝

只允许把 **工作区内部** 路径 bind 进容器。`host:/guest:ro|rw` 中 host 经解析后必须落在 `CAPBOX_WORKSPACE` 下，禁止 `..` 与工作区外路径（例如 `/etc/passwd`）。

---

## 审计里看不到完整命令

默认 `CAPBOX_AUDIT=summary` 只记 argv0 + 参数个数，并脱敏 `password=` / Bearer。需要排障可设 `CAPBOX_AUDIT=full` 与 `CAPBOX_AUDIT_CMD=full`（仍会做基础脱敏）。
