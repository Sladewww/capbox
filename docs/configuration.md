# 配置默认值

由 `lib/config.sh` 生成；CLI 版本：**0.4.2**。下列为裸初始化默认值。显式 `--agent` 与 `--trusted` 预设会覆盖各自的四项设置。空额度表示 **尚未配置额度**。

| 键 | 默认值 |
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

优先级：内置默认 < config.env < 显式环境变量。`ALLOW_OLD_BWRAP` 不能通过环境变量打开。配置文件与配方按数据解析，从不 source。
