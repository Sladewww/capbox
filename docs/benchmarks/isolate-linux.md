# Linux 隔离任务与冷检查点验收

基线为 `eb0e816d37fdafa694d60a8dd90e8e775621eb03`。宿主是 Debian 13、
Linux 6.18.57 x86-64、9 个可用逻辑 CPU、约 9.7 GiB 内存、bubblewrap
0.12.0、Python 3.12.14。源与任务副本都在 `/tmp` 的 tmpfs 上。本机数据
反映热缓存和内存文件系统开销，持久磁盘需另测。rootfs 为 Alpine 3.24.4
并安装了 `jq=1.8.2-r0` 和 `oniguruma=6.9.10-r0`。

## 运行基准

在仓库根目录准备一次 Alpine fixture，然后通过同一份 rootfs 串行运行两批
基准。准备包需要可用的 Alpine 镜像或已下载的本地 APK。

```sh
fixture=$(mktemp -d)
bin/capbox --root "$fixture" init --distro alpine
bin/capbox --root "$fixture" pkg install jq
python3 tools/benchmark-isolate.py "$fixture/.capbox/os/alpine" --repeats 3 --parallel 4 > isolate.jsonl
```

本次宿主创建网络命名空间中的 loopback 时拒绝 `NETLINK_ROUTE`，因此使用
`--net open` 运行受控的本地基准。脚本默认 `none`。测试用固定种子生成
普通文件。工作树为 0 或 64 MiB（0 或 1,024 个文件），rootfs 在原有
93 个普通文件、337 个链接上增加 0 或 256 MiB（2,048 个文件）。每种
组合测 1 和 4 路提交，各 3 轮。每轮都等待真正的 guest 输出 `ready`，
并保持任务存活至量盘。输出包括从调用到 `task start` 返回、到首个 guest
标记的毫秒数，以及 `du -s -B1` 得到的分配字节数。并行一轮完成启动的
时间取该轮四个任务的最大值，再取三轮中位数。空间为任务目录总量，另列
工作树、rootfs、Git 审阅基线各自的分量。

## 测量结果

| 工作树 / rootfs（MiB） | 单任务提交 / guest 就绪（秒） | 四路全部就绪（秒） | 每任务占用（MiB） | 四任务占用（MiB） |
| --- | ---: | ---: | ---: | ---: |
| 0 / 9.18 | 0.56 / 1.11 | 1.74 | 10.38 | 41.52 |
| 64 / 9.18 | 2.49 / 3.04 | 9.58 | 142.57 | 570.30 |
| 0 / 265.18 | 0.71 / 1.36 | 3.22 | 266.38 | 1,065.52 |
| 64 / 265.18 | 2.63 / 3.22 | 11.40 | 398.57 | 1,594.30 |

共享模式作为对照组，单任务 guest 就绪中位数为 0.94–1.06 秒，四路全部
就绪为 1.52–1.70 秒，每任务记录占用 12 KiB。64 MiB 工作树每任务增加
64 MiB 文件副本和约 68 MiB Git 基线。临时 rootfs 全量复制是主要空间
开销。提交锁串行化副本准备，工作树与审阅基线开销会在并行提交时累加。
基准末尾同时运行写入者和读者，验证写入只存在于各自任务视图。取消返回
143、guest 失败返回 7，`task rm` 后任务目录清空。

### 压缩原型

在基线的独立 worktree 中，仅为 `isolate()` 写入审阅 Git 基线的
`git add` 加 `-c core.looseCompression=0` 后重跑同一命令。

| 工作树 / rootfs（MiB） | 单任务 guest 就绪（秒），基线 → 原型 | 四路全部就绪（秒），基线 → 原型 |
| --- | ---: | ---: |
| 0 / 9.18 | 1.11 → 0.99 | 1.74 → 1.63 |
| 64 / 9.18 | 3.04 → 1.68 | 9.58 → 4.65 |
| 0 / 265.18 | 1.36 → 1.46 | 3.22 → 2.73 |
| 64 / 265.18 | 3.22 → 2.14 | 11.40 → 6.23 |

随机数据的空间占用接近。补用单个 64 MiB 全零文件执行同一个 `git add`，
默认压缩和关闭压缩分别用 0.497 和 0.502 秒，Git 对象目录分别分配
65,536 和 67,121,152 字节。因压缩率变化会直接影响任务留存空间，保留
默认压缩。当前方案继续使用每任务独立 rootfs。本宿主的 tmpfs 和工作区
overlay 都拒绝 `cp --reflink=always`；直接共享活动 lower 会改变对源
rootfs 后续写入的快照语义，需单独设计不可变基础镜像的生成与生命周期。

原始记录：[基线 JSONL](isolate-linux-baseline.jsonl)、
[压缩原型 JSONL](isolate-linux-no-compression-prototype.jsonl)。

## 环境复用与任务续跑

| 能力 | 已安装依赖 | 已结束任务工作树 | overlay | 配置 |
| --- | --- | --- | --- | --- |
| `snapshot` | 恢复基础 rootfs 后，新任务运行了 `jq-1.8.2` | 归档范围为基础 rootfs | Alpine 源 upper 中的标记在恢复后缺失 | 源 hostname 在恢复后缺失 |
| `bundle` | 打包、校验通过，锁清单含 `jq=1.8.2-r0` | 归档范围为基础 rootfs 与配套文件 | 实际 overlay upper 非空时拒绝打包 | 输出可单独审查、应用的 `recipe.env` |
| `task checkpoint` / `restore` | 保存任务的私有 rootfs | 恢复任务普通工作文件及删除后的状态 | 归档合并后 rootfs，验收覆盖 copy-up、whiteout 与不透明目录 | 恢复任务提交时可移植策略 |

`bundle restore` 强制使用 `untrusted/none` 在 guest 校验包清单。
本宿主的网络命名空间限制导致这一步失败，确认目标 rootfs 被撤回。
现有完整 bundle 往返仍需在可创建隔离网络的宿主运行
`python3 test/security/test_envkit.py BundleTests`。本机复用过程见
[实测日志](reuse-linux.log)。

冷检查点的一键验收和[逐步操作](../agent-workflows.md#冷检查点)：

```sh
CAPBOX_TEST_ROOTFS="$fixture/.capbox/os/alpine" python3 test/security/test_task_checkpoint.py -v
```

本次以 `CAPBOX_CHECKPOINT_TEST_NET=open` 通过上述验收。恢复后的新隔离任务
检查 hostname、修改和删除后的工作树、overlay 变更与任务新增 rootfs 文件。
源项目及其 upper 保持原样。另验收哈希不符、哈希匹配但缺少可启动 shell、
目标已存在、运行中及共享任务等失败路径。
