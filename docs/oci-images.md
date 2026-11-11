# Docker / OCI 镜像文件

CapBox 不连接 Docker daemon，也不读取 `docker.sock`。`image docker import` 接受本机已经存在的镜像文件；`image docker pull` 只通过宿主的 `skopeo` 或 `crane` 把仓库镜像拷成 OCI layout。两种输入都展开成目录，再用原来的 bubblewrap 启动。

支持三种输入：

| 输入 | 来源 |
|---|---|
| docker-archive | `docker save`、`podman save` 产出的 `.tar` / `.tar.gz` / `.tar.zst` |
| OCI layout | 含 `oci-layout`、`index.json`、`blobs/` 的目录 |
| OCI archive | 上述 layout 打成的 tar |

```sh
capbox image docker inspect alpine.tar
capbox image docker import alpine.tar --name alpine
capbox exec --image alpine -- cat /etc/os-release
capbox image docker run alpine.tar -- uname -a
capbox image docker run alpine --entrypoint /bin/sh -- -c 'echo "$IMAGE_ENV"'
```

`import` 写到 `.capbox/images/docker/<name>/rootfs`，并在旁边放 `meta.json`。不改 `DISTRO`，也不替换 `os/alpine` 或 `os/ubuntu`。同名已存在时要 `--force`。`run` 的参数如果是文件，且同名镜像尚未导入，会先导入再启动；已存在则复用，除非显式传入 `--force`。外层 gzip/zstd 解压过程中限制在 8GiB。

`pull` 不自己实现仓库协议，也不连接 Docker daemon 或 `docker.sock`。宿主 PATH 上有 `skopeo` 时用它，否则用 `crane`；两个都没有就失败。标签会先解析成 `sha256`，再按这个摘要复制到临时 OCI layout，然后走同一条 `import`。复制结果的摘要必须和解析到的一致。

```sh
capbox image docker pull alpine:3.20 --name alpine
capbox image docker pull ghcr.io/org/app@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

默认只允许 `docker.io`、`ghcr.io`、`quay.io`、`public.ecr.aws`、`registry.k8s.io`。`CAPBOX_OCI_REGISTRIES` 用逗号列出其他主机；`*` 关闭白名单。短名字按 Docker Hub 规则补全（`alpine` → `docker.io/library/alpine`）。登录态用 `skopeo` / `crane` 自己的配置，CapBox 不读取 `~/.docker`。拉取走宿主网络；`CAPBOX_PROXY` 只在尚未设置 `https_proxy` 时传给这两个命令。临时 layout 超过 8GiB 会拒绝。

多平台镜像默认选宿主架构（`linux/amd64` 或 `linux/arm64`）。可以用 `--platform linux/arm64`、`--index N` 或 `--tag REF` 指定。非 Linux 镜像直接拒绝。

层按顺序应用，包括 OCI whiteout（`.wh.<name>` 删除下层文件，`.wh..wh..opq` 清空目录）。绝对路径、`..`、以及会走出 rootfs 的符号链接都会拒绝。层里的设备节点、fifo 不在宿主上创建；`/dev` 仍由 bwrap 提供。导入时不做数字属主映射，文件属主是执行导入的用户。没有多 UID 映射时，这和现有 rootfs 的单 UID 边界一致。

`image docker run` 把镜像里的 `Entrypoint`、`Cmd`、`User`、`WorkingDir`、`Env` 当数据用：argv 直接交给 bwrap，`Env` 只变成 `--setenv`，不写进宿主 shell，也不 source。`--` 后面的参数替换 `Cmd`，保留 `Entrypoint`。`exec --image NAME` 只更换这一次的 rootfs，命令仍是你写的那条，并且要求镜像里有 `/bin/sh`。它不能和 `--daemon` 一起用。

不可信镜像请加 `--profile untrusted` 或 `--profile strict`。`compat` 仍是全 capability、无 seccomp。外层 zstd 或 zstd 层需要宿主有 `zstd`。
