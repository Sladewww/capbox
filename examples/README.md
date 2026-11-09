# Examples

- `mcpServers.capbox.json` — daily MCP client entry. Bare `mcp serve` keeps **isolated** workspace, **untrusted** profile, **no network**, 600s timeout and 8MiB/stream. Tools cannot raise policy or change root.
- `mcpServers.capbox.restricted.json` — same defaults plus explicit `--net restricted` for the [host credential proxy](../docs/credentials.md). Configure `secret set` / `CAPBOX_NET_ALLOW` on the host first; never put real keys in these files.

Replace the absolute `command` and `--root` paths before use. See [docs/envkit.md](../docs/envkit.md).

## Five-minute outer-sandbox recipe

Use `mcpServers.capbox.json` as the cloneable Claude Code / Codex outer Linux sandbox entry. Full walkthrough: [docs/envkit.md §5](../docs/envkit.md#5-five-minute-path-capbox-as-an-outer-linux-sandbox-claude-code--codex). Keep secrets on the host; never put keys in these JSON files.

