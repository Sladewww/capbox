# 网络三档、配方与资源限额

## CAPBOX_NET

- `open` / `host`：共享宿主网络（人类调试的默认）。
- `none`：`--unshare-net`，无网络。
- `restricted`：`--unshare-net` + 宿主 allowlist HTTP 代理（`lib/net-proxy.py`）+ guest loopback 桥。一次性 `exec` 和 `capbox up` 都走这条桥。
  - **强制语义**：原始套接字到公网不可达；出站依赖 `http_proxy`/`https_proxy`（CapBox 自动注入 `http://127.0.0.1:18787`）。
  - **不是** bwrap 域名过滤。
  - 前置：`python3`、`nsenter`、非空 `CAPBOX_NET_ALLOW`。
  - allow 语法：`example.com`（仅 80/443，不含子域）、`*.example.com`、`github.com:22`、`host:*`、CIDR。显式网段仍受端口约束。解析到非 global 地址会被拒绝：回环、链路本地、私网、CGNAT（`100.64.0.0/10`）、IPv4-mapped。那个地址自己在名单里才放行。
  - 未知的 `CAPBOX_NET` 直接失败，不会当成 `open`。

`capbox init --agent` 写入 `untrusted` + `NET=none` + `IDMAP=off` + `RESOURCES_MODE=require`（额度需另设）。agent 用这个，不要用默认的 `compat` + `open`。
`pkg install` 和 `pkg update` 在 none 下仍出网，不写回配置。`remove` 和 `list` 不出网。`pip` / `npm` / `git` 不自动识别。

当次声明：`capbox exec|shell|up --net none|restricted|open -- …`。`restricted` 需要已经写好的 `CAPBOX_NET_ALLOW`。服务在自己的 `.env` 里写 `NET=`。

## recipe

`capbox.recipe` 或 `.capbox/recipe.env`：白名单 KEY=value，绝不 `source`。
`capbox recipe check [FILE]` 先完整检查；未知键、重复键或无效行报错。`capbox recipe apply [FILE]` 在全部校验通过后一次提交配置（`PACKAGES` 和 `INIT` 除外），按需 `init`，再安装 `PACKAGES`。`INIT=0` 跳过 init，包仍会装。

## 资源限额

见 [README.zh-CN.md](../../README.zh-CN.md) 的预设与资源说明，细节在 Wiki [资源限额](https://github.com/Sladewww/capbox/wiki/资源限额)。doctor 会报告是否具备可写 cgroup。

严格包锁与升级恢复参见 [包锁](../../docs/package-locks.md) 和 [升级](../../docs/upgrades.md)。
