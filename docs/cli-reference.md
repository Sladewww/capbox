# CLI 参考

由 `python3 tools/generate-docs.py` 生成；不要手改命令输出。CLI 版本：**0.5.1**。本文件固定以 `CAPBOX_LANG=zh` 生成，不随 locale 切换（仓库文档政策：README.md 英文，README.zh-CN.md 与 docs/ 中文）。

## capbox --help

```text
CapBox —— 工作区内持久化的 root Linux 容器

用法: capbox [--root DIR] [--debug] [--allow-old-bwrap] <command> [options] [-- args]

全局选项
  --root DIR                        指定工作区根（其下使用 DIR/.capbox）；等价于 CAPBOX_ROOT
  --debug                           打开调试日志
  --allow-old-bwrap                 仅本次接受低于 0.12.0 的 bwrap（不写配置，写入审计）

系统生命周期
  upgrade check|apply --from TEMPLATE / upgrade rollback
                                    比较/更新项目运行文件；私有备份、失败回退
  bootstrap                         在当前工作区脚手架 .capbox/（从 PATH 上的模板复制）
  init [--distro alpine|ubuntu] [--agent|--trusted] [--force] [--from URL|路径]
                                    脚手架（如需）+ 下载解包 rootfs，注入镜像源，跑首次引导
  status [--json]                   查看 distro / rootfs / daemon / 网络状态
  doctor                            逐项自检（bwrap、userns 全权限、rootfs、镜像源…）
  clean [--all]                     清理缓存与日志；--all 一并删除 rootfs

执行
  exec [--daemon] [--timeout N] [--cwd DIR] [--uid N] [--gid N] [--user NAME] [--] CMD...
                                    在容器内执行命令（默认一次性无状态容器）
  setup check|plan [--json]         宿主依赖检查、安装和升级计划（不自动安装）
  bundle pack|verify|check|restore DIR
                                    可携带 rootfs/配方/包锁制品及完整性校验
  mcp serve                         固定工作区与策略的 stdio MCP 适配器
  task start|list|status|logs|attach|wait|cancel|diff|rm
                                    持久任务、断线重连与隔离工作副本 diff（task --help）
  policy show|check                 新 oneshot 有效策略与 HTTP(S) 网络决策预览
  service start|stop|status|logs|list
                                    配置化服务（.capbox/services/<name>.env）
  shell [--daemon]                  交互式 shell（无 tty 时退化为读取 stdin 的 sh）
  ls [PATH]                         列出容器内目录（默认 /workspace）
  ps                                列出容器内进程

常驻容器（优先 systemd 用户服务；普通 up 需要外层后台托管）
  up [--systemd]                    启动守护容器
  down                              停止守护容器
  logs [-f] [-n N]                  查看守护容器日志

文件与软件包
  cp SRC DST                        宿主↔容器 拷贝（guest:/path 或 host:/path）
  pkg install|remove|update|list [--] PKG...
                                    按发行版分派到 apk / apt-get

信息与配置
  distros                           列出支持的发行版与镜像 URL
  config get|set|list               读取 / 修改 config.env
  recipe check|apply|show [FILE]          应用/查看声明式 KEY=value 配方（不 source）
  snapshot create|list|restore|rm   rootfs 快照 / 回滚
  image export|import|docker|lock|cache
                                    rootfs 归档、包锁，以及本地 Docker/OCI 镜像
  secret set|ls|rm|import           宿主凭据（真实 key 不进沙箱；见 docs/credentials.md）
  audit report|query|tail|path|clear      离线 HTML 报告与 JSONL 审计日志
  metrics [--json]                  资源/cgroup/磁盘真实状态（无假数据）
  version                           打印版本
  help, --help, -h                  显示本帮助

网络（CAPBOX_NET）
  none         --unshare-net，容器内无网络
  open (host)  共享宿主网络（默认；host 为兼容别名）
  restricted   --unshare-net + 域名 allowlist 代理（需 python3/nsenter 与 CAPBOX_NET_ALLOW）
               不假装 bwrap 能过滤域名；原始 TCP 无路由，仅 HTTP(S)_PROXY 出站
  当次声明     exec|shell|up --net MODE（不写 config.env）。shell/exec --daemon 改不了已在跑的网络
  pkg          会话为 none 时，install 与 update 仍出网；remove 与 list 不出网

安全档（CAPBOX_SECURITY_PROFILE / exec --profile）
  compat       默认兼容：全量 capability、无 seccomp（不削弱现有行为）
  untrusted    显式收紧：capability drop + 真实 seccomp BPF + disable-userns
  strict       更严 seccomp + 默认 rootfs 只读（需 overlay 才可写根）+ 默认 Landlock
  Landlock     CAPBOX_LANDLOCK=on|off。未设置时仅 strict 开启。挂载完成之后限制 VFS，不限制 TCP

常用示例
  capbox bootstrap                       # 仅在当前目录生成 .capbox/
  capbox init --agent --distro alpine    # agent：untrusted/none，额度需另设
  capbox init --trusted --distro alpine  # 可信开发：compat/open
  capbox recipe apply                    # 按 capbox.recipe 写配置/init/装包
  capbox exec --net none -- id -u        # 无网络一次性执行
  capbox exec -- id -u                   # 容器内应为 0
  capbox pkg install curl                # 镜像源及 APK 安装脚本兼容封装
  echo 'echo hi' | capbox shell          # 无 tty 时可用

退出码
  0   成功
  1   一般错误（下载失败、内部失败等）
  2   用法错误
  3   守护容器未运行（需要 daemon 的命令）
  4   rootfs 不存在（先运行 capbox init）
  5   依赖缺失（bwrap 等）
  6   安全基线不满足（bwrap 低于 0.12.0，且未显式放行）
  124 容器内命令超时

要点
  * compat 档默认 uid 0 + 全量 capability；agent 入口使用显式 --agent 预设。
  * --agent 的 require 仅约束已配置限额；空 MEMORY_MAX/CPU_MAX/PIDS_MAX 表示未设额度。
  * CAPBOX_IDMAP=auto 时尝试 newuidmap 多 UID 映射；失败则诚实回退单 UID（见 doctor）。
  * rootfs/配置在项目 .capbox；宿主控制文件在工作区外的 0700 私有目录。
  * 常驻环境使用 up --systemd，或能跨调用存活的后台托管；外层 die-with-parent 会影响 nohup。
```

