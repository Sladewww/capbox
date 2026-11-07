# Validation scope

CI checks behavior at distinct layers. A passing fallback test is not evidence that its unavailable capability succeeded.

| Job | Scope | Required behavior |
|---|---|---|
| bash -n + selftest | Syntax, harness fault detection, config transactions, upgrade recovery, strict locks, host boundaries and generated docs | No failing checks |
| acceptance (bubblewrap) | T01–T41 selections plus real hardened service/daemon/network integration on Alpine | Real sandbox execution; no swallowed doctor failure |
| Compatibility matrix | Alpine and Ubuntu guests on x86_64 and aarch64 Ubuntu 22.04 hosts | Real exec, strict profile, network isolation, service and lock verification; no skips |
| Multi-UID mapping (required) | A runner with an explicit subordinate UID/GID delegation | Must obtain multi mapping and pass chown, non-root exec and a service; no fallback or skip |
| Default host policy | Ubuntu 26.04 without changing userns/AppArmor sysctls | Execute successfully when bwrap can do so, or explicitly report host refusal; never report successful execution after a refusal |
| Compatibility coverage | Aggregate gate over every compatibility job | Every dependent job must succeed, including matrix entries |
| Security | C/Python CodeQL, repository secret patterns, pinned Alpine package scanning and SBOM | Workflow-defined failures block |

The main acceptance fixture intentionally enables unprivileged user namespaces on its ephemeral runner. The default-policy job does not change host policy; its summary distinguishes successful execution from an explicitly tested refusal. A refusal result is not a claim that this host can run a sandbox.

The legacy harness retains capability-dependent cases: T15/T16 require its daemon option, T19 requires its slow option, and T27 can test single-UID behavior where multi is unavailable. The independent compatibility jobs cover the success paths explicitly and do not use those skips as evidence.

GitHub's supported hosted runner labels are listed in the [official runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). Additional distro versions, WSL-specific behavior, privileged disk mounts and all application-level Wiki recipes are outside this matrix. A supported guest distro does not imply every third-party package or service combination has been tested.
