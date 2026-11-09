# 示例

- `mcpServers.capbox.json`：日常 MCP 客户端入口。裸 `mcp serve` 固定为 **isolated** 工作区、**untrusted** 配置、**无网络**、600 秒超时、每路流 8MiB。工具不能抬高策略或改 root。
- `mcpServers.capbox.restricted.json`：同样默认，另加显式 `--net restricted`，配合 [宿主凭据代理](../docs/credentials.md)。先在宿主配置 `secret set` / `CAPBOX_NET_ALLOW`；不要把真实密钥写进这些文件。

使用前把绝对路径 `command` 与 `--root` 换成你的路径。见 [docs/envkit.md](../docs/envkit.md)。

## 五分钟外层沙箱配方

把 `mcpServers.capbox.json` 当作可克隆的 Claude Code / Codex 外层 Linux 沙箱入口。完整步骤：[docs/envkit.md §5](../docs/envkit.md#5-five-minute-path-capbox-as-an-outer-linux-sandbox-claude-code--codex)。密钥留在宿主；不要写进这些 JSON。