## capbox init --help

```text
用法: capbox init [--distro alpine|ubuntu] [--force] [--from URL|本地路径] [--agent|--trusted]

  若当前工作区还没有完整的 .capbox/，会先从已安装的 CapBox 模板脚手架
  bin/、lib/、skill/ 到 $PWD/.capbox（不覆盖已有文件，不复制 cache/os/run）。

  --distro D   选择发行版（默认取 CAPBOX_DISTRO，初始 alpine）
  --force      忽略缓存重新下载，并覆盖已有 rootfs
  --from P     指定镜像来源：http(s) URL 或本地 tarball 路径
  --trusted    可信开发预设：compat + open + IDMAP=auto + RESOURCES_MODE=warn
  --agent      agent 预设：untrusted + none + IDMAP=off + RESOURCES_MODE=require
               MEMORY_MAX/CPU_MAX/PIDS_MAX 需按任务单独配置；空值表示未设置额度。
               pkg install / pkg update 仍出网。其它出网在当次命令声明：
               exec|shell|up --net restricted（需 CAPBOX_NET_ALLOW）或 --net open
```

## capbox upgrade --help

```text
用法: capbox upgrade check --from TEMPLATE [--json]
      capbox upgrade apply --from TEMPLATE
      capbox upgrade rollback

  TEMPLATE 是工作区外、由你信任的完整 CapBox 安装目录（含 bin/lib）。
  check 比较运行文件；apply 暂存并校验成套 bin/lib，私有备份后替换。
  替换或冒烟检查失败时恢复原文件；rollback 恢复最近一次成功升级前的文件。
  必须先用旧 CLI 停止所有 service/daemon，并停止其它 exec；不会替你杀进程。
  仅更新运行文件；配置、rootfs、业务数据保持原位置。备份持久保存在工作区外的 XDG_STATE_HOME/capbox（默认 ~/.local/state/capbox）。
  旧项目请从新版模板的 bin/capbox 调用本命令（--root 指定项目）。
```

