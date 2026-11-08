# Local Agent workflows

`task` and `policy` require host Python 3.10+ and use the normal CapBox exec launcher. Guest commands receive the same namespace, environment-clearing, profile and configured resource checks as `exec`. A task has its own host supervisor; `capbox up` is not required.

## Start, reconnect and cancel

Use an initialized project. The response is JSON with schema `capbox.agent.v1`; save its `task_id`:

```sh
capbox task start --timeout 600 --net none -- sh -c 'echo started; sleep 2; echo done'
# Replace TASK_ID with the task_id from that response:
capbox task list --json
capbox task status TASK_ID
capbox task logs TASK_ID --stream stdout --offset 0 --limit 65536 --json
capbox task attach TASK_ID
capbox task wait TASK_ID --timeout 30
capbox task cancel TASK_ID
capbox task rm TASK_ID
```

`start` returns after the supervisor acknowledges submission; command setup can still fail. Inspect `wait`/`status` for the actual exit code. `wait` and `attach` return the task's exit code: execution timeout is 124, explicit cancellation is 143, and lost supervisor state is 125. A **client wait** timeout also returns 124 but does not cancel the task. `cancel` acknowledges a request; use `wait` to confirm completion. Running tasks cannot be removed or upgraded underneath.

The task execution deadline starts when the supervisor starts, including CLI startup. Preparing/copying an isolated workspace happens before that deadline. It cancels the CLI process group and escalates to SIGKILL after a grace period. The child CLI uses parent-death handling; a dead supervisor is reported as `lost`, never as success. A runtime directory or outer host session being removed can still end tasks. Detached operation does not escape an outer tool/container supervisor. It is not reboot survival or memory checkpointing.

Task metadata, original command arguments and logs are private host data outside the workspace, in the same validated runtime hierarchy as other control records. They may contain sensitive command output. Nothing is published automatically. The first version retains completed tasks until `task rm`; use external archival if results must survive host runtime cleanup. `lost` records require manual confirmation of the host session and are not automatically removed.

### Output contract

- Task `start`, `list`, `status`, `wait`, `cancel`, `rm` and policy commands emit JSON. `--json` is accepted explicitly where applicable.
- `logs --json` returns `stream`, `offset`, `next_offset`, `data_base64`. Offsets are **bytes** in that stream, not characters or a global event number. Human `logs` writes the raw selected stream.
- `attach --json` emits JSONL output events followed by an exit event. Resume with `--stdout-offset` and `--stderr-offset`. Human attach keeps stdout and stderr separate. stderr can include launcher diagnostics as well as guest stderr.
- By default, only the first **8MiB per stream** are retained. The supervisor continues draining excess bytes and reports `dropped_bytes` on completion. `--max-output-bytes` permits 0–64MiB per stream. A single `logs` call reads at most 1MiB. Offsets refer to retained data.
- Eight active tasks per project are allowed. restricted network tasks use independent proxy/bridge session names. Shared-project tasks still share a mutable rootfs and workspace; use isolation or serialize conflicting writes.

## Explain the requested launch policy

```sh
capbox policy show --json
capbox policy show --profile strict --net none
capbox policy check --net restricted https://example.com/
capbox policy check --net restricted --resolve https://example.com/
```

The policy is for a **new oneshot**, not an already-running daemon. Each value identifies its source (`default`, `file`, `env`, `command`, or a profile-derived default). It includes profile, network, identity, rootfs/overlay and requested resource budgets. It does not claim that a requested resource limit is applied: the normal launch checks still decide that. Task status retains its submission-time policy even if the project's config later changes.

Network checks reuse the proxy's actual host/port and private-IP rules. Only HTTP(S) targets without userinfo are accepted; URL paths, queries and credentials are not echoed. Without `--resolve`, an allowlist match is **conditional** because DNS has not been checked. `--resolve` explicitly queries DNS; no TCP connection is made. DNS and connectivity can change, and the proxy revalidates addresses at connection time. `open` reports shared host networking, not successful connectivity. A denied decision exits 1; invalid usage exits 2.

These are deterministic policy previews, not a complete syscall-denial tracer. They do not alter config or automatically learn allow rules. The `pkg install/update` network exception remains explicitly reported.

## Isolated workspace and reviewable diff

`--isolate` first copies Git-tracked **working-tree** files, including their uncommitted contents, into a private task workspace. It also makes an independent rootfs copy, without hardlinks. Stop other writers, services and daemon before copying a live rootfs; no online database consistency guarantee is made.

```sh
task_id=$(capbox task start --isolate --net none -- sh -c 'printf "task result\n" > task-result.txt' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["task_id"])')
capbox task wait "$task_id"
capbox task diff "$task_id" --json
patch_file=$(mktemp)
capbox task diff "$task_id" > "$patch_file"
printf 'Review patch: %s\n' "$patch_file"
# After reviewing/exporting the result:
capbox task rm "$task_id"
```

The MVP exports a Git binary-capable patch; it **does not apply it to the original project**. JSON includes `changed_files`, `origin_changed`, and `patch_base64`. Read the patch, check the source baseline and resolve conflicts before using your normal Git review/apply workflow. A deleted or modified source baseline, changed executable mode or an existing source file colliding with a task's new file is reported. The preview is not an atomic future-apply authorization.

Supported scope and limits:

- Run from a Git repository root. Only tracked regular working-tree files are copied; untracked files and Git history/config are omitted. Source paths are opened relative to pinned directory descriptors without following links.
- `.capbox`, `.git`, common credential paths (`.env`, `.env.*`, `.secrets`, `.ssh`, `.aws`, `.azure`, `.gnupg`, `.kube`, `.docker`), PEM/key files and `id_rsa*` are excluded. This cannot recognize every secret; review tracked files before submission. `.gitignore` is not a confidentiality rule.
- Symlinks, hardlinks, special files and submodule directories are not supported. File enumeration and diff reject such content instead of following links into the host. Host Git uses private metadata outside the guest and disables external diff/textconv and hooks.
- The working-file set is limited to 10,000 files / 100MiB; exported patch size to 16MiB. A nonempty existing overlay upper is refused rather than silently omitted. Rootfs copies consume additional disk and startup time. They are full copies, not instant snapshots, and existing disk quotas still cover only their configured guest data path.
- `diff` is available only after an isolated task finishes. `lost` tasks cannot be exported automatically. Changes to the private rootfs are disposable and are not part of the workspace patch.
- Existing exec/file/bind settings are still enforced. Absolute binds referring to the original workspace may be invalid in the private copy; they are not silently granted access to the source.

This first implementation deliberately keeps patch application and credential provisioning with the trusted host caller. No MCP/network control server is opened.
