# 贡献指南

CapBox 的正确性依赖运行时属性。修改启动、身份、网络或文件系统逻辑后，运行真实沙箱回归，并记录宿主与 guest 环境。

## 提交前检查

```sh
bash -n bin/capbox
python3 tools/generate-docs.py --check
python3 test/security/test_configuration.py
python3 test/security/test_upgrade.py
python3 test/security/test_package_lock.py
python3 test/security/test_host_boundary.py
./test/selftest/run-selftest.sh
```

ShellCheck 的 error 级别必须通过；CI 也验证关键入口的 Git 可执行模式。

<!-- generated:tests -->
验收用例：**43**（T01–T43）。以 `./test/run.sh --list` 的实际清单为准，不硬编码旧数量。
<!-- /generated:tests -->

```sh
./test/run.sh
./test/run.sh T05 T06
# 已有 Alpine rootfs 后，独立执行真实安全回归：
CAPBOX_TEST_ROOTFS=/path/to/alpine python3 test/security/test_integration.py
```

T15/T16 的框架用例需要 `CAPBOX_TEST_DAEMON=1` 和外层长期托管；CI 的真实集成另行覆盖 daemon 生命周期。T19 的旧框架用例需要 `CAPBOX_TEST_SLOW=1`；Ubuntu guest 已由独立兼容矩阵常规测试。多 UID 的必需 CI 不允许回退成 single，也不允许跳过。

## 文档、模块与版本

- 公共版本来源为 `lib/version.sh`。版本变化时同步测试桩及 guest/daemon 的独立加载兜底；生成器会核对。
- 修改帮助、配置默认值或用例数后运行 `python3 tools/generate-docs.py`，提交生成差异。
- 配置解析/校验/提交在 `lib/config.sh`；启动参数只有 `lib/launch.sh` 一份。daemon 不再维护独立安全策略。
- `config.env` 和 recipe 都是数据，禁止 source。配置写回保留 inode，避免破坏已有 guest 的只读覆盖绑定。
- 新的运行文件要能通过 `upgrade apply` 成套安装、验证及回退；业务数据和 rootfs 不属于 CLI 运行文件。
- shell 引号、路径检查、进程身份的修复必须附行为回归，不能只验证命令字符串长相。

## 提交内容

保持 Bash/Python/C 的检查通过；guest 脚本使用 POSIX sh。说明具体问题、改动后的行为和实际验证范围。不要提交 rootfs、缓存、运行状态、真实凭据或测试临时文件。

完整 CI 范围与宿主策略区别见 [docs/testing.md](docs/testing.md)。