## capbox recipe --help

```text
用法: capbox recipe apply [--locked LOCKFILE] [FILE]
      capbox recipe check [FILE]
      capbox recipe show  [FILE]

  声明式 KEY=value 配方（不会被 source）。默认读：
    ./capbox.recipe  或  .capbox/recipe.env

  常用键: DISTRO PACKAGES NET NET_ALLOW MEMORY_MAX CPU_MAX PIDS_MAX MIRROR INIT
  export FILE：导出经过校验的 JSON 配方数据（不执行）。
  check：完整校验，不写配置。未知键、重复键或无效行均报错。
  apply：完整校验 → 一次写回 config.env → 按需 init → 安装 PACKAGES
  --locked：按严格包锁安装并验证；版本不可用则失败。
```

## capbox image --help

```text
用法: capbox image <export|import|list|verify|lock|cache|docker> ...

  export NAME              导出当前 rootfs → .capbox/images/NAME.tar.zst|gz + .sha256
  import NAME [--force]    导入到旁路目录 os/<distro>.imported-NAME；--force 才替换当前 rootfs
  list                     列出已导出的 rootfs 归档
  verify NAME              校验 SHA256
  lock save|show|verify|restore [FILE]  保存/查看/验证/按精确版本恢复包锁
  cache save|restore|path  离线包缓存（apk/apt 缓存目录打包）
  docker ...               导入、拉取或运行 Docker/OCI 镜像
                           （不连接 Docker daemon）。详见 capbox image docker --help

导入默认不破坏现有 rootfs；--force 会先 snapshot-bak 再替换。
Docker/OCI 导入落在 .capbox/images/docker/<name>/，不替换 Alpine/Ubuntu rootfs。
```

## capbox image docker --help

```text
用法: capbox image docker <inspect|import|pull|list|show|rm|run> ...

  inspect ARCHIVE [--platform OS/ARCH] [--index N] [--tag REF]
                           打印镜像配置 JSON。不展开，也不执行。
  import ARCHIVE [--name NAME] [--platform OS/ARCH] [--index N] [--tag REF] [--force]
                           按层展开到 .capbox/images/docker/<name>/rootfs
  pull REF [--name NAME] [--platform OS/ARCH] [--force]
                           用宿主的 skopeo（没有则用 crane）拷到临时 OCI layout，再导入。
                           先把标签解析成摘要再复制。不连接 Docker daemon，也不读 docker.sock。
                           CAPBOX_OCI_REGISTRIES 是逗号分隔的 registry 白名单
                           （默认 docker.io,ghcr.io,quay.io,public.ecr.aws,registry.k8s.io；* 表示全部放行）。
  list                     列出已导入的 Docker/OCI 镜像
  show NAME                打印 meta.json
  rm NAME                  删除一个已导入镜像
  run NAME|ARCHIVE [选项] [--] [CMD...]
                           参数是已导入名字就直接启动；是文件则已有同名镜像时复用，否则先导入。显式 --force 才重新导入

run 选项:
  --name NAME              文件导入后的名字（默认取标签，否则 img-<摘要>）
  --force                  文件路径已有同名镜像时仍重新导入
  --cwd DIR                覆盖 WorkingDir
  --user USER              覆盖 User（名字、uid 或 uid:gid）
  --timeout N              一次性超时秒数
  --net MODE               仅本次：none|restricted|open
  --profile P              仅本次：compat|untrusted|strict
  --entrypoint PROG        替换 Entrypoint（一个 argv）
  --clear-entrypoint       丢掉镜像 Entrypoint

Entrypoint、Cmd、User、WorkingDir、Env 都是数据。Env 只经 bwrap --setenv 进入 guest，
不 export 到宿主 shell。-- 后面的参数替换 Cmd，保留 Entrypoint。
exec --image NAME 只换这一次的 rootfs，不套用 OCI 配置。
非 Linux 镜像拒绝。层里的设备节点跳过。文件属主是执行导入的用户。
```

