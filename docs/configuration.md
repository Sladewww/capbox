# Configuration defaults

Generated from `lib/config.sh`; CLI version: **0.4.0**. These are bare-initialization defaults. Explicit `--agent` and `--trusted` presets overwrite their four settings. Empty quotas mean **no quota has been configured**.

| Key | Default |
|---|---|
| `CAPBOX_DISTRO` | `"alpine"` |
| `CAPBOX_MIRROR` | `"cn"` |
| `CAPBOX_MIRROR_ALPINE` | `"https://mirrors.aliyun.com/alpine"` |
| `CAPBOX_MIRROR_UBUNTU` | `"https://mirrors.aliyun.com/ubuntu"` |
| `CAPBOX_PROXY` | `""` |
| `CAPBOX_NET` | `"open"` |
| `CAPBOX_NET_ALLOW` | `""` |
| `CAPBOX_HOSTNAME` | `"capbox"` |
| `CAPBOX_EXEC_TIMEOUT` | `"600"` |
| `CAPBOX_MEMORY_MAX` | `""` |
| `CAPBOX_CPU_MAX` | `""` |
| `CAPBOX_PIDS_MAX` | `""` |
| `CAPBOX_DISK_MAX` | `""` |
| `CAPBOX_RESOURCES_MODE` | `"warn"` |
| `CAPBOX_BWRAP` | `"/usr/bin/bwrap"` |
| `CAPBOX_IDMAP` | `"auto"` |
| `CAPBOX_UID_MAP` | `""` |
| `CAPBOX_GID_MAP` | `""` |
| `CAPBOX_SETGROUPS` | `""` |
| `CAPBOX_EXEC_UID` | `"0"` |
| `CAPBOX_EXEC_GID` | `"0"` |
| `CAPBOX_SECURITY_PROFILE` | `"compat"` |
| `CAPBOX_LANDLOCK` | `""` |
| `CAPBOX_ROOTFS_RO` | `"0"` |
| `CAPBOX_FS_HIDE` | `""` |
| `CAPBOX_FS_BINDS` | `""` |
| `CAPBOX_OVERLAY` | `"auto"` |
| `CAPBOX_AUDIT` | `"summary"` |
| `CAPBOX_AUDIT_CMD` | `""` |
| `CAPBOX_ALLOW_OLD_BWRAP` | `"0"` |

Precedence: built-in defaults < config.env < explicit environment. `ALLOW_OLD_BWRAP` cannot be enabled through the environment. Configuration files and recipes are parsed as data, never sourced.
