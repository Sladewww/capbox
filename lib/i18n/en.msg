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

# Host bash log_*/die and usage/error message bodies
val.unset=not set
val.see_doctor=see doctor
val.unknown=unknown
val.unknown_error=unknown error
val.no_cgroup_delegate=no cgroup delegation
val.unavailable=unavailable
cli.ignore_allow_old_bwrap=Ignoring environment variable CAPBOX_ALLOW_OLD_BWRAP={value}; write a persistent allow to config.env, or pass --allow-old-bwrap for a one-shot allow
cli.root_missing_arg=--root requires an argument (workspace path)
cli.template_not_found=CapBox template not found (no lib/ next to the CLI); install CapBox or use a project-local .capbox/bin/capbox
cli.root_not_found=CapBox root directory (.capbox) not found; run capbox init from a project, or set CAPBOX_ROOT=/path/to/project
cli.upgrade_incomplete=A runtime file upgrade did not finish; run upgrade rollback with a complete template
cli.cannot_load_common=Unable to load {dir}/common.sh
cli.incomplete_install=Incomplete install, missing {dir}/{module}.sh
common.bwrap_below_baseline=FAIL  bwrap {ver} is below the 0.12.0 security baseline
common.need_cmd=Missing required command: {cmd}
common.need_cmd_hint=Missing required command: {cmd} ({hint})

rootfs.need_curl_to_download=Downloading a rootfs requires curl
rootfs.need_tar_to_unpack=Unpacking a rootfs requires tar
rootfs.need_curl_to_init_from_url=Initializing from a URL requires curl
config.need_flock_to_commit=Committing configuration requires an inter-process lock
config.need_flock_to_read=Reading configuration requires a shared lock
cli.cmd_unavailable=Command '{label}' is unavailable: missing implementation function {fn}
cli.cmd_unavailable_hint=Command '{label}' is unavailable: missing implementation function {fn} ({hint})

