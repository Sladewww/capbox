# Examples

- `mcpServers.capbox.json` — daily MCP client entry. Bare `mcp serve` keeps **isolated** workspace, **untrusted** profile, **no network**, 600s timeout and 8MiB/stream. Tools cannot raise policy or change root.
- `mcpServers.capbox.restricted.json` — same defaults plus explicit `--net restricted` for the [host credential proxy](../docs/credentials.md). Configure `secret set` / `CAPBOX_NET_ALLOW` on the host first; never put real keys in these files.

Replace the absolute `command` and `--root` paths before use. See [docs/envkit.md](../docs/envkit.md).
