# 网络三档、配方与资源限额

## CAPBOX_NET

- `open` / `host`：共享宿主网络（默认）。
- `none`：`--unshare-net`，无网络。
- `restricted`：`--unshare-net` + 宿主 allowlist HTTP 代理（`lib/net-proxy.py`）+ guest loopback 桥。
  - **强制语义**：原始套接字到公网不可达；出站依赖 `http_proxy`/`https_proxy`（CapBox 自动注入 `http://127.0.0.1:18787`）。
  - **不是** bwrap 域名过滤。
  - 前置：`python3`、`nsenter`、`CAPBOX_NET_ALLOW`。

CLI 覆盖：`capbox exec --net none|restricted|open -- CMD`

## recipe

`capbox.recipe` 或 `.capbox/recipe.env`：白名单 KEY=value，绝不 `source`。
`capbox recipe apply [FILE]` 写入配置、按需 `init`、安装 `PACKAGES`。

## 资源限额

见 README「资源限额」。doctor 会报告是否具备可写 cgroup。
