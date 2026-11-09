# 宿主凭据代理

CapBox 可以把真实 API key 留在宿主，让受限网络沙箱经既有白名单代理访问已批准的 HTTPS API。guest 只看到不透明占位符，例如 `capbox-sec-<32hex>`。目标主机同时在 `CAPBOX_NET_ALLOW` 中且绑定了已存密钥时，宿主代理改写 **HTTP 请求头**（不改 body，也不改 query）。

CapBox 不依赖 Docker 或 Podman。v1 不做 OAuth 浏览器流，也不要求 OS keychain；密钥文件放在宿主私有 `0700` 目录下。

## 快速开始

```sh
# 存入内置服务密钥（prompt / stdin；不要在 argv 上用 --value）
printf '%s' "$OPENAI_API_KEY" | capbox secret set openai --value-stdin

# 或从当前 shell 环境导入
capbox secret import openai

# 自定义 host + 环境变量绑定
printf '%s' "$MY_TOKEN" | capbox secret set --custom \
  --host api.example.com --env MY_TOKEN --value-stdin

capbox secret ls
capbox config set CAPBOX_NET restricted
capbox config set CAPBOX_NET_ALLOW api.openai.com,api.example.com

# guest 只看到占位符；代理注入真实请求头
capbox exec --net restricted -- printenv OPENAI_API_KEY
```

动态宿主源（代理需要时在宿主解析）：

```sh
capbox secret set github --command 'gh auth token'
```

`--command` 文本由宿主保存并重放。不要把密钥嵌进命令字符串（shell 历史 / 进程列表）。优先用 guest 可写挂载之外的绝对路径辅助程序。

## 信任模型

| 位置 | 是否持有真实密钥 |
| --- | --- |
| 宿主私有状态（`capbox-UID/<project-hash>/credentials/`，目录 `0700` / 文件 `0600`） | 是 |
| guest 环境 / `printenv` | 否 — 仅占位符 |
| 工作区内的 `.capbox/` | 否 |
| bwrap `--setenv` argv | 仅占位符 |
| 审计命令行 | 已脱敏；仍不要在 argv 上传真实密钥 |

凭据域名必须已出现在 `CAPBOX_NET_ALLOW`。存密钥时 CapBox 不会悄悄扩大网络白名单。

## HTTPS / MITM

明文 HTTP absolute-form 请求由宿主代理直接改写。

对 HTTPS，CapBox 只对已有活跃凭据绑定的主机终结 TLS：项目本地 MITM CA 放在宿主凭据目录。凭据会话活跃时，guest 通过 `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` / `CURL_CA_BUNDLE` 拿到该 CA（系统信任 + CapBox CA）。其它白名单主机的 CONNECT 继续隧道，不解密。

限制：

- 只改写请求头（含占位符的 Authorization / API key 头）。
- 不注入 body 或 query。
- 不支持非 HTTP 协议。
- 钉证书或忽略 `SSL_CERT_FILE` 的客户端无法配合 MITM。
- keychain 后端是文档化的后续选项；v1 以无头 Linux 上的文件存储优先。

## CLI

| 命令 | 用途 |
| --- | --- |
| `secret set <service>` | 内置服务（openai、anthropic、github、…） |
| `secret set --custom --host … --env …` | 自定义域名 + 环境变量绑定 |
| `secret ls` | 列出名称/域名/来源（值已脱敏） |
| `secret rm <name>` | 删除已存密钥 |
| `secret import [service] [--all] [--force] [--dry-run]` | 从进程环境导入 |

内置服务对应常见提供商环境变量名与 API 域名（见 `lib/credentials-services.json`）。

## MCP 日常路径

`capbox mcp serve` 默认 isolated / untrusted / **无网络**。要让 Agent 调用已批准的 HTTPS API、又不把真实密钥放进 guest：

1. 在宿主执行 `secret set` / `secret import`（见上文快速开始）。
2. 把提供商主机写入 `CAPBOX_NET_ALLOW`（不要指望静默扩白名单）。
3. 启动 MCP 时显式加 `--net restricted`。工作区模式保持默认（`isolated`）。

不要把密钥写进 MCP 客户端 JSON，也不要为了方便改成 `--workspace-mode shared` 或开放网络。客户端参数示例与完整说明：[envkit.md](envkit.md#host-secrets-with-mcp-restricted-only)。

## 相关

- 网络白名单：[configuration.md](configuration.md)、[cli-reference.md](cli-reference.md)
- Agent 任务 / isolate：[agent-workflows.md](agent-workflows.md)
- 固定范围 MCP 适配器：[envkit.md](envkit.md)