cli.module_not_ready={module} is not ready
cli.unknown_global_option=Unknown global option: {arg}
cli.unknown_command=Unknown command: {cmd}
audit.audit_log_must_regular_file_refusing_write=Audit log must be a regular file, refusing to write: {f}
audit.unable_truncate=Unable to truncate {f}
audit.cleared_audit_log=Cleared audit log: {f}
audit.audit_tail_n_must_non_negative_integer=audit tail: N must be a non-negative integer
audit.audit_unknown_subcommand_report_tail_path_clear=audit: unknown subcommand {sub} (report|tail|path|clear)
audit.metrics_unknown_option=metrics: unknown option {arg}
common.net_must_none_restricted_open_host_alias={who}: --net must be none|restricted|open (host is an alias); got: {mode}
common.net_restricted_requires_non_empty_capbox_net={who}: --net restricted requires a non-empty CAPBOX_NET_ALLOW (config set or environment variable)
common.configured_capbox_bwrap_not_executable_trying_auto=Configured CAPBOX_BWRAP={cfg_val} is not executable, trying auto-discovery
common.bwrap_unavailable=bwrap is unavailable: {bwrap}
common.bwrap_below_0_12_0_security_baseline=bwrap {ver} is below the 0.12.0 security baseline and was allowed by CAPBOX_ALLOW_OLD_BWRAP (doctor still reports FAIL)
common.unable_write_old_bwrap_allow_audit_record=Unable to write the old-bwrap allow audit record, refusing to start
common.audit_log_path_symlink_refusing_record_old=Audit log path is a symlink, refusing to record an old-bwrap allow: {f}
common.audit_log_directory_not_regular_directory_refusing=Audit log directory is not a regular directory, refusing to record an old-bwrap allow: {dir}
common.audit_log_path_unusable_refusing_record_old=Audit log path is unusable, refusing to record an old-bwrap allow: {f}
common.host_private_directory_must_owned_current_user=Host private directory must be owned by the current user, mode 0700, and not a symlink: {candidate}
common.no_safe_host_runtime_directory_found_outside=No safe host runtime directory found outside the workspace (need a private runtime or sticky /tmp)
common.unable_normalize_path_realpath_m_required=Unable to normalize path (realpath -m required): {p}
common.refused_workspace_resolved_dangerous_path_project_local=Refused: workspace resolved to a dangerous path ({workspace}). Use a project-local .capbox/, or set CAPBOX_ROOT=/path/to/project (do not install CapBox under $HOME as a global CLI, or the whole home directory would be bound).
common.guest_path_must_not_contain=guest path must not contain ..: {guest_path}
common.protected_config_path_symlink_refusing_start=Protected config path is a symlink, refusing to start: {host_file}
common.protected_config_path_directory_skipping_file_pre=Protected config path is a directory, skipping file pre-seeding: {host_file}
common.unable_create_mount_point_missing_config_file=Unable to create a mount point for a missing config file: {host_file}
common.protected_directory_symlink_refusing_start=Protected directory is a symlink, refusing to start: {host_dir}
common.regular_file_exists_protected_directory_path_skipping=A regular file exists on the protected directory path, skipping: {host_dir}
common.logs_symlink_refusing_start=logs is a symlink, refusing to start: {host_dir}
common.logs_must_regular_directory_refusing_start=logs must be a regular directory, refusing to start: {host_dir}
common.logs_audit_jsonl_symlink_refusing_start_audit=logs/audit.jsonl is a symlink, refusing to start: {host_dir}/audit.jsonl
common.logs_audit_jsonl_must_regular_file_refusing=logs/audit.jsonl must be a regular file, refusing to start: {host_dir}/audit.jsonl
common.unable_bind_mount_logs_read_only_guest=Unable to bind-mount logs read-only into the guest: {host_dir}
common.capbox_dir_symlink_refusing_start=CAPBOX_DIR is a symlink, refusing to start: {dir}
common.protected_directory_symlink_refusing_start_2=Protected directory is a symlink, refusing to start: {host_path}
common.refusing_clean_path_outside_workspace=Refusing to clean a path outside the workspace: {d}
common.refusing_delete_not_under_os=Refusing to delete: {d} is not under {dir}/os/
common.removing_rootfs=Removing rootfs: {d}
common.lock_missing_command_run=with_lock: missing command to run
common.timed_out_waiting_lock=Timed out waiting for lock: {lockfile}
common.unable_generate=Unable to generate {dst}
common.run_bwrap_oneshot_missing_guest_command=run_bwrap_oneshot: missing in-guest command
common.unable_build_bwrap_arguments_rc_common_causes=Unable to build bwrap arguments (rc={_bbrc}; common causes: bwrap too old, FS_BINDS out of bounds, or security profile/seccomp failure)
common.rootfs_does_not_exist_run_capbox_init=rootfs does not exist: {rootfs} (run capbox init first)
common.bwrap_unavailable_apt_install_bubblewrap=bwrap is unavailable: {bwrap} (apt install bubblewrap)
common.capbox_net_restricted_net_sh_not_loaded=CAPBOX_NET=restricted but net.sh is not loaded
common.capbox_idmap_multi_uid_mapping_unavailable=CAPBOX_IDMAP=on but multi-UID mapping is unavailable: {detail}
common.exec_guest_command_empty=exec_in_guest: command is empty
common.unable_create_capbox_current_workspace=Unable to create .capbox in the current workspace
common.rootfs_missing_unusable_run_capbox_init_distro=rootfs is missing or unusable: {rootfs}; run: capbox init --distro {distro} (this also scaffolds .capbox in the current directory)
common.status_unknown_option=status: unknown option {arg}
common.usage_capbox_config_get_key=Usage: capbox config get KEY
common.unknown_config_key_available=Unknown config key: {arg}; available: {keys}
common.usage_capbox_config_set_yes_key_value=Usage: capbox config set [--yes] KEY VALUE
common.set=Set {key} = {val}
common.usage_capbox_config_get_set_list_key=Usage: capbox config <get|set|list> [KEY] [VALUE]
common.clean_unknown_option=clean: unknown option {arg}
common.daemon_container_running_clean_will_stop_first=A daemon container is running; clean will stop it first (graceful shutdown, waiting for in-flight tasks)
common.failed_stop_daemon_container_rc_continuing_temp=Failed to stop the daemon container (rc={drc}, continuing with temp file cleanup)
common.cleaning_logs=Cleaning logs ({log_dir})
common.cleaning_temporary_state_ec=Cleaning temporary state ({state_dir}/ec-*, {tmp_dir})
common.cleaning_cache=Cleaning cache ({cache_dir})
common.cache_kept_files_about_pass_cache_all=Cache kept ({n_cache} files, about {size}); pass --cache or --all to clean it
common.removed_rootfs_cache_run_capbox_init_again=Removed rootfs and cache; run capbox init again before next use
common.cleaned_logs_temp_files_rootfs_cache_kept=Cleaned logs/temp files (rootfs and cache kept)
common.capbox_template_tree_not_found_install_lib=CapBox template tree not found (an install with lib/common.sh is required). Install the CapBox Skill/CLI first.
common.creating_capbox_current_workspace_template=Creating .capbox in the current workspace … (template: {template} → {dir})
common.unable_create=Unable to create {dir}
common.scaffold_copy_failed=Scaffold copy failed: {srcd}
common.lib_common_sh_still_missing_after_scaffolding=lib/common.sh is still missing after scaffolding
common.bin_capbox_still_missing_after_scaffolding=bin/capbox is still missing after scaffolding
common.workspace_ready=Workspace is ready: {dir}
common.capbox_auto_init_1_running_capbox_init=CAPBOX_AUTO_INIT=1: running capbox init automatically
config.capbox_distro_must_alpine_ubuntu_got=CAPBOX_DISTRO must be alpine or ubuntu (got: '{v}')
config.capbox_mirror_must_cn_global_none_got=CAPBOX_MIRROR must be cn / global / none (got: '{v}')
config.capbox_net_must_none_restricted_open_host=CAPBOX_NET must be none / restricted / open (host is a compatibility alias for open; got: '{v}')
config.capbox_net_allow_may_only_contain_domain=CAPBOX_NET_ALLOW may only contain domain/IP/comma/colon/slash/asterisk (got: '{v}')
config.invalid_capbox_memory_max_format_e_g=Invalid CAPBOX_MEMORY_MAX format (e.g. 512M / 1G; got: '{v}')
config.invalid_capbox_cpu_max_format_e_g=Invalid CAPBOX_CPU_MAX format (e.g. 50% or '50000 100000'; got: '{v}')
config.capbox_pids_max_must_positive_integer_got=CAPBOX_PIDS_MAX must be a positive integer (got: '{v}')
config.capbox_exec_timeout_must_non_negative_integer=CAPBOX_EXEC_TIMEOUT must be a non-negative integer number of seconds (got: '{v}')
config.capbox_proxy_must_start_http_https_socks5=CAPBOX_PROXY must start with http://, https://, socks5://, or socks5h://, or be empty for a direct connection (got: '{v}')
config.capbox_hostname_may_only_contain_letters_digits=CAPBOX_HOSTNAME may only contain letters, digits, '.', and '-' (got: '{v}')
config.capbox_must_url_starting_http_s_got=CAPBOX_{k} must be a URL starting with http(s):// (got: '{v}')
config.capbox_bwrap_must_not_empty_path_bubblewrap=CAPBOX_BWRAP must not be empty (path to the bubblewrap executable)
config.capbox_idmap_must_auto_off_got=CAPBOX_IDMAP must be auto / on / off (got: '{v}')
config.capbox_segments_must_guest_host_count_current=CAPBOX_{k} segments must be guest:host:count (current segment: '{part}')
config.capbox_setgroups_must_allow_deny_got=CAPBOX_SETGROUPS must be allow / deny (got: '{v}')
config.capbox_must_non_negative_integer_got=CAPBOX_{k} must be a non-negative integer (got: '{v}')
config.invalid_capbox_disk_max_format_e_g=Invalid CAPBOX_DISK_MAX format (e.g. 1G; got: '{v}')
config.capbox_resources_mode_must_warn_require_got=CAPBOX_RESOURCES_MODE must be warn|require (got: '{v}')
config.capbox_security_profile_must_compat_untrusted_strict=CAPBOX_SECURITY_PROFILE must be compat|untrusted|strict (got: '{v}')
config.capbox_landlock_must_off_got_when_unset=CAPBOX_LANDLOCK must be on or off (got: '{v}'). When unset, strict enables it by default
config.capbox_rootfs_ro_must_0_1_got=CAPBOX_ROOTFS_RO must be 0/1 (got: '{v}')
config.capbox_fs_hide_contains_illegal_characters_got=CAPBOX_FS_HIDE contains illegal characters (got: '{v}')
config.capbox_fs_hide_must_not_contain=CAPBOX_FS_HIDE must not contain ..
config.capbox_fs_binds_contains_illegal_characters_got=CAPBOX_FS_BINDS contains illegal characters (got: '{v}')
config.capbox_fs_binds_must_not_contain=CAPBOX_FS_BINDS must not contain ..
config.capbox_overlay_must_auto_0_1_got=CAPBOX_OVERLAY must be auto|0|1 (got: '{v}')
config.capbox_audit_must_off_summary_full_got=CAPBOX_AUDIT must be off|summary|full (got: '{v}')
config.capbox_audit_cmd_must_off_summary_full=CAPBOX_AUDIT_CMD must be off|summary|full (got: '{v}')
config.capbox_allow_old_bwrap_must_0_1=CAPBOX_ALLOW_OLD_BWRAP must be 0 or 1 (got: '{v}'). To allow persistently: capbox config set --yes CAPBOX_ALLOW_OLD_BWRAP 1
config.unknown_config_key_capbox=Unknown config key: CAPBOX_{k}
config.config_target_must_regular_file=Config target must be a regular file: {f}
config.failed_write_config=Failed to write config: {f}
config.config_batch_must_key_value_pairs=Config batch must be key/value pairs
config.unknown_config_key=Unknown config key: {k}
config.config_env_rejected_double_quoted_value_containing=config.env rejected a double-quoted value containing expansion characters: {key}
config.config_env_rejected_unsafe_bare_value=config.env rejected an unsafe bare value: {key}
config.ignoring_environment_variable_capbox_allow_old_bwrap=Ignoring environment variable CAPBOX_ALLOW_OLD_BWRAP={value}; persistent allow must be written to config.env, one-shot allow uses capbox --allow-old-bwrap
config.unable_create_safe_config_lock_directory=Unable to create a safe config lock directory
config.unable_open_config_lock=Unable to open the config lock
config.timed_out_waiting_config_read_lock=Timed out waiting for the config read lock
config.config_must_readable_regular_file_refusing_continue=Config must be a readable regular file; refusing to continue with defaults
config.capbox_distro_empty_falling_back_alpine=CAPBOX_DISTRO is empty, falling back to alpine
config.capbox_net_must_none_restricted_open_host_2=CAPBOX_NET must be none / restricted / open (host is an alias for open; got: '{net}'). Refusing to fall back to open
config.persistent_allow_old_bwrap_requires_yes_audit=Persistent allow of an old bwrap requires --yes (an audit record is written; doctor still reports FAIL)
config.unable_write_old_bwrap_allow_audit_record=Unable to write the old-bwrap allow audit record, CAPBOX_ALLOW_OLD_BWRAP has been reverted
cred.unknown_secret_subcommand=Unknown secret subcommand: {arg}
cred.failed_prepare_credentials_session=Failed to prepare the credentials session
daemon.launch_module_incomplete_unified_bwrap_security_gate=Launch module is incomplete: unified bwrap security gate is missing
daemon.launch_module_incomplete_lib_launch_sh_missing=Launch module is incomplete: lib/launch.sh is missing
daemon.daemon_request_command_empty=daemon_request: command is empty
daemon.daemon_container_not_running_start_first_dsh=Daemon container is not running; start it first as a DSH background task: capbox up
daemon.daemon_container_stopping_draining_flight_tasks_not=Daemon container is stopping (draining in-flight tasks) and is not accepting new requests; retry later or run capbox up again
daemon.unable_write_request_file=Unable to write request file: {reqf}
daemon.unable_submit_request=Unable to submit request: {reqf}
daemon.guest_command_timed_out_s=In-guest command timed out ({timeout_s}s)
daemon.daemon_container_stopped_while_command_running_heartbeat=Daemon container stopped while the command was running (heartbeat lost); request abandoned
daemon.unable_build_daemon_container_bwrap_arguments_rc=Unable to build daemon-container bwrap arguments (rc={brc})
daemon.daemon_container_bwrap_arguments_empty=Daemon-container bwrap arguments are empty
daemon.capbox_up_systemd_requires_systemd_run=capbox up --systemd requires systemd-run
daemon.capbox_up_systemd_requires_systemctl=capbox up --systemd requires systemctl
daemon.user_systemd_unavailable_systemctl_user_has_no=User systemd is unavailable (systemctl --user has no bus). Run capbox up from a longer-lived task, or enable lingering on the login session
daemon.systemd_unit_service_already_running_workingdirectory_which=systemd unit {unit}.service is already running, but WorkingDirectory={wd}, which is not this workspace {workspace}
daemon.systemd_unit_service_already_running=systemd unit {unit}.service is already running
daemon.capbox_executable_not_found_cannot_hand_off=capbox executable not found, cannot hand off to systemd
daemon.handed_off_systemd_user_unit_service_detached=Handed off to systemd --user unit {unit}.service (detached from the current process tree)
daemon.systemd_run_failed=systemd-run failed
daemon.unit_submitted_inspect_systemctl_user_status_service=Unit submitted. Inspect with: systemctl --user status {unit}.service
daemon.stop_capbox_down=Stop with: capbox down
daemon.up_net_requires_mode_none_restricted_open=up: --net requires a mode none|restricted|open
daemon.up_unknown_option=up: unknown option {arg}
daemon.missing_server_script_lib_guest_daemon_sh=Missing server script: {dir}/lib/guest/daemon.sh
daemon.daemon_container_already_running_pid_no_need=Daemon container is already running (pid {pid}), no need to start again
daemon.unable_build_bwrap_command=Unable to build the bwrap command
daemon.starting_daemon_container_rootfs=Starting daemon container (rootfs={rootfs})
daemon.got_termination_signal_asking_daemon_container_shut=Got a termination signal, asking the daemon container to shut down gracefully…
daemon.idmap_failed_start_daemon_container=idmap failed to start the daemon container: {detail}
daemon.restricted_daemon_container_network_bridge_not_ready=restricted: daemon-container network bridge is not ready (see {path})
daemon.restricted_daemon_container_allowlist_proxy_bridge_ready=restricted: daemon-container allowlist proxy bridge is ready
daemon.got_termination_signal_waiting_daemon_container_exit=Got a termination signal, waiting for the daemon container to exit…
daemon.daemon_container_ready_guest_pid_hostname=Daemon container is ready (in-guest pid {pid}, hostname {hostname})
daemon.ipc_directory=IPC directory: {daemon_dir}
daemon.stop_capbox_down_end_background_task_hosts=Stop with: capbox down (or end the background task that hosts this process)
daemon.daemon_container_failed_start_exit_recent_logs=Daemon container failed to start (exit {brc}), recent logs:
daemon.daemon_container_did_not_write_daemon_json=Daemon container did not write daemon.json within 20s, still waiting (log: {logf})
daemon.new_instance_has_taken_over_iid_keeping=A new instance has taken over (iid {cur_iid}…); keeping its state files
daemon.daemon_container_stopped_exit=Daemon container stopped (exit {rc})
daemon.down_unknown_option=down: unknown option {arg}
daemon.stopping_systemd_unit_service=Stopping systemd unit {unit}.service
daemon.orphan_server_detected_fresh_heartbeat_no_daemon=Orphan server detected (fresh heartbeat but no daemon.json); asking it to shut down gracefully
daemon.orphan_server_did_not_exit_within_10s=Orphan server did not exit within 10s (it may be too old and lack self-heal)
daemon.suggestion_end_tty_job_hosts_delete_hb=Suggestion: end the TTY/job that hosts it, or delete {daemon_dir}/hb and retry
daemon.orphan_server_has_exited=Orphan server has exited
daemon.stale_state_files_found_daemon_process_gone=Stale state files found (daemon process is gone) and cleaned up
daemon.daemon_container_not_running=Daemon container is not running
daemon.stopping_daemon_container_guest_pid=Stopping daemon container (in-guest pid {pid})
daemon.unable_write_ctl_stop=Unable to write {daemon_dir}/ctl/stop
daemon.server_did_not_acknowledge_stop_request_within=Server did not acknowledge the stop request within {noack}s (it may have crashed); cleaning state files directly
daemon.daemon_container_stopped=Daemon container stopped
daemon.daemon_container_did_not_exit_within_s=Daemon container did not exit within {limit}s; cleaning state files
daemon.cannot_force_kill_across_pid_namespace_container=(Cannot force-kill across a PID namespace; the container will end with the background task that hosts it)
daemon.logs_unknown_option=logs: unknown option {arg}
daemon.logs_n_must_non_negative_integer=logs: -n must be a non-negative integer
daemon.no_daemon_container_logs_yet_does_not=No daemon-container logs yet ({logf} does not exist)
fs.fs_path_must_not_absolute=FS path must not be absolute: {p}
fs.fs_path_must_not_contain=FS path must not contain ..: {p}
fs.fs_path_must_not_contain_empty_segments=FS path must not contain empty segments: {p}
fs.fs_path_contains_illegal_characters=FS path contains illegal characters: {p}
fs.fs_binds_entry_must_host_guest_path=FS_BINDS entry must be host:/guest/path:ro|rw (got: {spec})
fs.guest_path_must_not_contain=guest path must not contain ..
fs.refusing_host_bind_outside_workspace_only_paths=Refusing a host bind outside the workspace: {_fs_bind_host} (only paths inside CAPBOX_WORKSPACE are allowed)
fs.capbox_rootfs_ro_must_0_1=CAPBOX_ROOTFS_RO must be 0/1
fs.unable_create_overlay_directories=Unable to create overlay directories
fs.rootfs_ro_1_overlay_unavailable_root_will=ROOTFS_RO=1 but overlay is unavailable: the root will be mounted read-only, writes to / will fail (/tmp and /run remain tmpfs)
fs.invalid_fs_binds=Invalid FS_BINDS: {part}
fs.fs_binds_cannot_mount_onto_logs_audit=FS_BINDS cannot mount onto logs/ (the audit log must stay read-only): {_fs_bind_guest}
fs.unable_normalize_fs_binds_host_path=Unable to normalize FS_BINDS host path: {_fs_bind_host}
fs.invalid_snapshot_name=Invalid snapshot name
fs.snapshot_created_sha256=Snapshot created: {out} (sha256={sum})
fs.snapshot_does_not_exist=Snapshot does not exist: {name}
fs.snapshot_verification_failed=Snapshot verification failed: {arch}
fs.snapshot_contents_missing=Snapshot contents are missing {name}
fs.restore_failed_rollback_attempted=Restore failed, rollback was attempted
fs.restored_snapshot=Restored from snapshot: {name}
fs.deleted_snapshot=Deleted snapshot {name}
fs.snapshot_unknown_subcommand=snapshot: unknown subcommand {sub}
idmap.invalid_uid_gid_mapping_segment_expected_guest=Invalid UID/GID mapping segment: '{part}' (expected guest:host:count)
idmap.newuidmap_failed_pid_spec=newuidmap failed (pid={pid} spec={uid_spec})
idmap.unable_write_proc_setgroups_will_still_try=Unable to write /proc/{pid}/setgroups={sg} (will still try newgidmap)
idmap.newgidmap_failed_pid_spec=newgidmap failed (pid={pid} spec={gid_spec})
idmap.exec_uid_must_number_0_4294967295_got=EXEC_UID must be a number in 0..4294967295 (got: {uid})
idmap.exec_gid_must_number_0_4294967295_got=EXEC_GID must be a number in 0..4294967295 (got: {gid})
idmap.idmap_failed_get_child_pid_bwrap_info=idmap: failed to get child-pid from bwrap --info-fd
idmap.idmap_background_mapping_start_failed_see=idmap: background mapping start failed (see {logf})
idmap.idmap_after_map_hook_failed=idmap: after_map hook failed
image.extracting_zst_requires_zstd=Extracting zst requires zstd
image.refusing_write_image_contents_symlink=Refusing to write image contents into a symlink: {cur}/{part}
image.cache_target_not_directory=Cache target is not a directory: {cur}/{part}
image.cache_tree_contains_symlink_refusing_write_rootfs=Cache tree contains a symlink, refusing to write into rootfs
image.invalid_image_name=Invalid image name
image.exported=Exported: {out}
image.sha256=SHA256: {sum}
image.image_does_not_exist=Image does not exist: {name}
image.missing_sha256=Missing {arch}.sha256
image.sha256_mismatch_expect_got=SHA256 mismatch: expect={expect} got={got}
image.image_import_unknown_option=image import: unknown option {arg}
image.import_target_path_symlink=Import target path is a symlink
image.unable_create_extract_directory=Unable to create extract directory
image.extract_directory_not_real_directory=Extract directory is not a real directory
image.failed_extract_import_archive=Failed to extract the import archive
image.import_archive_has_no_root_directory=Import archive has no root directory
image.import_root_directory_escaped_extract_directory=Import root directory escaped the extract directory
image.import_target_already_exists=Import target already exists
image.unable_place_import_directory=Unable to place the import directory
image.import_result_not_real_directory=Import result is not a real directory
image.imported_sidecar_path_current_rootfs_not_replaced=Imported to a sidecar path: {target} (current rootfs was not replaced)
image.current_rootfs_not_real_directory_refusing_force=Current rootfs is not a real directory, refusing --force
image.backup_path_already_exists=Backup path already exists: {bak}
image.unable_move_current_rootfs_aside=Unable to move the current rootfs aside
image.replaced_current_rootfs_force_old_tree=Replaced the current rootfs with --force; old tree is at {bak}
image.replace_failed=Replace failed
image.replace_current_rootfs_capbox_image_import_force=To replace the current rootfs: capbox image import {name} --force
image.image_lock_too_many_arguments=image lock: too many arguments
image.image_lock_save_show_verify_restore=image lock: save|show|verify|restore
image.offline_cache=Offline cache: {out} ({sum})
image.usage_image_cache_restore_archive=Usage: image cache restore ARCHIVE
image.cache_verification_failed=Cache verification failed
image.unable_create_cache_staging_directory=Unable to create cache staging directory
image.failed_extract_cache_archive=Failed to extract the cache archive
image.cache_archive_does_not_contain=Cache archive does not contain {rel}
image.refusing_write_cache_rootfs=Refusing to write cache into rootfs
image.restored_offline_package_cache_rootfs=Restored the offline package cache into rootfs
image.image_cache_save_restore_path=image cache: save|restore|path
image.image_unknown_subcommand=image: unknown subcommand {sub}
landlock.capbox_landlock_must_off_got=CAPBOX_LANDLOCK must be on or off (got: {v})
landlock.missing_lib_guest_capbox_landlock_c=Missing lib/guest/capbox-landlock.c
landlock.landlock_helper_symlink=Landlock helper is a symlink: {bin}
landlock.capbox_landlock_requires_host_gcc_static_build=CAPBOX_LANDLOCK requires host gcc -static to build the helper
landlock.unable_create_temporary_file_landlock_build=Unable to create a temporary file for the Landlock build
landlock.failed_build_capbox_landlock_gcc_static_required=Failed to build capbox-landlock (gcc -static required): {err}
landlock.unable_install_capbox_landlock=Unable to install capbox-landlock: {bin}
landlock.capbox_landlock_not_executable=capbox-landlock is not executable: {bin}
landlock.unable_create_landlock_rules_file=Unable to create the Landlock rules file
landlock.failed_write_landlock_rules=Failed to write Landlock rules
landlock.landlock_enabled_launch_command_has_no_bwrap=Landlock is enabled, but the launch command has no bwrap
landlock.landlock_enabled_bwrap_arguments_missing_command_separator=Landlock is enabled, but the bwrap arguments are missing the command separator --
landlock.landlock_enabled_there_no_guest_command=Landlock is enabled, but there is no in-guest command
launch.capbox_net_invalid_net_sh_not_loaded=CAPBOX_NET is invalid ({net}) and net.sh is not loaded; refusing to treat it as open
launch.exec_uid_exec_gid_must_numbers_0=EXEC_UID/EXEC_GID must be numbers in 0..4294967295 (got uid={_eu} gid={_eg})
net.capbox_net_restricted_requires_non_empty_capbox=CAPBOX_NET=restricted requires a non-empty CAPBOX_NET_ALLOW (comma-separated domains or IPs)
net.capbox_net_allow_contains_illegal_characters=CAPBOX_NET_ALLOW contains illegal characters: {part}
net.capbox_net_allow_empty_after_parsing=CAPBOX_NET_ALLOW is empty after parsing
net.capbox_net_restricted_missing_prerequisites=CAPBOX_NET=restricted is missing prerequisites: {miss}
net.restricted_proxy_process_exited_see=restricted proxy process exited, see {path}
net.restricted_proxy_start_timed_out=restricted proxy start timed out
net.unable_enter_container_netns_child=Unable to enter the container netns (child={child})
net.proxy_sock_does_not_exist=Proxy sock does not exist: {sock}
net.restricted_bridge_process_exited_see=restricted bridge process exited, see {path}
net.restricted_bridge_start_timed_out=restricted bridge start timed out
net.restricted_argv_has_no_bwrap_cannot_inject=restricted: argv has no bwrap, cannot inject --info-fd
net.net_run_bwrap_oneshot_missing_command=_net_run_bwrap_oneshot: missing command
net.unable_build_bwrap_arguments=Unable to build bwrap arguments
net.restricted_failed_get_child_pid_bwrap_info=restricted: failed to get child-pid from bwrap --info-fd
net.invalid_publish_entry_expected_host_guest_host=Invalid PUBLISH entry (expected HOST:GUEST or HOST:IP:GUEST): {item}
net.publish_net_open_shares_host_network_so=PUBLISH={raw}: NET=open shares the host network, so guest ports are already visible on the host (no extra forwarding; this does not claim outbound filtering)
net.publish_under_none_restricted_requires_python3=PUBLISH under none/restricted requires python3
net.publish_under_none_restricted_requires_nsenter=PUBLISH under none/restricted requires nsenter
net.publish_forwarder_not_ready_yet_may_still=PUBLISH forwarder is not ready yet (it may still be waiting for the service netns); see {pd}/forward.log
net.publish_127_0_0_1_guest=PUBLISH 127.0.0.1:{_pub_host_port} → guest {_pub_guest_addr}:{_pub_guest_port}
pkglock.package_lock_not_saved=Package lock was not saved
recipe.recipe_unknown_key=recipe unknown key: {key}
recipe.recipe_rejected_double_quoted_value_containing_expansion=recipe rejected a double-quoted value containing expansion characters: {key}
recipe.recipe_rejected_unsafe_bare_value=recipe rejected an unsafe bare value: {key}
recipe.recipe_file_does_not_exist=recipe file does not exist: {hint}
recipe.recipe_line_invalid_only_key_value_known=recipe line {number} is invalid (only KEY=value of known keys is accepted)
recipe.recipe_duplicate_key_line=recipe duplicate key: {_recipe_key} (line {number})
recipe.recipe_init_must_boolean=recipe INIT must be a boolean
recipe.usage_capbox_recipe_check_apply_show_file=Usage: capbox recipe <check|apply|show> [FILE]
recipe.recipe_not_found_tried_capbox_recipe_capbox=recipe not found (tried capbox.recipe or .capbox/recipe.env)
recipe.locked_requires_lock_file=--locked requires a lock file
recipe.recipe_unknown_option=recipe unknown option: {arg}
recipe.recipe_accepts_only_one_file=recipe accepts only one file
recipe.applying_recipe=Applying recipe: {f}
recipe.recipe_rootfs_not_ready_running_init=recipe: rootfs is not ready, running init
recipe.cmd_init_unavailable=cmd_init is unavailable
recipe.recipe_rootfs_already_ready_skipping_download=recipe: rootfs is already ready, skipping download
recipe.recipe_installing_packages=recipe: installing packages: {pkgs}
recipe.cmd_pkg_unavailable=cmd_pkg is unavailable
recipe.recipe_applied=Recipe applied
res.capbox_cgroup_root_unavailable=CAPBOX_CGROUP_ROOT={path} is unavailable: {find_out}
res.memory_max_could_not_written_cgroup_memory=MEMORY_MAX={value} could not be written to cgroup memory.max (not applied; the leaf has no controller or is not writable)
res.unable_parse_memory_max=Unable to parse MEMORY_MAX: {value}
res.pids_max_could_not_written_cgroup_pids=PIDS_MAX={value} could not be written to cgroup pids.max (not applied; will not fake it with RLIMIT_NPROC)
res.pids_max_must_positive_integer_got=PIDS_MAX must be a positive integer (got: {value})
res.cpu_max_could_not_written_cgroup_cpu=CPU_MAX={value} could not be written to cgroup cpu.max (not applied)
res.unable_parse_cpu_max_supports_50_quota=Unable to parse CPU_MAX: {value} (supports 50% or 'quota period')
res.disk_max_cleanup_failed_leaving_will_not=DISK_MAX cleanup failed, leaving {base} (will not unprivileged-rm a directory that is still mounted)
res.unable_parse_disk_max=Unable to parse DISK_MAX: {value}
res.capbox_resources_mode_require_following_limits_cannot=CAPBOX_RESOURCES_MODE=require: the following limits cannot be honored exactly: {missing}
res.cpu_max_not_applied=CPU_MAX={value} was not applied: {detail}
res.pids_max_not_applied_cgroup_pids_required=PIDS_MAX={value} was not applied: cgroup pids is required (refusing to use RLIMIT_NPROC)
res.capbox_cgroup_root_cannot_honor_cgroup_limits=CAPBOX_CGROUP_ROOT={path} cannot honor cgroup limits: {detail}
res.memory_max_require_mode_refuses_prlimit_fallback=MEMORY_MAX={value}: require mode refuses a prlimit fallback (this is not cgroup memory.max)
res.memory_max_fell_back_prlimit_rlimit_virtual=MEMORY_MAX={value} fell back to prlimit RLIMIT_AS={bytes} (a virtual address space approximation, **not** cgroup memory.max)
res.memory_max_not_applied_no_cgroup_no=MEMORY_MAX={value} was not applied: no cgroup, and no prlimit / unable to parse
res.disk_max_not_applied=DISK_MAX={value} was not applied: {detail}
rootfs.unsupported_cpu_architecture_x86_64_aarch64_required=Unsupported CPU architecture: {arch} (x86_64 or aarch64 required)
rootfs.missing_rootfs_checksum_file=Missing rootfs checksum file: {file}
rootfs.rootfs_sha256_txt_has_no=rootfs-sha256.txt has no {key}
rootfs.verifying_rootfs_requires_sha256sum=Verifying rootfs requires sha256sum
rootfs.unsupported_distro_supported=Unsupported distro: {distro} (supported: {distros})
rootfs.unable_create_cache_directory=Unable to create cache directory: {cache_dir}
rootfs.using_cached_image=Using cached image: {dst}
rootfs.cached_image_failed_sha256_re_downloading=Cached image failed SHA256, re-downloading: {dst}
rootfs.forcing_re_download_removing_old_cache=Forcing re-download, removing old cache: {dst}
rootfs.downloading_rootfs_source=Downloading {distro} rootfs (source {n}/{total}): {u}
rootfs.download_complete_sha256_checked=Download complete: {dst} ({size}, SHA256 checked)
rootfs.downloaded_file_failed_gzip_sha256_checks_trying=Downloaded file failed gzip/SHA256 checks, trying the next source
rootfs.download_failed=Download failed: {u}
rootfs.all_image_mirrors_failed_you_can_download=All image mirrors failed; you can download manually into {dst}, or use --from <local path|URL>
rootfs.tarball_does_not_exist=tarball does not exist: {tarball}
rootfs.unable_create_directory=Unable to create directory: {parent}
rootfs.unable_create_staging_directory=Unable to create staging directory: {stage}
rootfs.extracting_rootfs=Extracting rootfs to {dest}
rootfs.extract_failed=Extract failed: {tarball}
rootfs.extract_result_has_no_bin_sh_image=Extract result has no /bin/sh; the image may be incomplete: {tarball}
rootfs.unable_replace_existing_rootfs=Unable to replace the existing rootfs: {dest}
rootfs.unable_put_rootfs_place=Unable to put rootfs in place: {dest}
rootfs.rootfs_ready=rootfs is ready: {dest}
rootfs.refusing_rootfs_path=Refusing '.' or '..' in a rootfs path: {parent}
rootfs.refusing_follow_symlink=Refusing to follow a symlink: {cur}
rootfs.path_component_not_directory=Path component is not a directory: {cur}
rootfs.refusing_relative_rootfs_path=Refusing a relative rootfs path: {dest}
rootfs.refusing_write_file_onto_directory=Refusing to write a file onto a directory: {dest}
rootfs.refusing_follow_symlink_when_writing=Refusing to follow a symlink when writing: {dest}
rootfs.capbox_mirror_none_skipping_mirror_injection=CAPBOX_MIRROR=none, skipping mirror injection
rootfs.rootfs_does_not_exist_skipping_mirror_injection=rootfs does not exist, skipping mirror injection: {rootfs}
rootfs.mirror_url_empty_skipping_injection_check_capbox=Mirror URL is empty, skipping injection (check CAPBOX_MIRROR_{distro_uc})
rootfs.wrote_apk_repositories_v3_24=Wrote apk repositories: {url}/v3.24/{main,community}
rootfs.wrote_apt_sources_suite=Wrote apt sources: {url} (suite={suite})
rootfs.unknown_distro_skipping_mirror_injection=Unknown distro, skipping mirror injection: {distro}
rootfs.rootfs_not_executable_skipping_first_boot=rootfs is not executable, skipping first boot
rootfs.running_first_boot_bootstrap=Running first boot (bootstrap)
rootfs.bootstrap_returned_not_fatal_rootfs_still_usable=bootstrap returned {rc} (not fatal, rootfs is still usable)
rootfs.first_boot_complete=First boot complete
rootfs.init_unknown_option=init: unknown option {arg}
rootfs.agent_trusted_cannot_together=--agent and --trusted cannot be used together
rootfs.unsupported_distro_supported_alpine_ubuntu=Unsupported distro: {distro} (supported: alpine / ubuntu)
rootfs.bootstrap_unknown_option=bootstrap: unknown option {arg}
rootfs.scaffold_implementation_unavailable=scaffold implementation is unavailable
rootfs.next_capbox_init_distro=Next: capbox init --distro {distro}
rootfs.agent_preset_security_profile_untrusted_net_none=agent preset: SECURITY_PROFILE=untrusted NET=none IDMAP=off RESOURCES_MODE=require
rootfs.resource_limits_must_set_separately_via_memory=Resource limits must be set separately via MEMORY_MAX/CPU_MAX/PIDS_MAX; start is refused when a configured limit cannot be honored
rootfs.untrusted_hides_ssh_gnupg_aws_azure_kube=untrusted hides .ssh .gnupg .aws .azure .kube .docker inside the workspace
rootfs.pkg_install_pkg_update_will_network_other=pkg install and pkg update will use the network. Other commands have no network by default
rootfs.one_shot_network_grant_capbox_exec_net=For a one-shot network grant: capbox exec --net restricted -- CMD (set CAPBOX_NET_ALLOW first) or --net open
rootfs.allowlist_example_com_allows_only_ports_80=allowlist: example.com allows only ports 80/443 on that host; write *.example.com for subdomains; add :* for any port (e.g. github.com:22)
rootfs.explicit_rootfs_matches_official_sha256=Explicit rootfs matches the official SHA256
rootfs.explicit_tarball_does_not_match_official_sha256=Explicit --from tarball does not match the official SHA256; accepting the source you specified (the official download path never does this)
rootfs.initializing_capbox_distro=Initializing CapBox distro: {distro}
rootfs.rootfs_already_exists_skipping_download_extract=rootfs already exists, skipping download and extract: {rootfs}
rootfs.downloading_specified_url=Downloading from the specified URL: {from}
rootfs.download_failed_2=Download failed: {from}
rootfs.downloaded_file_not_valid_gzip_tarball=Downloaded file is not a valid gzip tarball: {from}
rootfs.local_tarball_does_not_exist=Local tarball does not exist: {from}
rootfs.not_valid_gzip_tarball=Not a valid gzip tarball: {from}
rootfs.unable_obtain_rootfs_image=Unable to obtain a rootfs image
rootfs.unable_remove_old_rootfs=Unable to remove the old rootfs
rootfs.rootfs_incomplete_missing_executable_bin_sh=rootfs is incomplete (missing an executable /bin/sh): {rootfs}
rootfs.mirror_injection_failed_you_can_rerun_capbox=Mirror injection failed (you can rerun capbox init later)
rootfs.proxy_file_injection_failed_did_not_follow=Proxy file injection failed (did not follow a symlink when writing)
rootfs.unable_write_capbox_release=Unable to write capbox-release
rootfs.drop_priv_helper_not_ready_exec_uid=drop-priv helper is not ready ({detail}); exec --uid may fail
rootfs.done=Done: {rootfs} ({size})
rootfs.next_capbox_exec_id_u_should_print=Next: capbox exec -- id -u     # should print 0 inside the container
sandbox.sandbox_bwrap_cmd_unknown_mode_expected_oneshot=sandbox_bwrap_cmd: unknown mode {mode} (expected oneshot or daemon)
sandbox.rootfs_missing_unusable_run_capbox_init_first=rootfs is missing or unusable: {rootfs}; run capbox init first
sandbox.unable_build_bwrap_arguments_rootfs_missing=Unable to build bwrap arguments (rootfs is missing)
sandbox.exec_net_requires_mode_none_restricted_open=exec: --net requires a mode none|restricted|open
sandbox.exec_unknown_option_separate_guest_command=exec: unknown option {arg} (use -- to separate the in-guest command)
sandbox.exec_missing_command_run_e_g_capbox=exec: missing command to run, e.g.: capbox exec -- id -u
sandbox.exec_timeout_must_non_negative_integer_number=exec: --timeout must be a non-negative integer number of seconds (got: {timeout_s})
sandbox.exec_daemon_uses_network_chosen_capbox_up=exec: --daemon uses the network chosen at capbox up; to change it, run up --net again
sandbox.exec_profile_must_compat_untrusted_strict_got=exec: --profile must be compat|untrusted|strict (got: {profile_override})
sandbox.exec_unable_resolve_user_check_rootfs_etc=exec: unable to resolve --user {user_override} (check rootfs /etc/passwd)
sandbox.exec_uid_must_non_negative_integer_got=exec: --uid must be a non-negative integer (got: {uid_override})
sandbox.exec_gid_must_non_negative_integer_got=exec: --gid must be a non-negative integer (got: {gid_override})
sandbox.exec_guest_directory_does_not_exist=exec: in-guest directory does not exist: {want_cwd}
sandbox.exec_guest_directory_does_not_exist_workspace=exec: in-guest directory does not exist: /workspace/{want_cwd}
sandbox.guest_command_timed_out_s_terminated=In-guest command timed out ({timeout_s}s) and was terminated
sandbox.persistent_container_feature_unavailable_missing_library_dae=Persistent-container feature is unavailable: missing library {lib_dir}/daemon.sh
sandbox.shell_net_requires_mode_none_restricted_open=shell: --net requires a mode none|restricted|open
sandbox.shell_unknown_option=shell: unknown option {arg}
sandbox.shell_daemon_uses_network_chosen_capbox_up=shell: --daemon uses the network chosen at capbox up; to change it, run up --net again
sandbox.cp_empty_path=cp: empty path: '{spec}'
sandbox.cp_unknown_option=cp: unknown option {arg}
sandbox.usage_capbox_cp_src_dst=Usage: capbox cp SRC DST
sandbox.refused_container_side_source_path_escapes_rootfs=Refused: container-side source path escapes rootfs: {src_path}
sandbox.refused_container_side_destination_path_escapes_rootfs=Refused: container-side destination path escapes rootfs: {dst_path}
sandbox.source_file_does_not_exist_container=Source file does not exist in the container: {src_path}
sandbox.source_file_does_not_exist=Source file does not exist: {src_abs}
sandbox.copy_failed=Copy failed: {err}
sandbox.ls_unknown_option=ls: unknown option {arg}
sandbox.guest_directory_does_not_exist=In-guest directory does not exist: {path}
sandbox.usage_capbox_ps=Usage: capbox ps
sandbox.ps_unavailable_falling_back_reading_proc=ps is unavailable, falling back to reading /proc
sandbox.suspicious_package_name_rejected=Suspicious package name, rejected: {p}
sandbox.pkg_install_missing_package_name=pkg install: missing package name
sandbox.invalid_package_name=Invalid package name
sandbox.pkg_remove_missing_package_name=pkg remove: missing package name
sandbox.pkg_list_invalid_filter_pattern=pkg list: invalid filter pattern: {pat}
sandbox.pkg_unknown_subcommand_install_remove_update_list=pkg: unknown subcommand {sub} (install|remove|update|list)
sandbox.pkg_returned_dpkg_audit_logs_above_judge=pkg {sub} returned {rc} (use the dpkg audit / logs above to judge)
sandbox.pkg_returned_chown_warnings_common_under_single=pkg {sub} returned {rc} (chown warnings are common under a single UID; check dpkg audit and the executables)
sandbox.pkg_session_network_none_command_using_one=pkg {sub}: session network is none, this command is using a one-shot network grant
sandbox.dpkg_has_packages_not_fully_configured_state=dpkg has packages that are not fully configured (state contains U/F, e.g. iU/iF):
sandbox.not_hidden_success_check_capbox_idmap_postinst=This is not a hidden success: check CAPBOX_IDMAP and postinst logs
sandbox.dpkg_audit_reported_unconfigured_packages=dpkg --audit reported unconfigured packages
sandbox.dpkg_audit_no_leftover_iu=dpkg audit: no leftover iU/iF
sandbox.ls_rootfs_no_arguments_expected=ls-rootfs: no arguments expected
sec.capbox_security_profile_must_compat_untrusted_strict=CAPBOX_SECURITY_PROFILE must be compat|untrusted|strict (got: {value})
sec.security_profile_requires_python3_libseccomp_generate_seccom=Security profile {profile} requires python3 + libseccomp to generate a seccomp BPF
sec.missing_lib_seccomp_gen_py=Missing lib/seccomp-gen.py
sec.seccomp_bpf_generation_failed_see_err_refusing=seccomp BPF generation failed (see {out}.err); refusing a fake implementation
sec.seccomp_bpf_empty_refusing_continue=seccomp BPF is empty, refusing to continue
sec.unable_open_seccomp_bpf=Unable to open seccomp BPF: {bpf}
svc.invalid_service_name=Invalid service name: {arg}
svc.invalid_service_name_2=Invalid service name: {name}
svc.service_definition_does_not_exist=Service definition does not exist: {f}
svc.service_value_contains_illegal_expansion_characters=Service {name}: value of {key} contains illegal expansion characters
svc.service_value_contains_newline=Service {name}: value of {key} contains a newline
svc.service_missing_cmd=Service {name}: missing CMD
svc.service_diagnostics=Service '{name}' diagnostics: {reason}

