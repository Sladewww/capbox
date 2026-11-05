# 贡献指南

## 跑起来再说

**改 `lib/` 下任何脚本后，不要只看 diff。** 这个项目的正确性高度依赖运行时属性，
代码里看不出来。本项目开发期间修复的 bug 里，**没有一个**是靠通读代码发现的。

典型陷阱：

| 看起来对 | 实际 |
|---|---|
| `[ -e "$rootfs/bin/sh" ]` 判 rootfs 就绪 | alpine 的 `sh` 是容器内绝对符号链接，宿主侧解析会跟随到宿主路径 → 误判缺失 |
| `kill -0 "$pid"` 判守护进程存活 | 每次调用是独立 PID namespace，容器内 pid 恒为 2，会命中无关进程 → 恒假阳性 |
| `while ...; _waited++; [ $_waited -ge 30 ]` 等 30 秒 | 每轮 `sleep 0.2`，实际只等 6 秒，而日志还写着「上限 30s」 |

最低验证线：

```sh
./bin/capbox doctor                 # 全部 PASS
./bin/capbox exec -- id -u          # 0
./bin/capbox exec -- sh -c 'mount -t tmpfs none /mnt && echo ok'
./bin/capbox exec -- sh -c 'exit 42'; echo $?    # 42
```

涉及 daemon 的改动再加一轮：`up` → `exec --daemon -- id -u` → `down`，并检查
`run/daemon/` 无残留。

## 跑测试

```sh
./test/run.sh                # 全部 22 个用例
./test/run.sh T05 T06        # 指定用例
./test/run.sh --list         # 列出用例
```

两个用例有额外前提：

- **T15 / T16**（daemon）：需要先起常驻容器，再带 `CAPBOX_TEST_DAEMON=1` 重跑。
  容器就绪后**立刻跑**，别 `sleep`：宿主可能在数秒内回收它。
- **T19**（ubuntu）：较慢，需 `CAPBOX_TEST_SLOW=1`。

框架自身有自测（假 CLI 桩 + 缺陷注入），改测试后请跑：

```sh
./test/selftest/run-selftest.sh
```

## 提交

- shell 脚本保持 `bash -n` / `sh -n` 通过；容器内脚本用 POSIX sh，不要用 bash 扩展。
- 注释写「为什么」，不写「做了什么」。
- 修 bug 的提交请附上能复现它的命令，而不只是结论。

## 不要提交

`os/`、`cache/`、`run/`、`state/`、`logs/`、`config.env`、`test/tmp/` —— 已在 `.gitignore` 中。
