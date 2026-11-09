# Environment tools (setup, bundles, MCP)

These commands require host Python 3.10+. They build on [runtime upgrades](upgrades.md), [strict package locks](package-locks.md) and [local tasks](agent-workflows.md).

## 1. Inspect installation and upgrade requirements

From a template or an initialized project:

```sh
capbox setup check --json
capbox setup check --probe --json
capbox setup plan --json
capbox --root /path/to/project setup plan --from /path/to/new-template --json
```

`setup check` reports host/architecture, resolved dependency paths and minimum versions, libseccomp availability, the template/runtime version and installed project version. `dependencies_ready` concerns required dependencies. User-namespace execution and cgroup enforcement remain `not_probed`: use `doctor` and actual launches after initializing a guest. Reading a sysctl is not proof that the host security policy permits execution.

`--probe` additionally compiles a fixed, trivial C program with `gcc -static` in a private temporary directory. It does not run the resulting binary or change host policy. A strict/Landlock configuration needs this static toolchain check before readiness can be confirmed.

The `python-safe-extract` component checks the secure importer's Python capabilities (`tarfile.data_filter` and `os.path.ALLOW_MISSING`). Keep Python security updates installed; an older 3.10+ patch release can still lack these capabilities, and bundle restore then fails closed.

`setup plan` outputs package-manager argv for recognized Debian/Ubuntu, Alpine, Fedora/RHEL and Arch families. It never executes installers, downloads a script, modifies AppArmor/sysctls or grants privileges. Package availability and bubblewrap versions vary by release; review the proposed commands, execute the appropriate host installation yourself, then repeat the check. Package-manager plans are guidance, not an additional tested host matrix.

With `--from`, the plan includes commands for the existing upgrade check/apply/rollback. Setup and upgrade use the new template's code even when inspecting an older project runtime. Stop services, daemon, tasks and other exec calls with the old CLI before applying a runtime upgrade. The existing private backup and rollback protocol remains in use.

## 2. Starter recipes and strict replay

Three starter recipes are shipped under `recipes/`: Python, Node and native build tools. Use their full paths when the template is outside the project:

```sh
capbox recipe check /path/to/template/recipes/python.recipe
capbox recipe apply /path/to/template/recipes/python.recipe
capbox image lock save
capbox image lock verify
# Exact package versions; unavailable versions fail:
capbox recipe apply --locked /path/to/package.lock /path/to/template/recipes/python.recipe
```

Starters are initial package selections, not already-locked environments. Configure task resource budgets explicitly. `recipe export FILE` returns validated `capbox.recipe.v1` JSON without sourcing or executing the recipe. Strict package replay still depends on version availability in repositories; use a bundle when an already-prepared rootfs needs offline transport.

## 3. Portable, content-locked environment bundles

Stop writers before packing. Choose a **new directory outside the workspace**:

```sh
capbox bundle pack /path/outside/project/python-environment --recipe /path/to/template/recipes/python.recipe
capbox bundle verify /path/outside/project/python-environment
capbox bundle check /path/outside/project/python-environment
```

A bundle contains fixed filenames:

| File | Purpose |
|---|---|
| `manifest.json` | Bundle schema, distro, host architecture, source runtime version, portable configuration and SHA256 per artifact |
| `rootfs.tar.gz` | Full current physical rootfs archive |
| `package.lock` | Installed package names and exact versions |
| `recipe.env` | Canonical portable configuration with `INIT=0` |

Pack refuses running managed workloads, nonempty overlay uppers and absolute host bind specifications. Other direct exec calls and external writers must also be stopped. It captures a physical rootfs, not a merged overlay or a live database snapshot. Business workspace files are not part of this archive. Config credentials/proxies, host-specific bwrap paths and UID-map ranges are not copied into the portable recipe. If a supplied recipe requests nonportable host settings or differs from the current environment, packing fails.

The **rootfs itself can contain credentials, proxy files, caches or application data**. Inspect and clean it before sharing. Artifacts are created privately and are never uploaded automatically. Hashes provide content integrity, not publisher authentication. Pack prints the manifest digest; preserve that digest through a trusted channel and pin it when checking or restoring:

```sh
capbox bundle verify /path/to/environment --manifest-sha256 SHA256_FROM_PACK
```

`verify` checks schema, distro, architecture, hashes, canonical recipe and archive paths/types before reporting success. `check` additionally compares the active package inventory and portable configuration, returning nonzero for drift. Neither command silently updates a lock or installs newer package versions.

### Restore into a fresh target