svc.user_does_not_exist_in_guest_passwd=USER does not exist in {passwd}
svc.require_idmap_but_multi_uid_mapping_unavailable=REQUIRE_IDMAP=1 but multi-UID mapping is unavailable
svc.require_idmap_but_current_status=REQUIRE_IDMAP=1 but current status is {status}
svc.restricted_prerequisites_not_met=restricted prerequisites are not met
svc.failed_start_restricted_proxy=failed to start the restricted proxy
svc.guest_cannot_see_bridge_ready_path=guest cannot see the bridge ready path
svc.unable_create_run_dir=cannot create {rd}
svc.service_run_directory_is_symlink=service run directory is a symlink
svc.unable_build_bwrap_args_rc_often_old_bwrap=cannot build bwrap arguments (rc={rc}; often caused by an old bwrap)
svc.unable_build_bwrap_args=cannot build bwrap arguments
svc.security_profile_could_not_be_applied=security profile could not be applied
svc.resource_limits_could_not_be_applied=resource limits could not be applied
svc.landlock_could_not_be_enabled=Landlock could not be enabled
svc.capbox_idmap_on_but_multi_uid_mapping_unavailable=CAPBOX_IDMAP=on but multi-UID mapping is unavailable
svc.unable_inject_info_fd=cannot inject --info-fd
svc.idmap_start_failed=idmap start failed
svc.restricted_service_network_bridge_not_ready=restricted service network bridge is not ready
svc.service_not_ready_or_start_failed_see_logs=service is not ready or failed to start (see service logs)
svc.idmap=  idmap: {status} — {detail}
svc.listening_ports_ss_lntu_head=  Listening ports (ss -lntu | head):
svc.msg=    {L}
svc.rootfs_present=  rootfs{d}: present
svc.rootfs_missing=  rootfs{d}: missing
svc.recent_logs=  Recent logs:
svc.service_unknown_subcommand_start_stop_status_logs=service: unknown subcommand {sub} (start|stop|status|logs|list)
svc.depends_has_invalid_service_name=DEPENDS_ON has an invalid service name: {d}
svc.dependency_not_running_starting_first=Dependency {d} is not running, starting it first
svc.failed_start_dependency_service=Failed to start dependency service {d}
svc.service_not_decimal_number=Service {who}: {label} is not a decimal number: {v}
svc.service_outside_32_bit_range=Service {who}: {label} is outside the 32-bit range: {v}
svc.usage_capbox_service_start_name=Usage: capbox service start NAME
svc.service_start_unknown_option=service start: unknown option {arg}
svc.service_already_running_pid=Service {name} is already running (pid {pid})
svc.invalid_stop_timeout=Invalid STOP_TIMEOUT
svc.invalid_restart_max=Invalid RESTART_MAX
svc.invalid_ready_timeout=Invalid READY_TIMEOUT
svc.restart_must_no_failure_always=RESTART must be no|on-failure|always
svc.service_unable_resolve_user_guest_passwd=Service {name}: unable to resolve USER={user} in the guest passwd
svc.service_invalid_net=Service {name}: invalid NET: {net}
svc.publish_failed_start_see_logs=PUBLISH failed to start (see logs)
svc.service_started_supervisor_pid_uid_gid=Service {name} started (supervisor pid {pid}, uid={uid} gid={gid})
svc.usage_capbox_service_stop_name=Usage: capbox service stop NAME
svc.service_not_running=Service {name} is not running
svc.service_stopped=Service {name} stopped
svc.usage_capbox_service_status_name=Usage: capbox service status NAME
svc.service_logs_unknown_option=service logs: unknown option {arg}
svc.extra_argument=Extra argument {arg}
svc.usage_capbox_service_logs_name=Usage: capbox service logs NAME
svc.no_log=No log: {f}
upgrade.run_capbox_down_before_upgrading=Run capbox down before upgrading
upgrade.cancel_wait_all_tasks_before_upgrading=Cancel or wait for all tasks before upgrading
upgrade.run_capbox_service_stop_before_upgrading=Run capbox service stop {name} before upgrading
upgrade.found_leftover_state_older_version_stop_services=Found leftover state from an older version; stop services with the old CLI and confirm no old processes are still running
upgrade.requires_template_directory=--from requires a template directory
upgrade.upgrade_unknown_argument=upgrade unknown argument: {arg}
upgrade.rollback_does_not_accept=rollback does not accept --from
upgrade.upgrade_requires_template=upgrade requires --from TEMPLATE
common.bwrap_old_details<<
      Affected: CVE-2026-87766 (/oldroot symlink escape), CVE-2026-41163 (setuid ptrace)
      These vulnerabilities trigger before the sandbox process starts; --clearenv / fsguard / seccomp cannot defend against them
      This check applies equally to compat, untrusted, and strict
      Upgrade: sudo apt install --only-upgrade bubblewrap
            If the distro does not ship 0.12.0, install from source or a newer repository
      If you accept the risk, allow once: capbox --allow-old-bwrap <command>
      Allow persistently: capbox config set --yes CAPBOX_ALLOW_OLD_BWRAP 1
            (an audit record is written; doctor still reports FAIL)
