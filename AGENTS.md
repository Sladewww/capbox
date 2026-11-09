# AGENTS.md — coding agents using CapBox

## Layout

1. **Template (once per machine)**
   `~/.agents/capbox` — full tree (`bin/`, `lib/`, `skill/`).
   Symlink the skill into your agent skills dir:
   ```sh
   ln -s ~/.agents/capbox/skill ~/.agents/skills/capbox
   # or: ln -s ~/.agents/capbox/skill ~/.dsh/skills/capbox
   ```
   Put `~/.agents/capbox/bin` (or a link to `bin/capbox`) on `PATH`.

2. **Per session / project**
   Project data lives in **`$PWD/.capbox/`** (rootfs, config, guest IPC). Host control files live outside the workspace; persistent upgrade backups use XDG_STATE_HOME.
   First use in an empty project:
   ```sh
   capbox bootstrap          # copy template → ./.capbox/ (no download)
   capbox init --distro alpine
   ```
   Or just `capbox init` (scaffolds then downloads). Do **not** treat `~/.agents/capbox` as the workspace.

## When to use CapBox

Use for guest root needs: install system packages, edit `/etc`, mount, long-running services.
Prefer host tools for ordinary file edits. Daemon: run `capbox up` in a job that outlives the tool call (`die-with-parent` kills `nohup &`).

## Safety rules (do not weaken)

- Never `init` / bind workspace as `$HOME` or `/` (CLI refuses dangerous workspace).
- Never `source` `config.env`; only whitelist `KEY=value` parsing.
- Guest must not rewrite CLI: `bin/`, `lib/`, and `config.env` are `--ro-bind` into the container.
- `capbox cp guest:…` paths must stay under `os/<distro>/` (no `..` escape).
- Prefer `--root /path/to/project` or project-local `.capbox/bin/capbox` over a HOME-wide state dir.

## Tests

```sh
bash test/selftest/run-selftest.sh   # framework + fake CLI
bash test/run.sh                     # real CLI (needs bwrap)
# optional: CAPBOX_TEST_DAEMON=1 …  CAPBOX_TEST_SLOW=1 …
bash -n bin/capbox lib/*.sh lib/guest/*.sh test/*.sh test/cases/*.sh
```

## Release safety

- `bin/capbox`, `test/run.sh`, `test/selftest/run-selftest.sh`, and `test/selftest/fake-cli/capbox` must be committed as Git mode `100755`.
- Content-only file upload APIs create `100644` entries and are unsafe for these scripts. Verify `git ls-files -s` and a fresh clone before release.
- CI deliberately invokes entry points directly; do not replace that with `bash <script>` or add a checkout `chmod` workaround.

## Docs

- Agent handbook: [`skill/SKILL.md`](skill/SKILL.md)
- Contributing / pitfalls: [`CONTRIBUTING.md`](CONTRIBUTING.md)

## Docs, Wiki, and user-visible copy

When editing README, `docs/`, Wiki, comments, CLI help, or error strings:

- Prefer short sentences, concrete commands/paths, and verifiable limits. No slogans.
- Cut empty adjectives and filler. Ban CN: 赋能 / 打造 / 一站式 / 助力 / 无缝 / 强大 (and similar). Ban EN: "It's important to note", "In conclusion", "Let's dive in", and parallel hedging.
- State a trust fact once where it belongs. Do not restack the same trust-boundary slogan across Home / MCP / Agent pages, or bold every default for layout.
- Avoid bold/list stacking used only for emphasis. Prefer plain prose plus a table or command block when listing facts.
- CN and EN should read like human tech notes, not machine-translated marketing.
- Copy-only edits must not change runtime behavior or loosen default trust boundaries (`isolated` / `untrusted` / `none`, no auto-apply of diffs, secrets on host).

## Network / recipe / resources

- `CAPBOX_NET=none|restricted|open`（`host`=`open`）。未知值失败，不回退 open。`restricted` 需 `CAPBOX_NET_ALLOW` + python3/nsenter；原始网络被 unshare，仅代理出站。oneshot 与 `capbox up` 都挂 allowlist 桥。无端口=仅 80/443；子域写 `*.host`。
- `capbox init --agent`：`untrusted` + `NET=none` + `IDMAP=off` + `RESOURCES_MODE=require`（额度需另设）。`pkg install` / `pkg update` 仍出网；其它出网要当次 `--net`。人类默认仍是 `compat` + `open`。
- `capbox up --systemd`：交给 systemd --user。没有 user bus 时才依赖外层后台任务。`--die-with-parent` 会杀掉 `nohup`/`setsid`。
- `capbox recipe apply`：KEY=value only，never source.
- Resource limits prefer cgroup v2 (`CAPBOX_CGROUP_ROOT` optional strict parent); otherwise WARN (no fake enforcement).

## UID map / services

- `CAPBOX_IDMAP=auto|on|off`；doctor 会报告 multi/single/blocked。blocked+on = 硬失败。`--uid` 降权优先用宿主 `gcc -static` 构建的 `capbox-drop-priv`（见 `lib/guest/capbox-drop-priv.c`）。
- `capbox exec --uid/--gid/--user`；`capbox service start|stop|status|logs`.
- 慢测：`./test/slow/run-slow.sh`（勿删 mssql 数据目录）。

## Residual risk

- Project workspace is RW at `/workspace` by design — treat its contents as trusted (use `FS_HIDE` / untrusted profile for sensitive subpaths).
- `bin/` / `lib/` / `config.env` are `--ro-bind`; other project files the host may execute later are not.
- Default profile is `compat` (full caps, no seccomp). Use `CAPBOX_SECURITY_PROFILE=untrusted|strict` for explicit hardening; multi-UID idmap skips `--disable-userns` (bwrap incompatibility).
- cgroup/disk limits need host delegation/loop+mount privileges (DISK_MAX is not rootless; uses sudo -n or root); otherwise CapBox WARNs or fail-closes — it does not fake enforcement. DISK_MAX covers guest /var/lib/capbox-data only.
- Mirror reachability depends on the network (`doctor` reports it; override with `CAPBOX_MIRROR_*`).

## Hardening / observability / reproducibility

- Security profiles, FS hide/bind, snapshots, image export/import, audit JSONL, metrics: see README.
- Service `.env` may include `READY_*`, `HEALTH_*`, `RESTART*`, `DEPENDS_ON`, `STOP_TIMEOUT`, `PUBLISH`.

## Environment isolation

- All bwrap launches use unconditional `--clearenv` then a minimal `--setenv` whitelist (`lib/launch.sh` shared `build_bwrap_args`; daemon delegates to it). See `SECURITY.md`.

## Configuration, upgrades and documentation

- Recipes reject unknown/duplicate keys and invalid lines. Use `recipe check` before apply; validated configuration batches commit once and preserve the config inode.
- Stop all services/daemon and other exec calls with the old CLI before upgrading. Use the new template's CLI: `capbox --root PROJECT upgrade check|apply --from TEMPLATE`; recover with `upgrade rollback`. Inspect differences first; apply replaces the complete bin/lib bundle, including custom files.
- `image lock save|verify|restore` uses strict package versions. `recipe apply --locked FILE` never falls back to unpinned versions. Version availability still depends on repositories.
- Update generated CLI/default references and verify versions with `python3 tools/generate-docs.py --check`; behavioral and compatibility checks are listed in `docs/testing.md`.