Use a fresh independent project with no existing rootfs and select the bundle's distro first. For Alpine, for example:

```sh
capbox --root /path/to/fresh-project bootstrap
capbox --root /path/to/fresh-project config set SECURITY_PROFILE untrusted
capbox --root /path/to/fresh-project config set NET none
capbox --root /path/to/fresh-project config set IDMAP off
capbox --root /path/to/fresh-project config set RESOURCES_MODE require
capbox --root /path/to/fresh-project bundle restore /path/to/environment --manifest-sha256 SHA256_FROM_PACK
capbox --root /path/to/fresh-project bundle check /path/to/environment
```

For Ubuntu, also set `DISTRO=ubuntu` before restore. The project directory must already exist. A fresh target is required; existing rootfs data is never replaced. Input is copied into a private staging area, reverified and extracted through the filtered image importer. Archive publication is atomic with no-replace semantics. Restored package inventory is checked through an untrusted, no-network, single-UID launch; failure removes only the newly promoted rootfs.

Target security and resource configuration is preserved. `config_applied` is false. Review `configuration_drift` and the bundled `recipe.env` before explicitly applying source settings; do not import a less restrictive profile just to suppress a drift report. Workspace data, runtime installation, host delegation and kernel support remain separate concerns.

Bundles use the existing safe image extraction semantics, including permission/ownership sanitization; they are not a promise of bit-identical ACLs, owners, build results or running process state. Limits: 4GiB per artifact, 8GiB declared expanded data and 200,000 archive members. Atomic directory promotion requires Linux `renameat2`. Plan disk space and copy time accordingly.

## 4. A fixed-scope stdio MCP adapter

Initialize/prebuild the workspace before starting the server:

```sh
capbox --root /path/to/project mcp serve
# Explicitly use the shared project instead of private Git task copies:
capbox --root /path/to/project mcp serve --workspace-mode shared
# Restrict network destinations in host config first:
capbox --root /path/to/project mcp serve --net restricted --max-timeout 600
```

Defaults: isolated Git task workspace, `untrusted` profile, `none` network, maximum execution timeout 600 seconds and 8MiB retained output per stream. Startup accepts `strict` and `restricted` explicitly; restricted needs `NET_ALLOW`. No tool call may change workspace root, profile, network mode, output budget or maximum timeout. The adapter clears configured upstream PROXY values; restricted mode uses its own allowlist bridge. Host configuration supplies resource limits; the adapter does not invent or claim cgroup delegation.

Configure your MCP client to launch the CLI with an absolute template executable path and these arguments. For clients using a `mcpServers` block, an example is:

```json
{
  "mcpServers": {
    "capbox": {
      "command": "/absolute/path/to/template/bin/capbox",
      "args": ["--root", "/absolute/path/to/project", "mcp", "serve"]
    }
  }
}
```

Client configuration formats vary. This server implements [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), [initialization/version negotiation](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle) and [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools). It supports protocol versions `2025-11-25` and `2025-06-18`; unknown versions negotiate the newest supported version. It does not advertise MCP's optional task-augmented protocol: task IDs are CapBox tool results.

| Tool | Scope |
|---|---|
| `capbox_execute` | Bounded noninteractive guest argv; returns a task ID |
| `capbox_status` | Task state and exit code |
| `capbox_logs` | Stream text plus structured byte cursor/base64 data |
| `capbox_cancel` | Asynchronous cancellation; poll status to confirm |
| `capbox_diff` | Export a completed isolated task patch; no apply |
| `capbox_policy` | Server's fixed requested launch policy |

Only `/workspace` and its descendants are accepted as cwd. The server does not expose host package installation, upgrade, configuration mutation, arbitrary host files or shell commands. Task argv executes through the normal sandbox launcher with the fixed policy. An isolated workspace requires a Git repository root; there is no silent fallback to shared mode.

Messages are UTF-8 JSON-RPC lines, at most 1MiB per input message. Invalid JSON, oversized messages, unknown tools/parameters, bad IDs and policy override attempts are rejected. stdout contains protocol messages only; diagnostics use stderr. Tool-side failures use `isError`; log cursors remain byte offsets. Large diffs beyond the MCP result budget require local CLI export. Requests are processed serially with a bounded CLI invocation timeout; the server does not maintain a separate execution engine.

Closing the MCP connection does not request cancellation of already accepted tasks. Their normal host lifetime and outer-supervisor limits still apply. Use the client UI's tool review controls and CapBox cancellation when needed; logs and patches remain untrusted task data.
