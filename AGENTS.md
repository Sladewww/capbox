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
   State lives in **`$PWD/.capbox/`** (rootfs, `config.env`, daemon).  
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


## Network / recipe / resources

- `CAPBOX_NET=none|restricted|open`（`host`=`open`）。`restricted` 需 `CAPBOX_NET_ALLOW` + python3/nsenter；原始网络被 unshare，仅代理出站。
- `capbox recipe apply`：KEY=value only，never source.
- Resource limits prefer cgroup v2; otherwise WARN (no fake enforcement).

## UID map / services

- `CAPBOX_IDMAP=auto|on|off`；doctor 会报告 multi/single/blocked。blocked+on = 硬失败。
- `capbox exec --uid/--gid/--user`；`capbox service start|stop|status|logs`.
- 慢测：`./test/slow/run-slow.sh`（勿删 mssql 数据目录）。

## Residual risk

- Project workspace is RW at `/workspace` by design — treat its contents as trusted (use `FS_HIDE` / untrusted profile for sensitive subpaths).
- `bin/` / `lib/` / `config.env` are `--ro-bind`; other project files the host may execute later are not.
- Default profile is `compat` (full caps, no seccomp). Use `CAPBOX_SECURITY_PROFILE=untrusted|strict` for explicit hardening; multi-UID idmap skips `--disable-userns` (bwrap incompatibility).
- cgroup/disk limits need host delegation/loop privileges; otherwise CapBox WARNs or fail-closes — it does not fake enforcement.
- Mirror reachability depends on the network (`doctor` reports it; override with `CAPBOX_MIRROR_*`).

## Hardening / observability / reproducibility

- Security profiles, FS hide/bind, snapshots, image export/import, audit JSONL, metrics: see README.
- Service `.env` may include `READY_*`, `HEALTH_*`, `RESTART*`, `DEPENDS_ON`, `STOP_TIMEOUT`, `PUBLISH`.