## capbox service --help

```text
用法: capbox service <start|stop|status|logs|list> NAME [options]

  start NAME     按 .capbox/services/NAME.env 启动（独立 bwrap）
  stop NAME      停止服务
  status NAME    查看状态与诊断
  logs NAME [-f] [-n N]
  list           列出已定义服务

示例 (.capbox/services/nginx.env):
  CMD='nginx -g "daemon off;"'
  USER=www-data
  CWD=/
  READY_TCP=127.0.0.1:18080
  HEALTH_INTERVAL=5
  RESTART=on-failure
  RESTART_MAX=3
  STOP_TIMEOUT=10
  DEPENDS_ON=other
```

## capbox task --help

```text
用法: capbox task [-h] {start,list,status,wait,attach,cancel,logs,diff,rm,checkpoint,restore} ...

位置参数:
  {start,list,status,wait,attach,cancel,logs,diff,rm,checkpoint,restore}
    start               启动独立监督的 exec 任务
    checkpoint          归档已结束的隔离任务
    restore             将本地任务检查点恢复到新项目

选项:
  -h, --help            显示此帮助并退出
```

## capbox task start --help

```text
用法: capbox task start [-h] [--json] [--timeout TIMEOUT] [--cwd CWD]
                      [--net {none,restricted,open,host}] [--net-allow NET_ALLOW]
                      [--profile {compat,untrusted,strict}] [--isolate]
                      [--max-output-bytes MAX_OUTPUT_BYTES]
                      ...

位置参数:
  command

选项:
  -h, --help            显示此帮助并退出
  --json                结果默认即为版本化 JSON
  --timeout TIMEOUT
  --cwd CWD
  --net {none,restricted,open,host}
  --net-allow NET_ALLOW
                        任务出站规则，以逗号分隔，须在宿主 restricted 白名单范围内
  --profile {compat,untrusted,strict}
  --isolate             复制工作区文件与独立 rootfs（Git 脏树/非 Git/overlay 合并）；diff 后导出
  --max-output-bytes MAX_OUTPUT_BYTES
```

## capbox policy --help

```text
用法: capbox policy [-h] {show,check} ...

位置参数:
  {show,check}

选项:
  -h, --help    显示此帮助并退出
```

## capbox setup --help

```text
用法: capbox setup [-h] {check,plan} ...

位置参数:
  {check,plan}

选项:
  -h, --help    显示此帮助并退出
```

## capbox bundle --help

```text
用法: capbox bundle [-h] {pack,verify,check,restore} ...

位置参数:
  {pack,verify,check,restore}

选项:
  -h, --help            显示此帮助并退出
```

## capbox mcp --help

```text
用法: capbox mcp [-h] [--profile {untrusted,strict}] [--net {none,restricted}]
               [--workspace-mode {isolated,shared}] [--max-timeout MAX_TIMEOUT]
               {serve}

位置参数:
  {serve}

选项:
  -h, --help            显示此帮助并退出
  --profile {untrusted,strict}
                        安全配置档（默认: untrusted）
  --net {none,restricted}
                        网络模式（默认: none；拒绝 open）
  --workspace-mode {isolated,shared}
                        任务工作区（默认: isolated）
  --max-timeout MAX_TIMEOUT
                        任务超时上限秒数（默认: 600）
```

