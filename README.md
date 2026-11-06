# CapBox

English | [中文](README.zh-CN.md)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4.4%2B-green.svg)](bin/capbox)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](#requirements)
[![Tests](https://img.shields.io/badge/tests-T01–T41-informational.svg)](test/run.sh)
[![CI](https://github.com/Sladewww/capbox/actions/workflows/ci.yml/badge.svg)](https://github.com/Sladewww/capbox/actions/workflows/ci.yml)

A root Linux in the project directory. No Docker, no sudo. After `capbox init` the container is uid 0, and all of its state is the `.capbox/` directory.

Coding agents often need to install packages, edit `/etc`, or compile into `/usr`. Doing that on the host either needs privileges or dirties the machine. Docker is often unavailable inside an outer sandbox. CapBox uses [bubblewrap](https://github.com/containers/bubblewrap) and a user namespace: `os/<distro>/` is the container `/`, the workspace is `/workspace`.

- Guest root is not host root. Writes to `/` land in `.capbox/os/<distro>/`.
- One `.capbox/` per project. Alpine or Ubuntu, SHA256-pinned tarballs, x86_64 and aarch64.
- `capbox init --agent` sets `untrusted` and `CAPBOX_NET=none`. `pkg install` and `pkg update` still use the network. Anything else must say `--net` on that command.
- `.capbox/logs/` (including `audit.jsonl`) is read-only inside the guest.

This is a shared kernel, not a VM.

## Quickstart

Linux and `bwrap` **>= 0.12.0**. Older versions are refused (exit 6), including `compat`.

```sh
git clone https://github.com/Sladewww/capbox.git ~/.agents/capbox
ln -s ~/.agents/capbox/bin/capbox ~/.local/bin/capbox

cd /path/to/your-project
capbox init --distro alpine          # or: capbox init --agent --distro alpine
capbox doctor
capbox exec -- id -u                 # 0
```

Do not `init` with the workspace set to `$HOME` or `/`. The whole tree is bind-mounted read-write at `/workspace`.

Keep a process across calls with `capbox up --systemd` (or `capbox up` in a background job that outlives the tool call), then `capbox exec --daemon -- …`.

## Docs

| | |
|---|---|
| [Wiki](https://github.com/Sladewww/capbox/wiki) | Operations manual (Chinese): services, network, backups |
| [Quick start](https://github.com/Sladewww/capbox/wiki/快速开始) | bootstrap, init, doctor, first service |
| [SECURITY.md](SECURITY.md) | Threat model |
| [skill/SKILL.md](skill/SKILL.md) | Agent skill |
| [AGENTS.md](AGENTS.md) | Notes for agents in this repo |

## Network

| Mode | Behavior |
|---|---|
| `open` (alias `host`) | Share the host network. Default for a human at the keyboard. |
| `none` | `bwrap --unshare-net`. No network in the guest. |
| `restricted` | `--unshare-net` plus an HTTP proxy with a domain allowlist. Raw TCP/UDP is not routed. This does not pretend bwrap can filter domain names. |

Unknown values fail. They are not treated as `open`. Names that resolve to loopback, link-local (including cloud metadata), or private addresses are rejected unless that address is itself on the allowlist.

Allowlist syntax and the agent preset are on the [network page](https://github.com/Sladewww/capbox/wiki/网络与端口).

## Recipe

A `capbox.recipe` in the project root is `KEY=value`. It is not sourced.

```sh
capbox recipe apply    # write config, init if needed, pkg install
capbox recipe show
```

## Limits

`CAPBOX_MEMORY_MAX`, `CAPBOX_CPU_MAX`, `CAPBOX_PIDS_MAX`, and `CAPBOX_DISK_MAX` prefer cgroup v2. `CAPBOX_RESOURCES_MODE=warn` (default) warns when a limit cannot be applied. `require` fails closed. `DISK_MAX` covers only `/var/lib/capbox-data`, needs a host mount, and is not rootless. Details: [资源限额](https://github.com/Sladewww/capbox/wiki/资源限额).

`CAPBOX_SECURITY_PROFILE` is `compat` (default), `untrusted`, or `strict`. `CAPBOX_LANDLOCK=on|off`; unset means on only for `strict`. Landlock runs after mounts and does not filter TCP ports.

## Commands

| Command | |
|---|---|
| `init [--distro D] [--agent]` | Install a rootfs. `--agent` writes untrusted + `NET=none`. |
| `exec [--daemon] [--net MODE] [--timeout N] -- CMD` | Run in the container. |
| `pkg install`, `update`, `remove`, `list` | apk / apt. Install and update may use the network when the session is `none`. |
| `up [--systemd] [--net MODE]` / `down` | Long-lived container. |
| `service start`, `stop`, `status`, `logs`, `list` | Services from `.capbox/services/*.env`. |
| `doctor` | Exit 1 on FAIL. Exit 6 if bwrap is older than 0.12.0. A bypass does not turn this into PASS. |

Exit codes: `0` ok, `1` error, `2` usage, `3` daemon not running, `4` no rootfs, `5` missing dependency, `6` bwrap baseline, `124` timeout. Anything else is the guest's exit code.

## Services

`.capbox/services/<name>.env` is `KEY=value`, not sourced. `CMD` is the program, not an environment variable. `USER`, `CWD`, and any other key are passed with `--setenv` after `--clearenv`. `service start` is its own bwrap and does not need `capbox up`.

See [服务运维](https://github.com/Sladewww/capbox/wiki/服务运维).

## Boundary

- The workspace is the trust boundary. Do not use `$HOME` as the workspace.
- `bin/`, `lib/`, and `config.env` are read-only in the guest, so a guest cannot rewrite the CLI the host will run next.
- `logs/` is read-only in the guest. `FS_BINDS` cannot target it. A symlink or directory at `audit.jsonl` refuses to start.
- `capbox cp` rejects `..` that escapes the rootfs.
- The usual assumption is that the host is already inside a sandbox.

## Tests

```sh
bash -n bin/capbox lib/*.sh lib/guest/*.sh
bash test/selftest/run-selftest.sh
./test/run.sh
```

CI: [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## License

MIT — see [LICENSE](LICENSE).
