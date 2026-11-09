# Host credential proxy

CapBox can keep real API keys on the host and let a restricted-network sandbox
talk to approved HTTPS APIs through the existing allowlist proxy. The guest only
sees opaque placeholders such as `capbox-sec-<32hex>`. The host proxy rewrites
**HTTP request headers** (not bodies or query strings) when the destination host
is both in `CAPBOX_NET_ALLOW` and bound to a stored secret.

This is aligned with the sentinel / proxy-managed model used by Docker Sandboxes
credential management, and is comparable in intent to Podman secret injection
and other host-side credential brokers. CapBox does **not** require Docker or
Podman, does not implement OAuth browser flows in v1, and does not require an OS
keychain (file store under the host private `0700` directory).

## Quick start

```sh
# Store a built-in service secret (prompt / stdin; never --value on argv)
printf '%s' "$OPENAI_API_KEY" | capbox secret set openai --value-stdin

# Or import from the current shell environment
capbox secret import openai

# Custom host + env binding
printf '%s' "$MY_TOKEN" | capbox secret set --custom \
  --host api.example.com --env MY_TOKEN --value-stdin

capbox secret ls
capbox config set CAPBOX_NET restricted
capbox config set CAPBOX_NET_ALLOW api.openai.com,api.example.com

# Guest sees only the placeholder; proxy injects the real header value
capbox exec --net restricted -- printenv OPENAI_API_KEY
```

Dynamic host sources (resolved on the host when the proxy needs them):

```sh
capbox secret set github --command 'gh auth token'
```

`--command` text is stored and replayed by the host. Do not embed a secret in the
command string (shell history / process listings). Prefer absolute helper paths
outside guest-writable mounts.

## Trust model

| Location | Holds real secret? |
| --- | --- |
| Host private state (`capbox-UID/<project-hash>/credentials/`, mode `0700` / files `0600`) | Yes |
| Guest environment / `printenv` | No — placeholder only |
| `.capbox/` inside the workspace | No |
| bwrap `--setenv` argv | Placeholders only |
| Audit command lines | Already redacted; still never pass real keys on argv |

Credential domains must already appear in `CAPBOX_NET_ALLOW`. CapBox does not
silently widen the network allowlist when you store a secret.

## HTTPS / MITM

Plain HTTP absolute-form requests are rewritten on the host proxy directly.

For HTTPS, CapBox terminates TLS only for hosts that have an active credential
binding: a project-local MITM CA lives in the host credentials directory. When
a credential session is active, the guest receives that CA via `SSL_CERT_FILE` /
`REQUESTS_CA_BUNDLE` / `CURL_CA_BUNDLE` (system trust + CapBox CA). CONNECT to
other allowlisted hosts continues to tunnel without decryption.

Limits:

- Header rewrite only (Authorization / API key headers containing the placeholder).
- No body or query injection.
- No non-HTTP protocols.
- Clients that pin certificates or ignore `SSL_CERT_FILE` will not work with MITM.
- Keychain backends are a documented future option; v1 is file-store first for
  headless Linux.

## CLI

| Command | Purpose |
| --- | --- |
| `secret set <service>` | Built-in service (openai, anthropic, github, …) |
| `secret set --custom --host … --env …` | Custom domain + env binding |
| `secret ls` | List names/domains/sources (values redacted) |
| `secret rm <name>` | Delete a stored secret |
| `secret import [service] [--all] [--force] [--dry-run]` | Import from process env |

Built-in services mirror common provider env names and API domains (see
`lib/credentials-services.json`).

## Related

- Network allowlist: [configuration.md](configuration.md), [cli-reference.md](cli-reference.md)
- Agent tasks / isolate: [agent-workflows.md](agent-workflows.md)
