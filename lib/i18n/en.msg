# CapBox i18n catalog (en)
# Shared by bash and Python. Do not source this file.
# Single-line: key=value
# Multiline: key<< ... >>

log.prefix.info=[capbox]
log.prefix.warn=[capbox] warning:
log.prefix.err=[capbox] error:

help.main<<
CapBox — a persistent root Linux container in the workspace

Usage: capbox [--root DIR] [--debug] [--allow-old-bwrap] <command> [options] [-- args]

Global options
  --root DIR                        Workspace root (uses DIR/.capbox); same as CAPBOX_ROOT
  --debug                           Enable debug logs
  --allow-old-bwrap                 Accept bwrap older than 0.12.0 for this run only (not written to config; audited)

System lifecycle
  upgrade check|apply --from TEMPLATE / upgrade rollback
                                    Compare or update project runtime files; private backup, roll back on failure
  bootstrap                         Scaffold .capbox/ in the current workspace (copied from the template on PATH)
  init [--distro alpine|ubuntu] [--agent|--trusted] [--force] [--from URL|path]
                                    Scaffold if needed, download and unpack the rootfs, inject mirrors, run first boot
  status [--json]                   Show distro / rootfs / daemon / network status
  doctor                            Check each item (bwrap, full userns privileges, rootfs, mirrors, …)
  clean [--all]                     Clean cache and logs; --all also deletes the rootfs

Execution
  exec [--daemon] [--timeout N] [--cwd DIR] [--uid N] [--gid N] [--user NAME] [--] CMD...
                                    Run a command in the container (default: one-shot, no persistent state)
  setup check|plan [--json]         Host dependency checks and install/upgrade plan (does not install)
  bundle pack|verify|check|restore DIR
                                    Portable rootfs / recipe / package-lock artifact and integrity checks
  mcp serve                         stdio MCP adapter with a fixed workspace and policy
  task start|list|status|logs|attach|wait|cancel|diff|rm
                                    Persistent tasks, reconnect after disconnect, and isolated worktree diff (task --help)
  policy show|check                 Preview the effective policy for a new oneshot and HTTP(S) network decisions
  service start|stop|status|logs|list
                                    Configured services (.capbox/services/<name>.env)
  shell [--daemon]                  Interactive shell (falls back to sh reading stdin when there is no tty)
  ls [PATH]                         List a directory in the container (default /workspace)
  ps                                List processes in the container

Persistent container (prefers a systemd user service; plain up needs an outer background supervisor)
  up [--systemd]                    Start the daemon container
  down                              Stop the daemon container
  logs [-f] [-n N]                  Show daemon container logs

Files and packages
  cp SRC DST                        Copy host ↔ container (guest:/path or host:/path)
  pkg install|remove|update|list [--] PKG...
                                    Dispatches to apk / apt-get by distro

Info and configuration
  distros                           List supported distros and mirror URLs
  config get|set|list               Read or change config.env
  recipe check|apply|show [FILE]          Apply or show a declarative KEY=value recipe (never sourced)
  snapshot create|list|restore|rm   rootfs snapshot / rollback
  image export|import|lock|cache    Images and offline cache; lock save|verify|restore
  secret set|ls|rm|import           Host credentials (real keys never enter the sandbox; see docs/credentials.md)
  audit report|tail|path|clear      Offline HTML report and JSONL audit log
  metrics [--json]                  Real resource / cgroup / disk status (no fabricated numbers)
  version                           Print the version
  help, --help, -h                  Show this help

Network (CAPBOX_NET)
  none         --unshare-net, no network in the container
  open (host)  Share the host network (default; host is a compatibility alias)
  restricted   --unshare-net + domain allowlist proxy (needs python3/nsenter and CAPBOX_NET_ALLOW)
               Does not pretend bwrap can filter domains; raw TCP has no route, only HTTP(S)_PROXY egress
  Per-invocation  exec|shell|up --net MODE (does not write config.env). shell/exec --daemon cannot change a running network
  pkg          When the session is none, install and update still go online; remove and list do not

