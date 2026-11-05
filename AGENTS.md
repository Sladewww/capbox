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

## Docs

- Agent handbook: [`skill/SKILL.md`](skill/SKILL.md)
- Contributing / pitfalls: [`CONTRIBUTING.md`](CONTRIBUTING.md)


## Residual risk

- Project workspace is RW at `/workspace` by design — treat its contents as trusted.
- `bin/` / `lib/` / `config.env` are `--ro-bind`; other project files the host may execute later are not.
- No seccomp; guest has full capabilities inside the user namespace.
- Mirror reachability depends on the network (`doctor` reports it; override with `CAPBOX_MIRROR_*`).
