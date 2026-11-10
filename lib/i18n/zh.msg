# CapBox i18n catalog (zh)
# Shared by bash and Python. Do not source this file.
# Single-line: key=value
# Multiline: key<< ... >>

log.prefix.info=[capbox]
log.prefix.warn=[capbox] 警告:
log.prefix.err=[capbox] 错误:

help.main<<
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
  image export|import|lock|cache    镜像与离线缓存；lock save|verify|restore
  secret set|ls|rm|import           宿主凭据（真实 key 不进沙箱；见 docs/credentials.md）
  audit report|tail|path|clear      离线 HTML 报告与 JSONL 审计日志
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
>>

help.init<<
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
>>

help.bootstrap<<
用法: capbox bootstrap

  在当前工作区创建/补齐 .capbox/（从已安装模板复制 bin、lib、skill）。
  不下载 rootfs；随后请运行 capbox init。
>>

help.upgrade<<
用法: capbox upgrade check --from TEMPLATE [--json]
      capbox upgrade apply --from TEMPLATE
      capbox upgrade rollback

  TEMPLATE 是工作区外、由你信任的完整 CapBox 安装目录（含 bin/lib）。
  check 比较运行文件；apply 暂存并校验成套 bin/lib，私有备份后替换。
  替换或冒烟检查失败时恢复原文件；rollback 恢复最近一次成功升级前的文件。
  必须先用旧 CLI 停止所有 service/daemon，并停止其它 exec；不会替你杀进程。
  仅更新运行文件；配置、rootfs、业务数据保持原位置。备份持久保存在工作区外的 XDG_STATE_HOME/capbox（默认 ~/.local/state/capbox）。
  旧项目请从新版模板的 bin/capbox 调用本命令（--root 指定项目）。
>>

help.recipe<<
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
>>

help.image<<
用法: capbox image <export|import|list|verify|lock|cache> ...

  export NAME              导出当前 rootfs → .capbox/images/NAME.tar.zst|gz + .sha256
  import NAME [--force]    导入到旁路目录 os/<distro>.imported-NAME；--force 才替换当前 rootfs
  list                     列出已导出镜像
  verify NAME              校验 SHA256
  lock save|show|verify|restore [FILE]  保存/查看/验证/按精确版本恢复包锁
  cache save|restore|path  离线包缓存（apk/apt 缓存目录打包）

导入默认不破坏现有 rootfs；--force 会先 snapshot-bak 再替换。
>>

help.service<<
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
>>

help.service.logs<<
用法: capbox service logs NAME [-f] [-n N]
>>

help.audit<<
用法: capbox audit <report|tail|path|clear> [参数]

  report --output FILE  生成离线 HTML 报告（文件须在工作区外，report --help 查看筛选参数）
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
>>

help.pkg<<
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
>>

help.secret<<
用法: capbox secret set|ls|rm|import

  secret set <service> [--value-stdin|--command CMD]
  secret set --custom --host HOST [--host HOST...] --env NAME [--name ID] [--value-stdin|--command CMD]
  secret ls
  secret rm <name>
  secret import [service] [--all] [--force] [--dry-run]

真实密钥只保存在宿主私有目录（0700/0600）。guest 仅见 capbox-sec-<32hex> 占位符；
restricted 代理在 NET_ALLOW 授权域名上改写 HTTP(S) 请求头。详见 docs/credentials.md。
>>

help.snapshot<<
用法: capbox snapshot <create|list|restore|rm> [NAME]

  create NAME   打包当前 rootfs 到 .capbox/snapshots/NAME.tar.zst|gz（保留数字属主）
  list          列出快照
  restore NAME  回滚 rootfs（先写到临时目录再替换，不直接毁掉现网未确认的数据）
  rm NAME       删除快照

注意：restore 会替换 os/<distro>/；请先 create 备份。不触碰无关数据目录。
>>

help.down<<
用法: capbox down
停止常驻守护容器
>>

help.status<<
用法: capbox status [--json]
>>

help.logs<<
用法: capbox logs [-f] [-n N]

  输出守护容器（bwrap 那个进程）的 stdout/stderr。
  -f  持续跟随（Ctrl-C 退出）
  -n  显示最后 N 行，默认 50
