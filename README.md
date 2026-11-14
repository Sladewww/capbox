# CapBox

English | [中文](README.zh-CN.md)

A persistent Linux workspace for coding agents and trusted development tasks, using bubblewrap and user namespaces. Guest root can install packages and change its own system files. The project is available read-write at `/workspace`.

<!-- generated:version -->
Development CLI: **0.5.2**. Published releases and their migration notes are listed in [Releases](https://github.com/Sladewww/capbox/releases).
<!-- /generated:version -->

CapBox shares the host kernel. Keep unrelated secrets outside the workspace, and review guest-modified project code before executing it on the host. [Security model](SECURITY.md).

## Environment tools (setup, bundles, MCP)

Use `setup check/plan` for host prerequisites and upgrade guidance, `bundle pack/verify/check/restore` for content-locked offline environments, and `mcp serve` for fixed-scope stdio tools. See [Environment tools](docs/envkit.md) for usage and limits. MCP daily entry (`isolated` / `strict` / `none`) is in [outer Linux sandbox path](docs/envkit.md#5-five-minute-path-capbox-as-an-outer-linux-sandbox-claude-code--codex).

## Offline audit reports

`capbox audit report --output /path/outside/project/audit.html` exports a self-contained report with event trends, failure counts, filters, search and details. Open the HTML locally; no server or network is needed. See [audit reports](docs/audit-reports.md) for scope, export controls and sensitive-data handling.

## Requirements

Linux, Bash 4.4+, and **bubblewrap >= 0.12.0**. Package installation may require updating the distro's bubblewrap package or building a supported upstream version. Check `bwrap --version` after installation.

Alpine package scripts require host Python 3.10+ and libseccomp. Upgrades, strict package locks and some runtime helpers also require host Python 3.10+. Landlock and identity helpers need a working `gcc -static` toolchain. The host must permit the requested user namespaces. `doctor` reports capabilities; CI's compatibility scope is documented in [Testing](docs/testing.md).

Normal sandbox execution is rootless. `DISK_MAX` additionally needs host loop/mount authorization and covers only the configured guest data directory. CPU, memory and PID enforcement requires cgroup delegation; `require` refuses configured limits that cannot be applied.

## Install the template

Keep the template outside all business workspaces. For example, if this destination does not already exist:

```sh
mkdir -p "$HOME/.local/share"
git clone https://github.com/Sladewww/capbox.git "$HOME/.local/share/capbox"
export PATH="$HOME/.local/share/capbox/bin:$PATH"
capbox version
bwrap --version
```

Add that PATH entry to your shell configuration if needed. For a published version, use its release tag or archive and verify the provided checksum.

## Choose an execution preset

Use an independent project directory; never use `$HOME` or `/` as the workspace.

**Coding agent / untrusted task:**

```sh
cd /path/to/project
capbox init --agent --distro alpine
capbox doctor
capbox exec -- id -u
```

`--agent` sets `untrusted`, `NET=none`, `IDMAP=off`, `RESOURCES_MODE=require`. It does **not** invent resource budgets. When the host has cgroup delegation, explicitly set budgets for the task and confirm enforcement:

```sh
capbox config set MEMORY_MAX 512M
capbox config set CPU_MAX 50%
capbox config set PIDS_MAX 256
capbox doctor
capbox metrics --json
```

cgroup limits need **both**: (1) the process's own cgroup is writable (so the task can be moved), and (2) an empty, already-delegated limit root. A plain desktop/session scope usually fails (2) because it still has processes. Minimal systemd user-session example:

```sh
uid=$(id -u)
cg="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/capbox.slice"
systemctl --user start capbox.slice   # empty delegated slice (condition 2)
REAL="$HOME/.local/share/capbox/bin/capbox"
systemd-run --user --scope --quiet --collect \
  --setenv=CAPBOX_CGROUP_ROOT="$cg" -- \
  "$REAL" exec -- id -u               # writable user scope (condition 1)
```

`doctor` runs a real probe (mkdir child → write `cgroup.subtree_control` → write `memory.max`); a PASS means both conditions held for that process.

**Trusted development with host networking:**

```sh
capbox init --trusted --distro alpine
capbox pkg install curl
capbox exec -- curl --version
```

`--trusted` selects `compat/open`, automatic ID mapping and `RESOURCES_MODE=warn`. Both explicit presets overwrite their four settings. Bare `init` preserves existing configuration; fresh bare initialization keeps the historical compat/open defaults. Ubuntu is available with `--distro ubuntu`.

## Network and services

| Mode | Meaning |
|---|---|
| `none` | Separate network namespace; no general network access |
| `restricted` | Separate namespace plus an HTTP(S) proxy allowlist; requires `NET_ALLOW` |
| `open` (`host`) | Share the host network |

`pkg install/update` can use the network for that operation even under `none`. For Alpine, prefer `capbox pkg` so its package-script compatibility filter runs; directly invoking apk bypasses that wrapper. Other task networking is explicit, for example `capbox exec --net restricted -- CMD`.

Services use `.capbox/services/NAME.env` and independent bwrap launches. `service start` does not need `up`. Use `service logs NAME`; host launchers, filters, helpers and process identities live outside the workspace in private `0700` directories. Guest IPC, rootfs and project data remain under the project.

A shared persistent guest can use `capbox up --systemd`, then `capbox exec --daemon -- CMD`. Without a user systemd bus, use a process manager that survives the calling tool's lifetime.

## Local Agent tasks

Use `capbox task start -- CMD` for a supervised task with a persistent ID, resumable output and cancellation. `task start --isolate` uses a private working-file/rootfs copy and exports a reviewable diff. `capbox policy show` and `policy check URL` explain requested launch and network rules without weakening them.

See [Local Agent workflows](docs/agent-workflows.md) for JSON contracts, timeout semantics, isolation limits and review/export examples.

## Validate configuration and reproduce packages

```sh
capbox recipe check capbox.recipe
capbox recipe apply capbox.recipe
capbox image lock save
capbox image lock verify
# Rebuild against the exact recorded package versions:
capbox recipe apply --locked /path/to/package.lock capbox.recipe
```

Recipes reject unknown keys, duplicates and invalid lines. Every value is validated before a single serialized configuration commit. Existing config inodes are preserved for long-lived read-only guest bindings. Package installation and rootfs initialization happen afterward and can still fail; they are not rolled back as a single filesystem transaction.

Package locks bind distro, architecture and the complete installed package/version set. Restoration fails if an exact version is unavailable or verification differs; it never silently substitutes newer versions. They do not preserve a disappearing upstream repository. Keep rootfs images or repository snapshots when long-term reproducibility is required. [Package locks](docs/package-locks.md).

## Docker and OCI image files

CapBox still does not talk to a Docker daemon. `image docker` reads a local `docker save` archive, an OCI layout directory, or an OCI archive, flattens the layers, and starts that tree with the same bubblewrap launcher. `image docker pull REF` shells out to host `skopeo` (or `crane`), resolves the tag to a digest, and imports that layout. It does not open `docker.sock`. Registries are allowlisted by `CAPBOX_OCI_REGISTRIES`.

```sh
capbox image docker import alpine.tar --name alpine
capbox exec --image alpine -- cat /etc/os-release
capbox image docker run alpine.tar -- uname -a
```

Import stores `.capbox/images/docker/<name>/` and does not replace the Alpine or Ubuntu rootfs or change `DISTRO`. `exec --image` swaps the rootfs for one command. `image docker run` also applies the image `Entrypoint`, `Cmd`, `User`, `WorkingDir`, and `Env` as data: arguments go to bwrap, and environment entries are `--setenv` only. Non-Linux images are rejected. [Details](docs/oci-images.md).

## Upgrade an existing project

First use the **old CLI** to stop services and the daemon, and finish other exec calls. Then invoke the new template's CLI:

```sh
"$HOME/.local/share/capbox/bin/capbox" --root /path/to/project upgrade check --from "$HOME/.local/share/capbox"
"$HOME/.local/share/capbox/bin/capbox" --root /path/to/project upgrade apply --from "$HOME/.local/share/capbox"
# If needed:
"$HOME/.local/share/capbox/bin/capbox" --root /path/to/project upgrade rollback
```

The tool compares file contents, stages a complete bin/lib bundle, validates it, retains a private backup, and recovers after replacement failure. Rootfs and business data remain in place. An interrupted upgrade blocks normal commands until recovery. This is a stopped-project maintenance operation; it cannot coordinate concurrent invocations of pre-upgrade CLIs. [Upgrade details](docs/upgrades.md).

## Documentation and validation

| Document | Purpose |
|---|---|
| [Generated CLI reference](docs/cli-reference.md) | Actual command help |
| [Generated configuration defaults](docs/configuration.md) | Actual built-in defaults |
| [Architecture](docs/architecture.md) | Module boundaries and launch policy |
| [Testing](docs/testing.md) | CI matrix and capability requirements |
| [Wiki](https://github.com/Sladewww/capbox/wiki) | Versioned Chinese operations and application examples |
| [CONTRIBUTING](CONTRIBUTING.md) | Checks before submitting changes |

<!-- generated:tests -->
Acceptance cases: **43** (T01–T43). Framework selftests validate the test harness; real guest and host-boundary regressions run separately.
<!-- /generated:tests -->

MIT — [LICENSE](LICENSE).


### Host credential proxy

Real API keys stay on the host; restricted mode injects them via the allowlist proxy. See [docs/credentials.md](docs/credentials.md). See [docs/envkit.md](docs/envkit.md) for the MCP entry and its host-enforced network policy.