## capbox audit --help

```text
用法: capbox audit <report|query|tail|path|clear> [参数]

  report --output FILE  生成离线 HTML 报告（文件须在工作区外，report --help 查看筛选参数）
  query --task-id ID    以 JSON 查询任务及关联事件
  tail [N]   显示最近 N 条（默认 50）
  path       打印审计文件路径
  clear      清空审计文件（需确认意图：直接执行即清空）

CAPBOX_AUDIT=off|summary|full
  summary（默认）：记下脱敏后的完整参数、status、退出码和耗时；
                 失败可带截断短 detail。不写命令 stdout/stderr。
  full：在 summary 之上，允许再写封顶后的脱敏 output 字段。
CAPBOX_AUDIT_CMD=summary|full|off
  不设置时跟随 CAPBOX_AUDIT。off 不写 cmd 字段。
  summary 与 full 都写脱敏后的完整参数（不再是 argv0 加参数个数）。
```

## capbox audit report --help

```text
用法: capbox audit report [-h] [--task-id TASK_ID] --output OUTPUT [--force] [--json]
                        [--input INPUT] [--limit LIMIT] [--since SINCE] [--until UNTIL]
                        [--kind KIND] [--status STATUS]

导出可搜索、筛选的离线 HTML 审计报告，不启动服务

选项:
  -h, --help         显示此帮助并退出
  --task-id TASK_ID  精确匹配任务 ID（32 位小写十六进制字符）
  --output OUTPUT    工作区外的 HTML 文件；父目录必须已存在
  --force            原子替换当前用户已有的普通输出文件
  --json             输出机器可读的生成结果
  --input INPUT      显式读取其它普通 JSONL 审计文件；默认当前项目 logs/audit.jsonl
  --limit LIMIT      保留扫描区域内最后 N 条匹配记录（1–20000，默认 5000）
  --since SINCE      起始时间（包含）；ISO 8601 时区或 UTC 日期
  --until UNTIL      结束时间（不包含）；ISO 8601 时区或 UTC 日期
  --kind KIND        只导出此类型，可重复
  --status STATUS    只导出此状态，可重复
```

## capbox audit query --help

```text
用法: capbox audit query [-h] --task-id TASK_ID [--input INPUT] [--limit LIMIT] [--since SINCE]
                       [--until UNTIL] [--kind KIND] [--status STATUS]

从项目审计日志查询任务及其事件，输出 JSON

选项:
  -h, --help         显示此帮助并退出
  --task-id TASK_ID  精确匹配任务 ID（32 位小写十六进制字符）
  --input INPUT      显式读取其它普通 JSONL 审计文件；默认当前项目 logs/audit.jsonl
  --limit LIMIT      保留扫描区域内最后 N 条匹配记录（1–20000，默认 5000）
  --since SINCE      起始时间（包含）；ISO 8601 时区或 UTC 日期
  --until UNTIL      结束时间（不包含）；ISO 8601 时区或 UTC 日期
  --kind KIND        只导出此类型，可重复
  --status STATUS    只导出此状态，可重复
```

## capbox pkg --help

```text
用法: capbox pkg <install|remove|update|list> [--] PKG...

  install PKG...   安装软件包
  remove PKG...    卸载软件包
  update           刷新软件源索引
  list [PATTERN]   列出已安装包（可给过滤模式）

按发行版自动分派到 apk（alpine）或 apt-get（ubuntu），
ubuntu 自动附加 APT::Sandbox::User=root（本环境必需）。
会话 CAPBOX_NET=none 时，install 和 update 仍会出网；remove 和 list 不会。
这次出网不写进 config.env。pip / npm / git 不会因此获得网络。
安装后会跑 dpkg --audit / 扫描 iU·iF 状态；有残留配置会明确报告（不掩盖）。
启用 CAPBOX_IDMAP=auto/on 且多映射可用时，apt postinst 的 chown 更可能成功。
```