>>

# doctor report text (_doctor_pass / _doctor_fail / _doctor_warn and *_doctor_report)
doctor.bwrap_installed=bwrap is installed ({bwrap})
doctor.bwrap_version_ok=bwrap version {ver} (>= 0.12.0)
doctor.bwrap_below_baseline=bwrap {ver} is below the 0.12.0 security baseline
doctor.bwrap_below_allowed_once=bwrap {ver} is below the baseline; allowed for this run by --allow-old-bwrap (doctor still reports FAIL)
doctor.bwrap_below_allowed_persist=bwrap {ver} is below the baseline; allowed by CAPBOX_ALLOW_OLD_BWRAP (doctor still reports FAIL)
doctor.bwrap_unavailable=bwrap is unavailable ({bwrap}); install bubblewrap >= 0.12.0 or set CAPBOX_BWRAP
doctor.workspace_dangerous=Workspace is {home} or / ({workspace}); the entire tree would be RW-bound into the container. Use a project-local .capbox/ or CAPBOX_ROOT=/path/to/project
doctor.workspace_safe=Workspace is safe ({workspace})
doctor.audit_workspace_unsafe=workspace is unsafe
doctor.userns_ok=full userns privileges (uid=0, CapEff={caphex})
doctor.userns_probe_failed=full userns privilege probe failed: the container could not get uid 0 and full capabilities (check kernel unprivileged_userns_clone and the bwrap version)
doctor.userns_not_probed=full userns privileges were not probed (bwrap is unavailable)
doctor.idmap_module_missing=UID mapping module is not loaded (lib/idmap.sh)
doctor.deps_complete=required commands are present (tar/curl/flock/timeout)
doctor.deps_missing_timeout=timeout is missing (exec --timeout will not work); other dependencies are present
doctor.deps_missing=missing required commands: {cmds}
doctor.rootfs_ready=rootfs is ready ({rootfs}, {size})
doctor.rootfs_missing=rootfs is missing or unavailable ({rootfs}); run: capbox init --distro {distro}
doctor.resolv_ready=resolv.conf is ready ({path})
doctor.resolv_missing=resolv.conf has not been generated yet (it is created on the first exec)
doctor.mirror_skipped_none=CAPBOX_MIRROR=none, skipping mirror connectivity check
doctor.mirror_url_empty=mirror URL is empty (check CAPBOX_MIRROR_{distro})
doctor.mirror_reachable=mirror is reachable ({url})
doctor.mirror_unreachable=mirror is unreachable ({url}); check the network or CAPBOX_MIRROR
doctor.host_net_ok=host network is available
doctor.host_net_probe_failed=probe from the host to a public mirror failed (the environment may be offline)
doctor.net_none=CAPBOX_NET=none, no network in the container (--unshare-net)
doctor.net_restricted_mirror=CAPBOX_NET=restricted: mirror connectivity depends on the allowlist proxy (see the network mode item below)
doctor.missing_curl_skip_net=curl is missing, skipping network connectivity checks
doctor.socks5_apt_unsupported=apt does not natively support a socks5 proxy; use an http proxy, or configure proxychains in the container
doctor.proxy_configured=proxy is configured ({proxy})
doctor.proxy_unset=proxy is not configured (direct connection)
doctor.apk_repos_injected=apk mirror repositories have been injected
doctor.apk_repos_missing={path} is missing (re-run capbox init)
doctor.apt_repos_injected=apt mirror sources have been injected ({which})
doctor.apt_repos_missing=apt source files are missing ({sl} or {d822}); re-run capbox init
doctor.env_cleared=environment is cleared (host secrets are not inherited; the HOME/PATH whitelist is available)
doctor.env_not_cleared=environment was not cleared or the whitelist is missing (probe rc={rc} out={out}); bwrap --clearenv must always run before --setenv
doctor.skip_env_old_bwrap=skipping environment-clear probe (bwrap is below the security baseline)
doctor.skip_env_no_bwrap=skipping environment-clear probe (bwrap is unavailable)
doctor.skip_env_no_rootfs=skipping environment-clear probe (rootfs or bwrap is unavailable)
doctor.config_preoccupy_no_log=could not locate the guest-side logs/audit.jsonl, so read-only protection cannot be confirmed
doctor.guest_wrote_config=guest wrote the host config.env (missing or existing paths were not protected read-only)
doctor.guest_wrote_services=guest created host services/_doctor_probe.env (the services directory was not protected read-only)
doctor.guest_wrote_protected=guest could write a protected config path (probe out={out})
doctor.guest_wrote_audit_log=guest wrote the host logs/audit.jsonl (logs were not protected read-only)
doctor.config_preoccupy_ok=config path pre-occupation is in effect (missing or existing config.env, services/, and logs/audit.jsonl cannot be written by the guest)
doctor.skip_preoccupy_capbox_dir=skipping config pre-occupation probe (CAPBOX_DIR is not in the workspace view)
doctor.skip_preoccupy_old_bwrap=skipping config pre-occupation probe (bwrap is below the security baseline)
doctor.skip_preoccupy_no_bwrap=skipping config pre-occupation probe (bwrap is unavailable)
doctor.skip_preoccupy_no_rootfs=skipping config pre-occupation probe (rootfs or bwrap is unavailable)
doctor.daemon_running=daemon container is running (pid {pid})
doctor.daemon_not_running=daemon container is not running (run capbox up as a background task when needed)
doctor.summary_baseline_fail=Doctor result: security baseline not met (exit 6); {fails} FAIL, {warns} WARN
doctor.summary_fail=Doctor result: {fails} FAIL, {warns} WARN
doctor.summary_pass_with_warns=Doctor result: all passed ({warns} WARN)
doctor.summary_pass=Doctor result: all passed
doctor.audit_baseline_fail=security baseline not met, {fails} FAIL
doctor.audit_fail={fails} FAIL, {warns} WARN
doctor.idmap_multi=UID mapping multi ({detail})
doctor.idmap_drop_helper_ok=drop-priv helper ({detail})
doctor.idmap_drop_helper_unavailable=drop-priv helper is unavailable ({detail}); --uid will fall back to guest setpriv/python/chpst/su
doctor.idmap_single=UID mapping single ({detail}). chown/setgroups/multi-user services will fail
doctor.idmap_blocked_on=UID mapping is blocked and CAPBOX_IDMAP=on ({detail})
doctor.idmap_fallback_single=UID mapping is unavailable, fell back to single ({detail})
doctor.idmap_status_unknown=UID mapping status is unknown
doctor.cgroup_v2_writable=cgroup v2 is writable ({detail})
doctor.cgroup_v2_no_delegate=cgroup v2 is present but cannot be delegated: {detail}
doctor.cgroup_unavailable=cgroup is unavailable: {detail}
doctor.disk_max_honored=DISK_MAX can be honored: {detail}
doctor.disk_max_not_honored=DISK_MAX cannot be honored: {detail}
doctor.resources_unset=resource limits are unset (MEMORY/CPU/PIDS/DISK are empty)
doctor.resources_mode=RESOURCES_MODE={mode}
doctor.memory_max_set=MEMORY_MAX={value} is set
doctor.cpu_max_set=CPU_MAX={value} is set
doctor.pids_max_set=PIDS_MAX={value} is set
doctor.disk_max_set=DISK_MAX={value} is set (guest {guest})
doctor.disk_guest_path_invalid=DISK_MAX guest path is invalid
doctor.image_dir_present=image directory {path} (about {n} archives)
doctor.image_dir_missing=image directory has not been created yet (it is created on image export)
doctor.package_lock_present=package.lock is present
doctor.net_invalid=CAPBOX_NET is invalid ({value}); refusing to treat it as open
doctor.net_mode_none=network mode none (--unshare-net, no network in the container)
doctor.net_mode_open=network mode open (shared host network; host is a compatibility alias)
doctor.net_mode_restricted_ok=network mode restricted (unshare-net + allowlist proxy; {pre}; ALLOW={allow})
doctor.net_mode_restricted_prereq=network mode restricted but prerequisites are not met (needs python3, nsenter, and a non-empty CAPBOX_NET_ALLOW); exec will fail
doctor.fs_rootfs_ro_overlay_ok=ROOTFS_RO=1 and overlay is available (writes go to upper)
doctor.fs_rootfs_ro_overlay_unavailable=ROOTFS_RO=1 but overlay is unavailable: the root will be mounted read-only
doctor.fs_rootfs_ro_off=ROOTFS_RO is not enabled (rootfs is RW-bound, the compatibility default)
doctor.fs_hide_binds_ok=FS_HIDE/FS_BINDS config validated (binds outside the workspace are refused)
doctor.fs_hide_binds_invalid=FS_HIDE/FS_BINDS config is invalid
doctor.landlock_invalid=CAPBOX_LANDLOCK must be on or off (current: {value})
doctor.landlock_off=Landlock is off (when unset, strict enables it by default; compat/untrusted leave it off)
doctor.landlock_helper_failed=Landlock is enabled, but the helper could not be built (needs host gcc -static and lib/guest/capbox-landlock.c)
doctor.landlock_kernel_unsupported=Landlock is enabled, but the kernel does not support it (needs 5.13+ with the LSM enabled)
doctor.landlock_abi=Landlock ABI {abi} (restricts VFS after mounts complete; does not restrict TCP ports; allowing a directory does not let you punch holes under it)
doctor.security_compat=security profile compat (compatibility default: full capabilities, no seccomp; does not weaken existing behavior)
doctor.security_userns_boundary_compat=userns boundary: guest root is not host root; without seccomp the attack surface is larger — for untrusted workloads set CAPBOX_SECURITY_PROFILE=untrusted|strict
doctor.security_profile_ok=security profile {profile} (seccomp BPF={bpf}, capability drop, disable-userns={dus})
doctor.security_idmap_skip_disable_userns=Do not combine an untrusted workload with multi-UID idmap: --disable-userns was skipped, so the guest can still nest a user namespace. Package installs may use idmap; for untrusted commands set CAPBOX_IDMAP=off (or a single UID) before using untrusted/strict
doctor.security_bpf_failed=security profile {profile}, but a seccomp BPF could not be generated (refusing a fake implementation)
doctor.security_need_seccomp_tools=security profile {profile} requires python3 + lib/seccomp-gen.py + libseccomp
doctor.security_userns_boundary_recorded=userns boundary recorded: harden reduces the guest attack surface and does not claim host-level isolation