>>

help.exec<<
用法: capbox exec [--daemon] [--timeout N] [--cwd DIR] [--root] [--net MODE]
                  [--uid N] [--gid N] [--user NAME] [--profile compat|untrusted|strict] [--] CMD...

  --daemon     在常驻容器内执行（需先启动 capbox up）
  --timeout N  一次性执行超时秒数，0=不限，默认取 CAPBOX_EXEC_TIMEOUT
  --cwd DIR    容器内工作目录（默认 /workspace，相对路径按 /workspace 解释）
  --root       在容器根目录 / 下执行（等价于 --cwd /）
  --net MODE   覆盖本次 oneshot 的 CAPBOX_NET：none|restricted|open（host=open）
               不写 config.env。与 --daemon 不能同用（守护容器的网络在 up 时确定）
  --uid N      容器内初始 uid（默认 CAPBOX_EXEC_UID / 0）；与 --daemon 组合时在命令前降权
  --gid N      容器内初始 gid
  --user NAME  从 guest /etc/passwd 解析 uid:gid（可与数字 uid 二选一）
  --profile P  覆盖 CAPBOX_SECURITY_PROFILE（仅本次 oneshot）

stdout 只包含容器内命令的输出，可直接被管道消费。
退出码透传容器内退出码；超时为 124；需要 daemon 但未运行为 3。
>>

help.shell<<
用法: capbox shell [--daemon] [--net MODE]
  交互式 shell（无 tty 时退化为读取 stdin 的 sh）
  --net 只作用于一次性 shell，不写 config.env，也不能改已在跑的守护容器
>>

help.clean<<
用法: capbox clean [--cache] [--all]

  （无参数）  清理日志、临时文件、一次性 exec 残留；**保留缓存与 rootfs**
  --cache     额外清理 cache/ 下已下载的镜像 tarball
  --all       清理缓存并删除当前 distro 的 rootfs（最彻底，需重新 init）

注意：clean 会先停止正在运行的守护容器（等价于 capbox down，优雅退出），
      然后清理 run/tmp —— 容器内 /tmp 的后端。目录本身保留，daemon 可正常重启。
>>

help.metrics<<
用法: capbox metrics [--json]
  显示 cgroup/磁盘/安全档/网络等真实探测结果（不编造已限额）。
>>

help.ls<<
用法: capbox ls [PATH]    列出容器内目录（默认 /workspace）
>>

help.ps<<
用法: capbox ps    列出容器内进程
>>

help.cp<<
用法: capbox cp SRC DST

路径写法（契约 §3.1：容器侧路径以 os/<distro>/ 为根）：
  guest:/path   容器内绝对路径 → os/<distro>/path
  host:/path    宿主路径（相对路径按当前 cwd 解析）
  /abs/path     裸绝对路径 = 容器侧
  rel/path      裸相对路径 = 容器侧（相对 rootfs 根）

要点：**不带前缀的一律按容器侧解释**；操作宿主文件请显式写 host:。

例:
  capbox cp guest:/etc/os-release host:./os-release
  capbox cp host:./app.conf guest:/etc/app.conf
  capbox cp host:/tmp/a.txt /root/a.txt          # 落到 rootfs/root/a.txt
>>

help.up<<
用法: capbox up [--systemd] [--net MODE]

启动常驻守护容器。

默认前台阻塞。调用方的 shell 如果包了 bwrap --die-with-parent
（DSH / 部分 coding agent 的 bash 工具），这次调用结束会杀掉整棵进程树，
nohup/setsid 也救不了。两种活法：

  1) capbox up --systemd
     交给 systemd --user 的 transient service，进程不属于这次工具调用。
     需要用户会话的 systemd（systemctl --user 可用）。之后 capbox down 会停这个单元。
  2) 把 capbox up 放进活得比工具调用更久的任务（例如 bash 工具 run_in_background）。

  --net MODE   只作用于这一次 up（none|restricted|open，host=open）。不写 config.env。
               单元已在跑时不会改它的网络。

停止: capbox down
>>