Security profiles (CAPBOX_SECURITY_PROFILE / exec --profile)
  compat       Default compatibility: full capabilities, no seccomp (does not weaken existing behavior)
  untrusted    Explicit tightening: capability drop + real seccomp BPF + disable-userns
  strict       Stricter seccomp + read-only rootfs by default (needs overlay to write the root) + Landlock by default
  Landlock     CAPBOX_LANDLOCK=on|off. When unset, only strict enables it. Restricts VFS after mounts, not TCP

Examples
  capbox bootstrap                       # create .capbox/ in the current directory only
  capbox init --agent --distro alpine    # agent: untrusted/none; limits must be set separately
  capbox init --trusted --distro alpine  # trusted development: compat/open
  capbox recipe apply                    # write config / init / install packages from capbox.recipe
  capbox exec --net none -- id -u        # one-shot with no network
  capbox exec -- id -u                   # should be 0 inside the container
  capbox pkg install curl                # mirrors and APK install script compatibility wrapper
  echo 'echo hi' | capbox shell          # works without a tty

Exit codes
  0   Success
  1   General error (download failure, internal failure, and so on)
  2   Usage error
  3   Daemon container is not running (commands that need the daemon)
  4   rootfs is missing (run capbox init first)
  5   Missing dependency (bwrap, and so on)
  6   Security baseline not met (bwrap older than 0.12.0, and not explicitly allowed)
  124 Command inside the container timed out

Notes
  * The compat profile defaults to uid 0 + full capabilities; the agent entry uses the explicit --agent preset.
  * --agent require only applies to limits that are already set; an empty MEMORY_MAX/CPU_MAX/PIDS_MAX means no quota.
  * CAPBOX_IDMAP=auto tries newuidmap multi-UID mapping and falls back honestly to a single UID on failure (see doctor).
  * rootfs and config live in the project's .capbox; host control files live in a 0700 private directory outside the workspace.
  * For a persistent environment use up --systemd, or a supervisor that outlives the tool call; an outer die-with-parent affects nohup.
>>

help.init<<
Usage: capbox init [--distro alpine|ubuntu] [--force] [--from URL|local-path] [--agent|--trusted]

  If the current workspace has no complete .capbox/, scaffold bin/, lib/, and
  skill/ into $PWD/.capbox from the installed CapBox template first
  (does not overwrite existing files; does not copy cache/os/run).

  --distro D   Choose a distro (defaults to CAPBOX_DISTRO, initially alpine)
  --force      Ignore the cache, re-download, and overwrite an existing rootfs
  --from P     Image source: an http(s) URL or a local tarball path
  --trusted    Trusted development preset: compat + open + IDMAP=auto + RESOURCES_MODE=warn
  --agent      Agent preset: untrusted + none + IDMAP=off + RESOURCES_MODE=require
               Set MEMORY_MAX/CPU_MAX/PIDS_MAX per task; empty means no quota is set.
               pkg install / pkg update still go online. Other egress is declared per command:
               exec|shell|up --net restricted (needs CAPBOX_NET_ALLOW) or --net open
>>

help.bootstrap<<
Usage: capbox bootstrap

  Create or complete .capbox/ in the current workspace (copy bin, lib, skill from the installed template).
  Does not download a rootfs; run capbox init afterwards.
>>

help.upgrade<<
Usage: capbox upgrade check --from TEMPLATE [--json]
      capbox upgrade apply --from TEMPLATE
      capbox upgrade rollback

  TEMPLATE is a complete CapBox install directory (with bin/lib) outside the workspace that you trust.
  check compares runtime files; apply stages and verifies the full bin/lib set, then replaces after a private backup.
  On replace or smoke-check failure the original files are restored; rollback restores files from the last successful upgrade.
  Stop every service/daemon with the old CLI first, and stop other exec sessions; this command will not kill processes for you.
  Only runtime files are updated; config, rootfs, and business data stay in place. Backups persist outside the workspace under XDG_STATE_HOME/capbox (default ~/.local/state/capbox).
  For older projects, invoke this command from a new template's bin/capbox (--root points at the project).
>>

