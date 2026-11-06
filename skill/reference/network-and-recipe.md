# 网络三档、配方与资源限额

## CAPBOX_NET

- `open` / `host`：共享宿主网络（人类调试的默认）。
- `none`：`--unshare-net`，无网络。
- `restricted`：`--unshare-net` + 宿主 allowlist HTTP 代理（`lib/net-proxy.py`）+ guest loopback 桥。一次性 `exec` 和 `capbox up` 都走这条桥。
  - **强制语义**：原始套接字到公网不可达；出站依赖 `http_proxy`/`https_proxy`（CapBox 自动注入 `http://127.0.0.1:18787`）。
  - **不是** bwrap 域名过滤。
  - 前置：`python3`、`nsenter`、非空 `CAPBOX_NET_ALLOW`。
  - allow 语法：`example.com`（仅 80/443，不含子域）、`*.example.com`、`github.com:22`、`host:*`、CIDR。解析到回环 / 链路本地 / 私网会被拒绝，除非该地址自己在名单里。
  - 未知的 `CAPBOX_NET` 直接失败，不会当成 `open`。

`capbox init --agent` 写入 `untrusted` + `restricted`。agent 用这个，不要用默认的 `compat` + `open`。

CLI 覆盖：`capbox exec --net none|restricted|open -- CMD`

## recipe

`capbox.recipe` 或 `.capbox/recipe.env`：白名单 KEY=value，绝不 `source`。
`capbox recipe apply [FILE]` 写入配置、按需 `init`、安装 `PACKAGES`。

## 资源限额

见 README「资源限额」。doctor 会报告是否具备可写 cgroup。