# Shared CAPBOX_*_DETAIL / CAPBOX_BWRAP_VERSION_DETAIL / cgroup find-why text
common.bwrap_version_unparseable=unable to parse {bin} --version (need >= 0.12.0)
common.bwrap_version_detail_below=bwrap {ver} is below 0.12.0 (distro-reverted 0.11.x patches do not count; need >= 0.12.0)
idmap.detail_off=CAPBOX_IDMAP=off (force a single UID)
idmap.detail_missing_helpers=newuidmap/newgidmap are missing (install the uidmap package); the kernel only allows a single-UID self-mapping
idmap.detail_no_subuid=user {user} has no usable entry in /etc/subuid
idmap.detail_uid_map_unparseable=CAPBOX_UID_MAP could not be parsed: {spec}
idmap.detail_gid_map_unparseable=CAPBOX_GID_MAP could not be parsed: {spec}
idmap.detail_tmp_dir_failed=could not create the idmap probe temporary directory
idmap.detail_probe_file_failed=could not create the idmap probe file
idmap.detail_map_write_failed=newuidmap is present but writing the multi-line mapping failed: {detail}
idmap.drop_helper_missing_src=capbox-drop-priv.c is missing
idmap.drop_helper_no_gcc=gcc/cc is missing, cannot build the static helper
idmap.drop_helper_gcc_failed=gcc -static failed: {err}
idmap.drop_helper_ready=static helper is ready for a read-only bind ({bin})
idmap.drop_helper_missing_after_build=helper is still missing after the build
res.cgroup_dual_hint=Honoring limits requires both: (1) the process's own cgroup is writable (so the task can be moved into a child cgroup); (2) the limit root is empty and already delegated (mkdir, and writes to cgroup.subtree_control and memory.max, succeed). You can systemctl --user start capbox.slice, set CAPBOX_CGROUP_ROOT to that slice, and run inside a writable user scope.
res.detail_no_sys_fs_cgroup=/sys/fs/cgroup is missing
res.detail_not_cgroup_v2=not a cgroup v2 unified hierarchy (cgroup.controllers is missing)
res.detail_root_ok_self_not_writable=limit-root probe succeeded ({root}), but the process's own cgroup is not writable, so the task cannot be moved into a child cgroup. {hint}
res.detail_cgroup_root_writable=CAPBOX_CGROUP_ROOT={root} (live probe: subtree_control+memory.max are writable)
res.detail_writable_cgroup_root=writable cgroup root: {root} (live probe: subtree_control+memory.max are writable)
res.detail_cgroup_root_unwritable_fallback=not writable, or a child cgroup is missing a writable memory.max
res.detail_cgroup_root_unusable=CAPBOX_CGROUP_ROOT={root} is unusable: {reason}
res.detail_no_usable_cgroup_parent=no usable cgroup parent (self={self}); {reason}. controllers: {controllers}
res.detail_no_usable_cgroup_parent_no_delegate=no usable cgroup parent (self={self}); {reason}. controllers: {controllers}, but the current path has no effective delegation. {hint}
res.detail_mkdir_evidence=mkdir evidence: {err}
res.find_why_not_dir=not a directory
res.find_why_mkdir_failed=cannot mkdir a child directory: {err}
res.find_why_subtree_control=cannot write cgroup.subtree_control(+memory): {err} (the limit root must be empty and already delegated; EBUSY if the parent cgroup has processes). {hint}
res.find_why_no_memory_max=child cgroup has no memory.max (parent did not delegate memory). {hint}
res.find_why_memory_max_unwritable=cannot write child cgroup memory.max: {err}. {hint}
res.find_why_no_usable_parent=no usable cgroup parent
res.disk_detail_unset=CAPBOX_DISK_MAX is not set
res.disk_detail_guest_path_invalid=CAPBOX_DISK_GUEST_PATH is invalid (must be an absolute path, and must not contain .. or /.)
res.disk_detail_missing_tools=losetup/mkfs.ext4/mount are missing (need e2fsprogs + util-linux)
res.disk_detail_no_loop_control=/dev/loop-control is missing
res.disk_detail_priv_direct=priv=direct; loop→{guest} (needs mount permission, not rootless)
res.disk_detail_priv_sudo=priv=sudo -n; loop→{guest} (needs host authorization, not rootless)
res.disk_detail_no_priv=no loop/mount privilege: {lsout}; need root, the disk group, or sudo -n (refusing to pretend limits are in effect)
res.disk_detail_state_symlink=state/disk is a symlink, refusing to create the quota disk
res.disk_detail_quota_dir_not_real=quota directory is not a real directory
res.disk_detail_loop_setup_failed=failed to create the loop quota disk (priv={mode})
res.disk_detail_no_dashdash=argv has no --, cannot bind the quota disk into the guest