help.recipe<<
Usage: capbox recipe apply [--locked LOCKFILE] [FILE]
      capbox recipe check [FILE]
      capbox recipe show  [FILE]

  Declarative KEY=value recipe (never sourced). Default files:
    ./capbox.recipe  or  .capbox/recipe.env

  Common keys: DISTRO PACKAGES NET NET_ALLOW MEMORY_MAX CPU_MAX PIDS_MAX MIRROR INIT
  export FILE: export validated JSON recipe data (does not run it).
  check: full validation, no config writes. Unknown, duplicate, or invalid lines are errors.
  apply: full validation → write config.env once → init if needed → install PACKAGES
  --locked: install and verify against a strict package lock; fail if a version is unavailable.
>>

help.image<<
Usage: capbox image <export|import|list|verify|lock|cache> ...

  export NAME              Export the current rootfs → .capbox/images/NAME.tar.zst|gz + .sha256
  import NAME [--force]    Import into a side directory os/<distro>.imported-NAME; only --force replaces the current rootfs
  list                     List exported images
  verify NAME              Verify SHA256
  lock save|show|verify|restore [FILE]  Save, show, verify, or restore a package lock at exact versions
  cache save|restore|path  Offline package cache (pack the apk/apt cache directory)

Import does not destroy an existing rootfs by default; --force takes a snapshot-bak first, then replaces.
>>

help.service<<
Usage: capbox service <start|stop|status|logs|list> NAME [options]

  start NAME     Start from .capbox/services/NAME.env (its own bwrap)
  stop NAME      Stop the service
  status NAME    Show status and diagnostics
  logs NAME [-f] [-n N]
  list           List defined services

Example (.capbox/services/nginx.env):
  CMD='nginx -g "daemon off;"'
  USER=www-data
  CWD=/
  READY_TCP=127.0.0.1:18080
  HEALTH_INTERVAL=5
  RESTART=on-failure
  RESTART_MAX=3
  STOP_TIMEOUT=10
  DEPENDS_ON=other
>>

help.service.logs<<
Usage: capbox service logs NAME [-f] [-n N]
>>

help.audit<<
Usage: capbox audit <report|tail|path|clear> [args]

  report --output FILE  Generate an offline HTML report (the file must be outside the workspace; see report --help for filters)
  tail [N]   Show the last N records (default 50)
  path       Print the audit file path
  clear      Empty the audit file (running the command is the confirmation)

CAPBOX_AUDIT=off|summary|full
  summary (default): record redacted full arguments, status, exit code, and duration;
                 failures may include a truncated short detail. Does not write command stdout/stderr.
  full: like summary, plus a capped, redacted output field.
CAPBOX_AUDIT_CMD=summary|full|off
  When unset, follows CAPBOX_AUDIT. off omits the cmd field.
  summary and full both record redacted full arguments (no longer argv0 plus an argument count).
>>

help.pkg<<
Usage: capbox pkg <install|remove|update|list> [--] PKG...

  install PKG...   Install packages
  remove PKG...    Remove packages
  update           Refresh the package index
  list [PATTERN]   List installed packages (optional filter)

Dispatches to apk (alpine) or apt-get (ubuntu) by distro;
ubuntu automatically adds APT::Sandbox::User=root (required in this environment).
When session CAPBOX_NET=none, install and update still go online; remove and list do not.
That egress is not written to config.env. pip / npm / git do not gain network from this.
After install, dpkg --audit / iU·iF state is scanned; leftover config is reported plainly (not hidden).
With CAPBOX_IDMAP=auto/on and a multi mapping available, apt postinst chown is more likely to succeed.
>>

help.secret<<
Usage: capbox secret set|ls|rm|import

  secret set <service> [--value-stdin|--command CMD]
  secret set --custom --host HOST [--host HOST...] --env NAME [--name ID] [--value-stdin|--command CMD]
  secret ls
  secret rm <name>
  secret import [service] [--all] [--force] [--dry-run]

Real secrets stay in a private host directory (0700/0600). The guest only sees capbox-sec-<32hex> placeholders;
the restricted proxy rewrites HTTP(S) request headers for NET_ALLOW-authorized domains. See docs/credentials.md.
>>

help.snapshot<<
Usage: capbox snapshot <create|list|restore|rm> [NAME]

  create NAME   Pack the current rootfs into .capbox/snapshots/NAME.tar.zst|gz (keeps numeric owners)
  list          List snapshots
  restore NAME  Roll back the rootfs (write to a temporary directory first, then replace; does not destroy unconfirmed live data in place)
  rm NAME       Delete a snapshot

