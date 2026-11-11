# Docker / OCI 镜像文件

CapBox 不连接 Docker daemon，也不读取 `docker.sock`。`image docker` 只接受本机已经存在的镜像文件，把层展开成目录，再用原来的 bubblewrap 启动。

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

`import` 写到 `.capbox/images/docker/<name>/rootfs`，并在旁边放 `meta.json`。不改 `DISTRO`，也不替换 `os/alpine` 或 `os/ubuntu`。同名已存在时要 `--force`。`run` 的参数如果是文件，会按该文件重新展开后再启动。

多平台镜像默认选宿主架构（`linux/amd64` 或 `linux/arm64`）。可以用 `--platform linux/arm64`、`--index N` 或 `--tag REF` 指定。非 Linux 镜像直接拒绝。

层按顺序应用，包括 OCI whiteout（`.wh.<name>` 删除下层文件，`.wh..wh..opq` 清空目录）。绝对路径、`..`、以及会走出 rootfs 的符号链接都会拒绝。层里的设备节点、fifo 不在宿主上创建；`/dev` 仍由 bwrap 提供。导入时不做数字属主映射，文件属主是执行导入的用户。没有多 UID 映射时，这和现有 rootfs 的单 UID 边界一致。

`image docker run` 把镜像里的 `Entrypoint`、`Cmd`、`User`、`WorkingDir`、`Env` 当数据用：argv 直接交给 bwrap，`Env` 只变成 `--setenv`，不写进宿主 shell，也不 source。`--` 后面的参数替换 `Cmd`，保留 `Entrypoint`。`exec --image NAME` 只更换这一次的 rootfs，命令仍是你写的那条，并且要求镜像里有 `/bin/sh`。它不能和 `--daemon` 一起用。

不可信镜像请加 `--profile untrusted` 或 `--profile strict`。`compat` 仍是全 capability、无 seccomp。外层 zstd 或 zstd 层需要宿主有 `zstd`。
