# Upgrade and recovery

Requires host Python **3.10+**.

Use a trusted, complete template outside the project workspace. Update that template through your normal Git or verified-release process. Before applying or rolling back, use the old CLI to stop every service and the daemon, and finish all exec calls. CapBox checks known running services/daemon and conservatively refuses legacy service records; it cannot coordinate arbitrary concurrent uses of an older CLI.

```sh
capbox --root /path/to/project upgrade check --from /path/to/new-template --json
capbox --root /path/to/project upgrade apply --from /path/to/new-template
capbox --root /path/to/project upgrade rollback
```

Invoke the **new template's bin/capbox** when upgrading an old project. Upgrade dispatch deliberately uses that template's complete libraries, even when the target project's libraries are old or incomplete.

`check` compares runtime contents and executable bits, including obsolete files. It reports differences even if the version strings match and can run before stopping services. `apply` replaces the complete `bin` and `lib` trees, including local modifications; inspect the comparison first. The private backup retains the previous trees for rollback.

## Commit and recovery

1. Validate ordinary files and directories; reject symlinked runtime inputs and guest-visible upgrade sources.
2. Copy a complete bundle to staging on the project's filesystem. Verify content hashes, shell syntax, module completeness, version and help.
3. Copy and verify the old runtime in persistent private backup storage. Save a flushed transaction journal.
4. Mark the project as under maintenance, replace the runtime directories and verify the installed bundle.
5. On a replacement/check failure, restore the old trees. Successful recovery clears the maintenance marker.

Directory replacement uses a journal and compensating recovery; it is not one atomic filesystem operation spanning both trees. The marker blocks normal invocations of the new CLI while recovery is needed. If the process or machine is interrupted, use an intact external template to run `upgrade rollback`. Rootfs, config, service definitions and business data are never moved as part of this operation.

## Backup location

Backups are under `$XDG_STATE_HOME/capbox/<project-hash>/upgrades/`, or `~/.local/state/capbox/<project-hash>/upgrades/` when XDG_STATE_HOME is unset. Directories must belong to the user, use `0700` for private backup roots, and stay outside the workspace. These backups survive runtime-directory cleanup and normal reboots. `check --json` reports the location.

The current implementation retains the latest rollback record and previous backup directories. Before moving a project or removing host state, preserve any backups you still need; the project hash follows its canonical installation path. Rollback checks backup hashes before replacing files.

Existing rootfs versions are independent from the CLI. For an old Alpine release, retain backups and initialize a new workspace, reinstall supported packages and migrate necessary business data. A CLI upgrade does not patch existing guest packages or perform database-version migrations.