Note: restore replaces os/<distro>/; create a backup first. Unrelated data directories are left alone.
>>

help.down<<
Usage: capbox down
Stop the persistent daemon container
>>

help.status<<
Usage: capbox status [--json]
>>

help.logs<<
Usage: capbox logs [-f] [-n N]

  Show stdout/stderr of the daemon container (the bwrap process).
  -f  Follow (exit with Ctrl-C)
  -n  Show the last N lines, default 50
>>

help.exec<<
Usage: capbox exec [--daemon] [--timeout N] [--cwd DIR] [--root] [--net MODE]
                  [--uid N] [--gid N] [--user NAME] [--profile compat|untrusted|strict] [--] CMD...

  --daemon     Run inside the persistent container (start capbox up first)
  --timeout N  One-shot timeout in seconds, 0=unlimited, default CAPBOX_EXEC_TIMEOUT
  --cwd DIR    Working directory in the container (default /workspace; relative paths are interpreted under /workspace)
  --root       Run under the container root / (same as --cwd /)
  --net MODE   Override CAPBOX_NET for this oneshot: none|restricted|open (host=open)
               Does not write config.env. Cannot be combined with --daemon (the daemon network is set at up)
  --uid N      Initial uid in the container (default CAPBOX_EXEC_UID / 0); with --daemon, drop privileges before the command
  --gid N      Initial gid in the container
  --user NAME  Resolve uid:gid from guest /etc/passwd (alternative to a numeric uid)
  --profile P  Override CAPBOX_SECURITY_PROFILE (this oneshot only)

stdout contains only the command output from inside the container, so it can be piped.
The exit code is the command's exit code; 124 on timeout; 3 if a daemon is required but not running.
>>

help.shell<<
Usage: capbox shell [--daemon] [--net MODE]
  Interactive shell (falls back to sh reading stdin when there is no tty)
  --net applies only to a one-shot shell; it does not write config.env and cannot change a running daemon
>>

help.clean<<
Usage: capbox clean [--cache] [--all]

  (no options)  Clean logs, temporary files, and leftover one-shot exec state; **keeps the cache and rootfs**
  --cache     Also clean downloaded image tarballs under cache/
  --all       Clean the cache and delete the current distro's rootfs (most thorough; requires init again)

Note: clean first stops a running daemon container (same as capbox down, graceful exit),
      then cleans run/tmp — the backend for /tmp in the container. The directory itself is kept so the daemon can restart.
>>

help.metrics<<
Usage: capbox metrics [--json]
  Show real probe results for cgroup/disk/security profile/network (does not invent configured limits).
>>

help.ls<<
Usage: capbox ls [PATH]    List a directory in the container (default /workspace)
>>

help.ps<<
Usage: capbox ps    List processes in the container
>>

help.cp<<
Usage: capbox cp SRC DST

Path syntax (contract §3.1: container paths are rooted at os/<distro>/):
  guest:/path   Absolute path in the container → os/<distro>/path
  host:/path    Host path (relative paths resolve from the current cwd)
  /abs/path     Bare absolute path = container side
  rel/path      Bare relative path = container side (relative to the rootfs root)

Note: **paths without a prefix are always container-side**; use host: for host files.

Examples:
  capbox cp guest:/etc/os-release host:./os-release
  capbox cp host:./app.conf guest:/etc/app.conf
  capbox cp host:/tmp/a.txt /root/a.txt          # lands at rootfs/root/a.txt
>>

help.up<<
Usage: capbox up [--systemd] [--net MODE]

Start the persistent daemon container.

Default: block in the foreground. If the caller's shell wraps bwrap --die-with-parent
(DSH / some coding-agent bash tools), the whole process tree dies when this invocation ends;
nohup/setsid cannot save it. Two ways to keep it alive:

  1) capbox up --systemd
     Hand it to a systemd --user transient service; the process does not belong to this tool call.
     Needs a user systemd session (systemctl --user must work). capbox down later stops that unit.
  2) Put capbox up in a task that outlives the tool call (for example a bash tool's run_in_background).

  --net MODE   Applies only to this up (none|restricted|open, host=open). Does not write config.env.
               Does not change the network of a unit that is already running.

Stop: capbox down
>>
