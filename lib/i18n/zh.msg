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

# Host bash log_*/die and usage/error message bodies
val.unset=未设置
val.see_doctor=见 doctor
val.unknown=未知
val.unknown_error=未知错误
val.no_cgroup_delegate=无 cgroup 委派
val.unavailable=不可用
cli.ignore_allow_old_bwrap=忽略环境变量 CAPBOX_ALLOW_OLD_BWRAP={value}；持久放行写入 config.env，单次放行用 --allow-old-bwrap
cli.root_missing_arg=--root 需要参数（工作区路径）
cli.template_not_found=找不到 CapBox 模板（CLI 旁无 lib/）；请安装 CapBox 或用项目内 .capbox/bin/capbox
cli.root_not_found=找不到 CapBox 根目录（.capbox）；请在项目下运行 capbox init，或设置 CAPBOX_ROOT=/path/to/project
cli.upgrade_incomplete=运行文件升级未完成；请用完整模板运行 upgrade rollback
cli.cannot_load_common=无法加载 {dir}/common.sh
cli.incomplete_install=安装不完整，缺少 {dir}/{module}.sh
common.bwrap_below_baseline=FAIL  bwrap {ver} 低于安全基线 0.12.0
common.need_cmd=缺少依赖命令: {cmd}
common.need_cmd_hint=缺少依赖命令: {cmd}（{hint}）

rootfs.need_curl_to_download=下载 rootfs 需要 curl
rootfs.need_tar_to_unpack=解包 rootfs 需要 tar
rootfs.need_curl_to_init_from_url=从 URL 初始化需要 curl
config.need_flock_to_commit=配置提交需要进程间锁
config.need_flock_to_read=读取配置需要共享锁
cli.cmd_unavailable=命令 '{label}' 不可用：缺少实现函数 {fn}
cli.cmd_unavailable_hint=命令 '{label}' 不可用：缺少实现函数 {fn}（{hint}）

cli.module_not_ready={module} 尚未就绪
cli.unknown_global_option=未知全局选项: {arg}
cli.unknown_command=未知命令: {cmd}
audit.audit_log_must_regular_file_refusing_write=审计日志必须是普通文件，拒绝写入: {f}
audit.unable_truncate=无法清空 {f}
audit.cleared_audit_log=已清空审计日志: {f}
audit.audit_tail_n_must_non_negative_integer=audit tail: N 必须是非负整数
audit.audit_unknown_subcommand_report_tail_path_clear=audit: 未知子命令 {sub}（report|tail|path|clear）
audit.metrics_unknown_option=metrics: 未知选项 {arg}
common.net_must_none_restricted_open_host_alias={who}: --net 必须是 none|restricted|open（host 别名）；当前: {mode}
common.net_restricted_requires_non_empty_capbox_net={who}: --net restricted 需要非空 CAPBOX_NET_ALLOW（config set 或环境变量）
common.configured_capbox_bwrap_not_executable_trying_auto=配置的 CAPBOX_BWRAP={cfg_val} 不可执行，尝试自动发现
common.bwrap_unavailable=bwrap 不可用: {bwrap}
common.bwrap_below_0_12_0_security_baseline=bwrap {ver} 低于安全基线 0.12.0，已被 CAPBOX_ALLOW_OLD_BWRAP 放行（doctor 仍为 FAIL）
common.unable_write_old_bwrap_allow_audit_record=无法写入旧版 bwrap 放行审计，拒绝启动
common.audit_log_path_symlink_refusing_record_old=审计日志路径是符号链接，拒绝记录旧版 bwrap 放行: {f}
common.audit_log_directory_not_regular_directory_refusing=审计日志目录不是普通目录，拒绝记录旧版 bwrap 放行: {dir}
common.audit_log_path_unusable_refusing_record_old=审计日志路径不可用，拒绝记录旧版 bwrap 放行: {f}
common.host_private_directory_must_owned_current_user=宿主私有目录必须由当前用户拥有、权限 0700 且不是符号链接: {candidate}
common.no_safe_host_runtime_directory_found_outside=找不到工作区之外的安全宿主运行目录（需要私有 runtime 或 sticky /tmp）
common.unable_normalize_path_realpath_m_required=无法规范化路径（需要可用的 realpath -m）: {p}
common.refused_workspace_resolved_dangerous_path_project_local=拒绝：工作区解析为危险路径 ({workspace})。请在项目下使用 .capbox/，或设置 CAPBOX_ROOT=/path/to/project（不要把 CapBox 装在 $HOME 下作为全局 CLI，以免绑定整个家目录）。
common.guest_path_must_not_contain=guest 路径禁止 ..: {guest_path}
common.protected_config_path_symlink_refusing_start=受保护配置路径是符号链接，拒绝启动: {host_file}
common.protected_config_path_directory_skipping_file_pre=受保护配置路径是目录，跳过文件预占: {host_file}
common.unable_create_mount_point_missing_config_file=无法为缺失配置创建挂载点: {host_file}
common.protected_directory_symlink_refusing_start=受保护目录是符号链接，拒绝启动: {host_dir}
common.regular_file_exists_protected_directory_path_skipping=受保护目录路径上存在普通文件，跳过: {host_dir}
common.logs_symlink_refusing_start=logs 是符号链接，拒绝启动: {host_dir}
common.logs_must_regular_directory_refusing_start=logs 必须是普通目录，拒绝启动: {host_dir}
common.logs_audit_jsonl_symlink_refusing_start_audit=logs/audit.jsonl 是符号链接，拒绝启动: {host_dir}/audit.jsonl
common.logs_audit_jsonl_must_regular_file_refusing=logs/audit.jsonl 必须是普通文件，拒绝启动: {host_dir}/audit.jsonl
common.unable_bind_mount_logs_read_only_guest=无法把 logs 只读挂进 guest: {host_dir}
common.capbox_dir_symlink_refusing_start=CAPBOX_DIR 是符号链接，拒绝启动: {dir}
common.protected_directory_symlink_refusing_start_2=受保护目录是符号链接，拒绝启动: {host_path}
common.refusing_clean_path_outside_workspace=拒绝清理工作区之外的路径: {d}
common.refusing_delete_not_under_os=拒绝删除: {d} 不在 {dir}/os/ 之下
common.removing_rootfs=删除 rootfs: {d}
common.lock_missing_command_run=with_lock: 缺少要执行的命令
common.timed_out_waiting_lock=等待锁超时: {lockfile}
common.unable_generate=无法生成 {dst}
common.run_bwrap_oneshot_missing_guest_command=run_bwrap_oneshot: 缺少容器内命令
common.unable_build_bwrap_arguments_rc_common_causes=无法构造 bwrap 参数（rc={_bbrc}；常见原因：bwrap 版本不足、FS_BINDS 越界、安全档/seccomp 失败）
common.rootfs_does_not_exist_run_capbox_init=rootfs 不存在: {rootfs}（请先运行 capbox init）
common.bwrap_unavailable_apt_install_bubblewrap=bwrap 不可用: {bwrap}（apt install bubblewrap）
common.capbox_net_restricted_net_sh_not_loaded=CAPBOX_NET=restricted 但 net.sh 未加载
common.capbox_idmap_multi_uid_mapping_unavailable=CAPBOX_IDMAP=on 但多 UID 映射不可用：{detail}
common.exec_guest_command_empty=exec_in_guest: 命令为空
common.unable_create_capbox_current_workspace=无法在当前工作区创建 .capbox
common.rootfs_missing_unusable_run_capbox_init_distro=rootfs 不存在或不可用: {rootfs}；请先运行: capbox init --distro {distro}（会自动脚手架当前目录的 .capbox）
common.status_unknown_option=status: 未知选项 {arg}
common.usage_capbox_config_get_key=用法: capbox config get KEY
common.unknown_config_key_available=未知配置项: {arg}；可用: {keys}
common.usage_capbox_config_set_yes_key_value=用法: capbox config set [--yes] KEY VALUE
common.set=已设置 {key} = {val}
common.usage_capbox_config_get_set_list_key=用法: capbox config <get|set|list> [KEY] [VALUE]
common.clean_unknown_option=clean: 未知选项 {arg}
common.daemon_container_running_clean_will_stop_first=检测到守护容器正在运行，clean 会先停止它（优雅退出，等待在跑任务完成）
common.failed_stop_daemon_container_rc_continuing_temp=停止守护容器失败（rc={drc}，继续清理临时文件）
common.cleaning_logs=清理日志 ({log_dir})
common.cleaning_temporary_state_ec=清理临时状态 ({state_dir}/ec-*, {tmp_dir})
common.cleaning_cache=清理缓存 ({cache_dir})
common.cache_kept_files_about_pass_cache_all=缓存保留（{n_cache} 个文件，约 {size}）；加 --cache 或 --all 才会清理
common.removed_rootfs_cache_run_capbox_init_again=已删除 rootfs 与缓存；下次使用前需重新 capbox init
common.cleaned_logs_temp_files_rootfs_cache_kept=已清理日志/临时文件（rootfs 与缓存保留）
common.capbox_template_tree_not_found_install_lib=找不到 CapBox 模板树（需要带 lib/common.sh 的安装）。请先安装 CapBox Skill/CLI。
common.creating_capbox_current_workspace_template=正在当前工作区创建 .capbox …（模板: {template} → {dir}）
common.unable_create=无法创建 {dir}
common.scaffold_copy_failed=脚手架复制失败: {srcd}
common.lib_common_sh_still_missing_after_scaffolding=脚手架后仍缺少 lib/common.sh
common.bin_capbox_still_missing_after_scaffolding=脚手架后仍缺少 bin/capbox
common.workspace_ready=已在工作区就绪: {dir}
common.capbox_auto_init_1_running_capbox_init=CAPBOX_AUTO_INIT=1：自动执行 capbox init
config.capbox_distro_must_alpine_ubuntu_got=CAPBOX_DISTRO 只能是 alpine 或 ubuntu（当前: '{v}'）
config.capbox_mirror_must_cn_global_none_got=CAPBOX_MIRROR 只能是 cn / global / none（当前: '{v}'）
config.capbox_net_must_none_restricted_open_host=CAPBOX_NET 只能是 none / restricted / open（host 为 open 的兼容别名；当前: '{v}'）
config.capbox_net_allow_may_only_contain_domain=CAPBOX_NET_ALLOW 只能包含域名/IP/逗号/冒号/斜线/星号（当前: '{v}'）
config.invalid_capbox_memory_max_format_e_g=CAPBOX_MEMORY_MAX 格式无效（例 512M / 1G；当前: '{v}'）
config.invalid_capbox_cpu_max_format_e_g=CAPBOX_CPU_MAX 格式无效（例 50% 或 '50000 100000'；当前: '{v}'）
config.capbox_pids_max_must_positive_integer_got=CAPBOX_PIDS_MAX 必须是正整数（当前: '{v}'）
config.capbox_exec_timeout_must_non_negative_integer=CAPBOX_EXEC_TIMEOUT 必须是非负整数秒（当前: '{v}'）
config.capbox_proxy_must_start_http_https_socks5=CAPBOX_PROXY 必须是 http:// https:// socks5:// socks5h:// 之一开头，或留空表示直连（当前: '{v}'）
config.capbox_hostname_may_only_contain_letters_digits=CAPBOX_HOSTNAME 只能是字母数字与 . -（当前: '{v}'）
config.capbox_must_url_starting_http_s_got=CAPBOX_{k} 必须是 http(s):// 开头的 URL（当前: '{v}'）
config.capbox_bwrap_must_not_empty_path_bubblewrap=CAPBOX_BWRAP 不能为空（bubblewrap 可执行文件路径）
config.capbox_idmap_must_auto_off_got=CAPBOX_IDMAP 只能是 auto / on / off（当前: '{v}'）
config.capbox_segments_must_guest_host_count_current=CAPBOX_{k} 段须为 guest:host:count（当前段: '{part}'）
config.capbox_setgroups_must_allow_deny_got=CAPBOX_SETGROUPS 只能是 allow / deny（当前: '{v}'）
config.capbox_must_non_negative_integer_got=CAPBOX_{k} 必须是非负整数（当前: '{v}'）
config.invalid_capbox_disk_max_format_e_g=CAPBOX_DISK_MAX 格式无效（例 1G；当前: '{v}'）
config.capbox_resources_mode_must_warn_require_got=CAPBOX_RESOURCES_MODE 只能是 warn|require（当前: '{v}'）
config.capbox_security_profile_must_compat_untrusted_strict=CAPBOX_SECURITY_PROFILE 只能是 compat|untrusted|strict（当前: '{v}'）
config.capbox_landlock_must_off_got_when_unset=CAPBOX_LANDLOCK 只能是 on 或 off（当前: '{v}'）。未设置时 strict 默认开启
config.capbox_rootfs_ro_must_0_1_got=CAPBOX_ROOTFS_RO 只能是 0/1（当前: '{v}'）
config.capbox_fs_hide_contains_illegal_characters_got=CAPBOX_FS_HIDE 含非法字符（当前: '{v}'）
config.capbox_fs_hide_must_not_contain=CAPBOX_FS_HIDE 禁止 ..
config.capbox_fs_binds_contains_illegal_characters_got=CAPBOX_FS_BINDS 含非法字符（当前: '{v}'）
config.capbox_fs_binds_must_not_contain=CAPBOX_FS_BINDS 禁止 ..
config.capbox_overlay_must_auto_0_1_got=CAPBOX_OVERLAY 只能是 auto|0|1（当前: '{v}'）
config.capbox_audit_must_off_summary_full_got=CAPBOX_AUDIT 只能是 off|summary|full（当前: '{v}'）
config.capbox_audit_cmd_must_off_summary_full=CAPBOX_AUDIT_CMD 只能是 off|summary|full（当前: '{v}'）
config.capbox_allow_old_bwrap_must_0_1=CAPBOX_ALLOW_OLD_BWRAP 只能是 0 或 1（当前: '{v}'）。持久放行: capbox config set --yes CAPBOX_ALLOW_OLD_BWRAP 1
config.unknown_config_key_capbox=未知配置项: CAPBOX_{k}
config.config_target_must_regular_file=配置目标必须是普通文件: {f}
config.failed_write_config=配置写入失败: {f}
config.config_batch_must_key_value_pairs=配置批次必须为键值对
config.unknown_config_key=未知配置项: {k}
config.config_env_rejected_double_quoted_value_containing=config.env 拒绝含展开符的双引号值: {key}
config.config_env_rejected_unsafe_bare_value=config.env 拒绝不安全的裸值: {key}
config.ignoring_environment_variable_capbox_allow_old_bwrap=忽略环境变量 CAPBOX_ALLOW_OLD_BWRAP={value}；持久放行只能写入 config.env，单次放行用 capbox --allow-old-bwrap
config.unable_create_safe_config_lock_directory=无法创建安全配置锁目录
config.unable_open_config_lock=无法打开配置锁
config.timed_out_waiting_config_read_lock=等待配置读取锁超时
config.config_must_readable_regular_file_refusing_continue=配置必须是可读的普通文件，拒绝使用默认配置继续
config.capbox_distro_empty_falling_back_alpine=CAPBOX_DISTRO 为空，回退 alpine
config.capbox_net_must_none_restricted_open_host_2=CAPBOX_NET 只能是 none / restricted / open（host 为 open 的别名；当前: '{net}'）。拒绝回退到 open
config.persistent_allow_old_bwrap_requires_yes_audit=持久放行旧版 bwrap 需要 --yes（会写入审计日志；doctor 仍为 FAIL）
config.unable_write_old_bwrap_allow_audit_record=无法写入旧版 bwrap 放行审计，已撤销 CAPBOX_ALLOW_OLD_BWRAP
cred.unknown_secret_subcommand=未知 secret 子命令: {arg}
cred.failed_prepare_credentials_session=凭据会话准备失败
daemon.launch_module_incomplete_unified_bwrap_security_gate=启动模块不完整：缺少统一 bwrap 安全门禁
daemon.launch_module_incomplete_lib_launch_sh_missing=启动模块不完整：缺少 lib/launch.sh
daemon.daemon_request_command_empty=daemon_request: 命令为空
daemon.daemon_container_not_running_start_first_dsh=守护容器未运行；请先以 DSH 后台任务方式启动: capbox up
daemon.daemon_container_stopping_draining_flight_tasks_not=守护容器正在停止（排空在跑任务），暂不接受新请求；请稍后重试或重新 capbox up
daemon.unable_write_request_file=无法写入请求文件: {reqf}
daemon.unable_submit_request=无法投递请求: {reqf}
daemon.guest_command_timed_out_s=容器内命令超时（{timeout_s}s）
daemon.daemon_container_stopped_while_command_running_heartbeat=守护容器在命令执行期间已停止（心跳失联），请求被放弃
daemon.unable_build_daemon_container_bwrap_arguments_rc=无法构造守护容器 bwrap 参数（rc={brc}）
daemon.daemon_container_bwrap_arguments_empty=守护容器 bwrap 参数为空
daemon.capbox_up_systemd_requires_systemd_run=capbox up --systemd 需要 systemd-run
daemon.capbox_up_systemd_requires_systemctl=capbox up --systemd 需要 systemctl
daemon.user_systemd_unavailable_systemctl_user_has_no=用户 systemd 不可用（systemctl --user 没有 bus）。改用活得更久的任务跑 capbox up，或在登录会话里启用 lingering
daemon.systemd_unit_service_already_running_workingdirectory_which=systemd 单元 {unit}.service 已在运行，但 WorkingDirectory={wd}，不是本工作区 {workspace}
daemon.systemd_unit_service_already_running=systemd 单元 {unit}.service 已在运行
daemon.capbox_executable_not_found_cannot_hand_off=找不到 capbox 可执行文件，无法交给 systemd
daemon.handed_off_systemd_user_unit_service_detached=交给 systemd --user 单元 {unit}.service（脱离当前进程树）
daemon.systemd_run_failed=systemd-run 失败
daemon.unit_submitted_inspect_systemctl_user_status_service=单元已提交。查看: systemctl --user status {unit}.service
daemon.stop_capbox_down=停止: capbox down
daemon.up_net_requires_mode_none_restricted_open=up: --net 需要模式 none|restricted|open
daemon.up_unknown_option=up: 未知选项 {arg}
daemon.missing_server_script_lib_guest_daemon_sh=缺少服务端脚本: {dir}/lib/guest/daemon.sh
daemon.daemon_container_already_running_pid_no_need=守护容器已在运行（pid {pid}），无需重复启动
daemon.unable_build_bwrap_command=无法构造 bwrap 命令
daemon.starting_daemon_container_rootfs=启动守护容器（rootfs={rootfs}）
daemon.got_termination_signal_asking_daemon_container_shut=收到终止信号，正在通知守护容器优雅退出…
daemon.idmap_failed_start_daemon_container=idmap 启动守护容器失败：{detail}
daemon.restricted_daemon_container_network_bridge_not_ready=restricted：守护容器网络桥未就绪（见 {path}）
daemon.restricted_daemon_container_allowlist_proxy_bridge_ready=restricted：守护容器 allowlist 代理桥已就绪
daemon.got_termination_signal_waiting_daemon_container_exit=收到终止信号，正在等待守护容器退出…
daemon.daemon_container_ready_guest_pid_hostname=守护容器就绪（容器内 pid {pid}，hostname {hostname}）
daemon.ipc_directory=IPC 目录: {daemon_dir}
daemon.stop_capbox_down_end_background_task_hosts=停止: capbox down（或结束承载本进程的后台任务）
daemon.daemon_container_failed_start_exit_recent_logs=守护容器启动失败（退出码 {brc}），最近日志：
daemon.daemon_container_did_not_write_daemon_json=守护容器在 20s 内未写出 daemon.json，继续等待（日志: {logf}）
daemon.new_instance_has_taken_over_iid_keeping=检测到新实例已接管（iid {cur_iid}…），保留其状态文件
daemon.daemon_container_stopped_exit=守护容器已停止（退出码 {rc}）
daemon.down_unknown_option=down: 未知选项 {arg}
daemon.stopping_systemd_unit_service=停止 systemd 单元 {unit}.service
daemon.orphan_server_detected_fresh_heartbeat_no_daemon=检测到孤儿服务端（有新鲜心跳但缺少 daemon.json）；尝试通知它优雅退出
daemon.orphan_server_did_not_exit_within_10s=孤儿服务端未在 10s 内退出（可能版本过旧、不支持 self-heal）
daemon.suggestion_end_tty_job_hosts_delete_hb=建议：结束承载它的 TTY/job，或删除 {daemon_dir}/hb 后重试
daemon.orphan_server_has_exited=孤儿服务端已退出
daemon.stale_state_files_found_daemon_process_gone=发现陈旧的状态文件（守护进程已不在），已清理
daemon.daemon_container_not_running=守护容器未运行
daemon.stopping_daemon_container_guest_pid=正在停止守护容器（容器内 pid {pid}）
daemon.unable_write_ctl_stop=无法写入 {daemon_dir}/ctl/stop
daemon.server_did_not_acknowledge_stop_request_within=服务端 {noack}s 内未响应停止请求（可能已崩溃），直接清理状态文件
daemon.daemon_container_stopped=守护容器已停止
daemon.daemon_container_did_not_exit_within_s=守护容器未在 {limit}s 内退出；清理状态文件
daemon.cannot_force_kill_across_pid_namespace_container=（跨 PID namespace 无法强制 kill，容器会随承载它的后台任务一并结束）
daemon.logs_unknown_option=logs: 未知选项 {arg}
daemon.logs_n_must_non_negative_integer=logs: -n 必须是非负整数
daemon.no_daemon_container_logs_yet_does_not=暂无守护容器日志（{logf} 不存在）
fs.fs_path_must_not_absolute=FS 路径不能是绝对路径: {p}
fs.fs_path_must_not_contain=FS 路径禁止 ..: {p}
fs.fs_path_must_not_contain_empty_segments=FS 路径禁止空段: {p}
fs.fs_path_contains_illegal_characters=FS 路径含非法字符: {p}
fs.fs_binds_entry_must_host_guest_path=FS_BINDS 项格式必须是 host:/guest/path:ro|rw（当前: {spec}）
fs.guest_path_must_not_contain=guest 路径禁止 ..
fs.refusing_host_bind_outside_workspace_only_paths=拒绝工作区外宿主 bind: {_fs_bind_host}（只允许 CAPBOX_WORKSPACE 内）
fs.capbox_rootfs_ro_must_0_1=CAPBOX_ROOTFS_RO 只能是 0/1
fs.unable_create_overlay_directories=无法创建 overlay 目录
fs.rootfs_ro_1_overlay_unavailable_root_will=ROOTFS_RO=1 但 overlay 不可用：根只读挂载，写入 / 会失败（/tmp /run 仍为 tmpfs）
fs.invalid_fs_binds=FS_BINDS 非法: {part}
fs.fs_binds_cannot_mount_onto_logs_audit=FS_BINDS 不能挂到 logs/ 上（审计日志必须保持只读）: {_fs_bind_guest}
fs.unable_normalize_fs_binds_host_path=无法规范化 FS_BINDS 宿主路径: {_fs_bind_host}
fs.invalid_snapshot_name=快照名非法
fs.snapshot_created_sha256=快照已创建: {out} (sha256={sum})
fs.snapshot_does_not_exist=快照不存在: {name}
fs.snapshot_verification_failed=快照校验失败: {arch}
fs.snapshot_contents_missing=快照内容缺少 {name}
fs.restore_failed_rollback_attempted=恢复失败，已尝试回退
fs.restored_snapshot=已从快照恢复: {name}
fs.deleted_snapshot=已删除快照 {name}
fs.snapshot_unknown_subcommand=snapshot: 未知子命令 {sub}
idmap.invalid_uid_gid_mapping_segment_expected_guest=UID/GID 映射段非法: '{part}'（需要 guest:host:count）
idmap.newuidmap_failed_pid_spec=newuidmap 失败（pid={pid} spec={uid_spec}）
idmap.unable_write_proc_setgroups_will_still_try=无法写 /proc/{pid}/setgroups={sg}（将继续尝试 newgidmap）
idmap.newgidmap_failed_pid_spec=newgidmap 失败（pid={pid} spec={gid_spec}）
idmap.exec_uid_must_number_0_4294967295_got=EXEC_UID 必须是 0..4294967295 的数字（当前: {uid}）
idmap.exec_gid_must_number_0_4294967295_got=EXEC_GID 必须是 0..4294967295 的数字（当前: {gid}）
idmap.idmap_failed_get_child_pid_bwrap_info=idmap：未能从 bwrap --info-fd 取得 child-pid
idmap.idmap_background_mapping_start_failed_see=idmap：后台启动映射失败（见 {logf}）
idmap.idmap_after_map_hook_failed=idmap：after_map hook 失败
image.extracting_zst_requires_zstd=解包 zst 需要 zstd
image.refusing_write_image_contents_symlink=拒绝把镜像内容写入符号链接: {cur}/{part}
image.cache_target_not_directory=缓存目标不是目录: {cur}/{part}
image.cache_tree_contains_symlink_refusing_write_rootfs=缓存树含符号链接，拒绝写入 rootfs
image.invalid_image_name=镜像名非法
image.exported=已导出: {out}
image.sha256=SHA256: {sum}
image.image_does_not_exist=镜像不存在: {name}
image.missing_sha256=缺少 {arch}.sha256
image.sha256_mismatch_expect_got=SHA256 不匹配: expect={expect} got={got}
image.image_import_unknown_option=image import: 未知选项 {arg}
image.import_target_path_symlink=导入目标路径是符号链接
image.unable_create_extract_directory=无法创建解包目录
image.extract_directory_not_real_directory=解包目录不是真实目录
image.failed_extract_import_archive=导入归档解包失败
image.import_archive_has_no_root_directory=导入归档无根目录
image.import_root_directory_escaped_extract_directory=导入根目录越出解包目录
image.import_target_already_exists=导入目标已存在
image.unable_place_import_directory=无法放置导入目录
image.import_result_not_real_directory=导入结果不是真实目录
image.imported_sidecar_path_current_rootfs_not_replaced=已导入到旁路: {target}（未替换当前 rootfs）
image.current_rootfs_not_real_directory_refusing_force=当前 rootfs 不是真实目录，拒绝 --force
image.backup_path_already_exists=备份路径已存在: {bak}
image.unable_move_current_rootfs_aside=无法挪开当前 rootfs
image.replaced_current_rootfs_force_old_tree=已 --force 替换当前 rootfs；旧树在 {bak}
image.replace_failed=替换失败
image.replace_current_rootfs_capbox_image_import_force=如需替换当前 rootfs: capbox image import {name} --force
image.image_lock_too_many_arguments=image lock: 参数过多
image.image_lock_save_show_verify_restore=image lock: save|show|verify|restore
image.offline_cache=离线缓存: {out} ({sum})
image.usage_image_cache_restore_archive=用法: image cache restore ARCHIVE
image.cache_verification_failed=缓存校验失败
image.unable_create_cache_staging_directory=无法创建缓存暂存目录
image.failed_extract_cache_archive=缓存归档解包失败
image.cache_archive_does_not_contain=缓存归档没有 {rel}
image.refusing_write_cache_rootfs=拒绝把缓存写入 rootfs
image.restored_offline_package_cache_rootfs=已恢复离线包缓存到 rootfs
image.image_cache_save_restore_path=image cache: save|restore|path
image.image_unknown_subcommand=image: 未知子命令 {sub}
landlock.capbox_landlock_must_off_got=CAPBOX_LANDLOCK 只能是 on 或 off（当前: {v}）
landlock.missing_lib_guest_capbox_landlock_c=缺少 lib/guest/capbox-landlock.c
landlock.landlock_helper_symlink=Landlock helper 是符号链接: {bin}
landlock.capbox_landlock_requires_host_gcc_static_build=CAPBOX_LANDLOCK 需要宿主 gcc -static 来构建 helper
landlock.unable_create_temporary_file_landlock_build=无法创建 Landlock 构建临时文件
landlock.failed_build_capbox_landlock_gcc_static_required=构建 capbox-landlock 失败（需要 gcc -static）: {err}
landlock.unable_install_capbox_landlock=无法安装 capbox-landlock: {bin}
landlock.capbox_landlock_not_executable=capbox-landlock 不可执行: {bin}
landlock.unable_create_landlock_rules_file=无法创建 Landlock 规则文件
landlock.failed_write_landlock_rules=写入 Landlock 规则失败
landlock.landlock_enabled_launch_command_has_no_bwrap=Landlock 已启用，但启动命令里没有 bwrap
landlock.landlock_enabled_bwrap_arguments_missing_command_separator=Landlock 已启用，但 bwrap 参数缺少命令分隔符 --
landlock.landlock_enabled_there_no_guest_command=Landlock 已启用，但没有容器内命令
launch.capbox_net_invalid_net_sh_not_loaded=CAPBOX_NET 非法（{net}），且 net.sh 未加载；拒绝当作 open
launch.exec_uid_exec_gid_must_numbers_0=EXEC_UID/EXEC_GID 必须是 0..4294967295 的数字（当前 uid={_eu} gid={_eg}）
net.capbox_net_restricted_requires_non_empty_capbox=CAPBOX_NET=restricted 需要非空 CAPBOX_NET_ALLOW（逗号分隔域名或 IP）
net.capbox_net_allow_contains_illegal_characters=CAPBOX_NET_ALLOW 含非法字符: {part}
net.capbox_net_allow_empty_after_parsing=CAPBOX_NET_ALLOW 解析后为空
net.capbox_net_restricted_missing_prerequisites=CAPBOX_NET=restricted 缺少前置: {miss}
net.restricted_proxy_process_exited_see=restricted 代理进程退出，见 {path}
net.restricted_proxy_start_timed_out=restricted 代理启动超时
net.unable_enter_container_netns_child=无法进入容器 netns（child={child}）
net.proxy_sock_does_not_exist=代理 sock 不存在: {sock}
net.restricted_bridge_process_exited_see=restricted 桥接进程退出，见 {path}
net.restricted_bridge_start_timed_out=restricted 桥接启动超时
net.restricted_argv_has_no_bwrap_cannot_inject=restricted：argv 里没有 bwrap，无法注入 --info-fd
net.net_run_bwrap_oneshot_missing_command=_net_run_bwrap_oneshot: 缺少命令
net.unable_build_bwrap_arguments=无法构造 bwrap 参数
net.restricted_failed_get_child_pid_bwrap_info=restricted：未能从 bwrap --info-fd 取得 child-pid
net.invalid_publish_entry_expected_host_guest_host=PUBLISH 项非法（期望 HOST:GUEST 或 HOST:IP:GUEST）: {item}
net.publish_net_open_shares_host_network_so=PUBLISH={raw}：NET=open 共享宿主网络，guest 端口已在宿主可见（无额外转发；不声称出站过滤）
net.publish_under_none_restricted_requires_python3=PUBLISH 在 none/restricted 下需要 python3
net.publish_under_none_restricted_requires_nsenter=PUBLISH 在 none/restricted 下需要 nsenter
net.publish_forwarder_not_ready_yet_may_still=PUBLISH forwarder 尚未就绪（可能仍在等服务 netns）；见 {pd}/forward.log
net.publish_127_0_0_1_guest=PUBLISH 127.0.0.1:{_pub_host_port} → guest {_pub_guest_addr}:{_pub_guest_port}
pkglock.package_lock_not_saved=包锁未保存
recipe.recipe_unknown_key=recipe 未知键: {key}
recipe.recipe_rejected_double_quoted_value_containing_expansion=recipe 拒绝含展开符的双引号值: {key}
recipe.recipe_rejected_unsafe_bare_value=recipe 拒绝不安全的裸值: {key}
recipe.recipe_file_does_not_exist=recipe 文件不存在: {hint}
recipe.recipe_line_invalid_only_key_value_known=recipe 第 {number} 行无效（只接受已知键的 KEY=value）
recipe.recipe_duplicate_key_line=recipe 重复键: {_recipe_key}（第 {number} 行）
recipe.recipe_init_must_boolean=recipe INIT 只能是布尔值
recipe.usage_capbox_recipe_check_apply_show_file=用法: capbox recipe <check|apply|show> [FILE]
recipe.recipe_not_found_tried_capbox_recipe_capbox=未找到 recipe（试 capbox.recipe 或 .capbox/recipe.env）
recipe.locked_requires_lock_file=--locked 需要锁文件
recipe.recipe_unknown_option=recipe 未知选项: {arg}
recipe.recipe_accepts_only_one_file=recipe 只接受一个文件
recipe.applying_recipe=应用配方: {f}
recipe.recipe_rootfs_not_ready_running_init=recipe: rootfs 未就绪，执行 init
recipe.cmd_init_unavailable=cmd_init 不可用
recipe.recipe_rootfs_already_ready_skipping_download=recipe: rootfs 已就绪，跳过下载
recipe.recipe_installing_packages=recipe: 安装软件包: {pkgs}
recipe.cmd_pkg_unavailable=cmd_pkg 不可用
recipe.recipe_applied=配方应用完成
res.capbox_cgroup_root_unavailable=CAPBOX_CGROUP_ROOT={path} 不可用：{find_out}
res.memory_max_could_not_written_cgroup_memory=MEMORY_MAX={value} 无法写入 cgroup memory.max（未应用；leaf 无控制器或不允许写）
res.unable_parse_memory_max=MEMORY_MAX 无法解析: {value}
res.pids_max_could_not_written_cgroup_pids=PIDS_MAX={value} 无法写入 cgroup pids.max（未应用；不会用 RLIMIT_NPROC 冒充）
res.pids_max_must_positive_integer_got=PIDS_MAX 必须是正整数（当前: {value}）
res.cpu_max_could_not_written_cgroup_cpu=CPU_MAX={value} 无法写入 cgroup cpu.max（未应用）
res.unable_parse_cpu_max_supports_50_quota=CPU_MAX 无法解析: {value}（支持 50% 或 'quota period'）
res.disk_max_cleanup_failed_leaving_will_not=DISK_MAX 清理失败，保留 {base}（未对仍挂载的目录做无特权 rm）
res.unable_parse_disk_max=DISK_MAX 无法解析: {value}
res.capbox_resources_mode_require_following_limits_cannot=CAPBOX_RESOURCES_MODE=require：以下限额无法精确兑现: {missing}
res.cpu_max_not_applied=CPU_MAX={value} 未应用：{detail}
res.pids_max_not_applied_cgroup_pids_required=PIDS_MAX={value} 未应用：需要 cgroup pids（拒绝使用 RLIMIT_NPROC）
res.capbox_cgroup_root_cannot_honor_cgroup_limits=CAPBOX_CGROUP_ROOT={path} 无法兑现 cgroup 限额：{detail}
res.memory_max_require_mode_refuses_prlimit_fallback=MEMORY_MAX={value}：require 模式拒绝 prlimit 降级（不是 cgroup memory.max）
res.memory_max_fell_back_prlimit_rlimit_virtual=MEMORY_MAX={value} 降级为 prlimit RLIMIT_AS={bytes}（虚拟地址空间近似，**不是** cgroup memory.max）
res.memory_max_not_applied_no_cgroup_no=MEMORY_MAX={value} 未应用：无 cgroup 且无 prlimit/无法解析
res.disk_max_not_applied=DISK_MAX={value} 未应用：{detail}
rootfs.unsupported_cpu_architecture_x86_64_aarch64_required=不支持的 CPU 架构: {arch}（需要 x86_64 或 aarch64）
rootfs.missing_rootfs_checksum_file=缺少 rootfs 校验和文件: {file}
rootfs.rootfs_sha256_txt_has_no=rootfs-sha256.txt 没有 {key}
rootfs.verifying_rootfs_requires_sha256sum=校验 rootfs 需要 sha256sum
rootfs.unsupported_distro_supported=不支持的发行版: {distro}（支持: {distros}）
rootfs.unable_create_cache_directory=无法创建缓存目录: {cache_dir}
rootfs.using_cached_image=使用已缓存镜像: {dst}
rootfs.cached_image_failed_sha256_re_downloading=缓存镜像未通过 SHA256，重新下载: {dst}
rootfs.forcing_re_download_removing_old_cache=强制重新下载，删除旧缓存: {dst}
rootfs.downloading_rootfs_source=下载 {distro} rootfs（源 {n}/{total}）: {u}
rootfs.download_complete_sha256_checked=下载完成: {dst}（{size}，SHA256 已核对）
rootfs.downloaded_file_failed_gzip_sha256_checks_trying=下载的文件未通过 gzip/SHA256 校验，尝试下一个源
rootfs.download_failed=下载失败: {u}
rootfs.all_image_mirrors_failed_you_can_download=所有镜像源都下载失败；可手动下载后放到 {dst}，或用 --from <本地路径|URL>
rootfs.tarball_does_not_exist=tarball 不存在: {tarball}
rootfs.unable_create_directory=无法创建目录: {parent}
rootfs.unable_create_staging_directory=无法创建暂存目录: {stage}
rootfs.extracting_rootfs=解包 rootfs 到 {dest}
rootfs.extract_failed=解包失败: {tarball}
rootfs.extract_result_has_no_bin_sh_image=解包结果不含 /bin/sh，镜像可能不完整: {tarball}
rootfs.unable_replace_existing_rootfs=无法替换已存在的 rootfs: {dest}
rootfs.unable_put_rootfs_place=无法放置 rootfs: {dest}
rootfs.rootfs_ready=rootfs 就绪: {dest}
rootfs.refusing_rootfs_path=拒绝 rootfs 路径中的 . 或 ..: {parent}
rootfs.refusing_follow_symlink=拒绝跟随符号链接: {cur}
rootfs.path_component_not_directory=路径组件不是目录: {cur}
rootfs.refusing_relative_rootfs_path=拒绝相对 rootfs 路径: {dest}
rootfs.refusing_write_file_onto_directory=拒绝把文件写入目录: {dest}
rootfs.refusing_follow_symlink_when_writing=拒绝跟随符号链接写入: {dest}
rootfs.capbox_mirror_none_skipping_mirror_injection=CAPBOX_MIRROR=none，跳过镜像源注入
rootfs.rootfs_does_not_exist_skipping_mirror_injection=rootfs 不存在，跳过镜像源注入: {rootfs}
rootfs.mirror_url_empty_skipping_injection_check_capbox=镜像源 URL 为空，跳过注入（检查 CAPBOX_MIRROR_{distro_uc}）
rootfs.wrote_apk_repositories_v3_24=已写入 apk 镜像源: {url}/v3.24/{main,community}
rootfs.wrote_apt_sources_suite=已写入 apt 镜像源: {url}（suite={suite}）
rootfs.unknown_distro_skipping_mirror_injection=未知发行版，跳过镜像源注入: {distro}
rootfs.rootfs_not_executable_skipping_first_boot=rootfs 不可执行，跳过首次引导
rootfs.running_first_boot_bootstrap=运行首次引导（bootstrap）
rootfs.bootstrap_returned_not_fatal_rootfs_still_usable=bootstrap 返回 {rc}（不致命，rootfs 仍可使用）
rootfs.first_boot_complete=首次引导完成
rootfs.init_unknown_option=init: 未知选项 {arg}
rootfs.agent_trusted_cannot_together=--agent 与 --trusted 不能同时使用
rootfs.unsupported_distro_supported_alpine_ubuntu=不支持的发行版: {distro}（支持: alpine / ubuntu）
rootfs.bootstrap_unknown_option=bootstrap: 未知选项 {arg}
rootfs.scaffold_implementation_unavailable=scaffold 实现不可用
rootfs.next_capbox_init_distro=下一步: capbox init --distro {distro}
rootfs.agent_preset_security_profile_untrusted_net_none=agent 预设: SECURITY_PROFILE=untrusted NET=none IDMAP=off RESOURCES_MODE=require
rootfs.resource_limits_must_set_separately_via_memory=资源限额需另设 MEMORY_MAX/CPU_MAX/PIDS_MAX；配置的限额无法兑现时拒绝启动
rootfs.untrusted_hides_ssh_gnupg_aws_azure_kube=untrusted 会遮盖工作区内的 .ssh .gnupg .aws .azure .kube .docker
rootfs.pkg_install_pkg_update_will_network_other=pkg install 与 pkg update 会出网。其它命令默认无网络
rootfs.one_shot_network_grant_capbox_exec_net=当次要出网: capbox exec --net restricted -- CMD（需先写 CAPBOX_NET_ALLOW）或 --net open
rootfs.allowlist_example_com_allows_only_ports_80=allowlist：example.com 只放行该主机的 80/443；子域写 *.example.com；任意端口加 :* （例 github.com:22）
rootfs.explicit_rootfs_matches_official_sha256=显式 rootfs 与官方 SHA256 一致
rootfs.explicit_tarball_does_not_match_official_sha256=显式 --from 的 tarball 与官方 SHA256 不一致，按你指定的来源接受（官方下载路径不会这样）
rootfs.initializing_capbox_distro=初始化 CapBox 发行版: {distro}
rootfs.rootfs_already_exists_skipping_download_extract=rootfs 已存在，跳过下载与解包: {rootfs}
rootfs.downloading_specified_url=从指定 URL 下载: {from}
rootfs.download_failed_2=下载失败: {from}
rootfs.downloaded_file_not_valid_gzip_tarball=下载的文件不是有效的 gzip tarball: {from}
rootfs.local_tarball_does_not_exist=本地 tarball 不存在: {from}
rootfs.not_valid_gzip_tarball=不是有效的 gzip tarball: {from}
rootfs.unable_obtain_rootfs_image=无法获取 rootfs 镜像
rootfs.unable_remove_old_rootfs=无法删除旧 rootfs
rootfs.rootfs_incomplete_missing_executable_bin_sh=rootfs 不完整（缺可执行 /bin/sh）: {rootfs}
rootfs.mirror_injection_failed_you_can_rerun_capbox=镜像源注入失败（可稍后重跑 capbox init）
rootfs.proxy_file_injection_failed_did_not_follow=代理文件注入失败（未跟随符号链接写入）
rootfs.unable_write_capbox_release=无法写入 capbox-release
rootfs.drop_priv_helper_not_ready_exec_uid=drop-priv helper 未就绪（{detail}）；exec --uid 可能失败
rootfs.done=完成: {rootfs}（{size}）
rootfs.next_capbox_exec_id_u_should_print=下一步: capbox exec -- id -u     # 应在容器内输出 0
sandbox.sandbox_bwrap_cmd_unknown_mode_expected_oneshot=sandbox_bwrap_cmd: 未知模式 {mode}（应为 oneshot 或 daemon）
sandbox.rootfs_missing_unusable_run_capbox_init_first=rootfs 不存在或不可用: {rootfs}；请先运行 capbox init
sandbox.unable_build_bwrap_arguments_rootfs_missing=无法构造 bwrap 参数（rootfs 缺失）
sandbox.exec_net_requires_mode_none_restricted_open=exec: --net 需要模式 none|restricted|open
sandbox.exec_unknown_option_separate_guest_command=exec: 未知选项 {arg}（用 -- 分隔容器内命令）
sandbox.exec_missing_command_run_e_g_capbox=exec: 缺少要执行的命令，例如: capbox exec -- id -u
sandbox.exec_timeout_must_non_negative_integer_number=exec: --timeout 必须是非负整数秒（当前: {timeout_s}）
sandbox.exec_daemon_uses_network_chosen_capbox_up=exec: --daemon 用的是 capbox up 时的网络；要改网络请重新 up --net
sandbox.exec_profile_must_compat_untrusted_strict_got=exec: --profile 必须是 compat|untrusted|strict（当前: {profile_override}）
sandbox.exec_unable_resolve_user_check_rootfs_etc=exec: 无法解析 --user {user_override}（检查 rootfs /etc/passwd）
sandbox.exec_uid_must_non_negative_integer_got=exec: --uid 必须是非负整数（当前: {uid_override}）
sandbox.exec_gid_must_non_negative_integer_got=exec: --gid 必须是非负整数（当前: {gid_override}）
sandbox.exec_guest_directory_does_not_exist=exec: 容器内目录不存在: {want_cwd}
sandbox.exec_guest_directory_does_not_exist_workspace=exec: 容器内目录不存在: /workspace/{want_cwd}
sandbox.guest_command_timed_out_s_terminated=容器内命令超时（{timeout_s}s），已终止
sandbox.persistent_container_feature_unavailable_missing_library_dae=常驻容器功能不可用：缺少库文件 {lib_dir}/daemon.sh
sandbox.shell_net_requires_mode_none_restricted_open=shell: --net 需要模式 none|restricted|open
sandbox.shell_unknown_option=shell: 未知选项 {arg}
sandbox.shell_daemon_uses_network_chosen_capbox_up=shell: --daemon 用的是 capbox up 时的网络；要改网络请重新 up --net
sandbox.cp_empty_path=cp: 空路径: '{spec}'
sandbox.cp_unknown_option=cp: 未知选项 {arg}
sandbox.usage_capbox_cp_src_dst=用法: capbox cp SRC DST
sandbox.refused_container_side_source_path_escapes_rootfs=拒绝：容器侧源路径越界 rootfs: {src_path}
sandbox.refused_container_side_destination_path_escapes_rootfs=拒绝：容器侧目标路径越界 rootfs: {dst_path}
sandbox.source_file_does_not_exist_container=源文件在容器内不存在: {src_path}
sandbox.source_file_does_not_exist=源文件不存在: {src_abs}
sandbox.copy_failed=拷贝失败: {err}
sandbox.ls_unknown_option=ls: 未知选项 {arg}
sandbox.guest_directory_does_not_exist=容器内目录不存在: {path}
sandbox.usage_capbox_ps=用法: capbox ps
sandbox.ps_unavailable_falling_back_reading_proc=ps 不可用，退化为读取 /proc
sandbox.suspicious_package_name_rejected=可疑包名，已拒绝: {p}
sandbox.pkg_install_missing_package_name=pkg install: 缺少包名
sandbox.invalid_package_name=包名非法
sandbox.pkg_remove_missing_package_name=pkg remove: 缺少包名
sandbox.pkg_list_invalid_filter_pattern=pkg list: 过滤模式非法: {pat}
sandbox.pkg_unknown_subcommand_install_remove_update_list=pkg: 未知子命令 {sub}（install|remove|update|list）
sandbox.pkg_returned_dpkg_audit_logs_above_judge=pkg {sub} 返回 {rc}（请结合上方 dpkg audit / 日志判断）
sandbox.pkg_returned_chown_warnings_common_under_single=pkg {sub} 返回 {rc}（单 UID 下 chown 告警常见；请看 dpkg audit 与可执行文件）
sandbox.pkg_session_network_none_command_using_one=pkg {sub}: 会话网络是 none，本次命令单独出网
sandbox.dpkg_has_packages_not_fully_configured_state=dpkg 存在未完成配置的包（状态含 U/F，例如 iU/iF）：
sandbox.not_hidden_success_check_capbox_idmap_postinst=这不是被掩盖的成功：请检查 CAPBOX_IDMAP 与 postinst 日志
sandbox.dpkg_audit_reported_unconfigured_packages=dpkg --audit 报告有未配置的包
sandbox.dpkg_audit_no_leftover_iu=dpkg audit：无 iU/iF 残留
sandbox.ls_rootfs_no_arguments_expected=ls-rootfs: 不需要参数
sec.capbox_security_profile_must_compat_untrusted_strict=CAPBOX_SECURITY_PROFILE 只能是 compat|untrusted|strict（当前: {value}）
sec.security_profile_requires_python3_libseccomp_generate_seccom=安全档 {profile} 需要 python3 + libseccomp 生成 seccomp BPF
sec.missing_lib_seccomp_gen_py=缺少 lib/seccomp-gen.py
sec.seccomp_bpf_generation_failed_see_err_refusing=seccomp BPF 生成失败（见 {out}.err）；拒绝伪实现
sec.seccomp_bpf_empty_refusing_continue=seccomp BPF 为空，拒绝继续
sec.unable_open_seccomp_bpf=无法打开 seccomp BPF: {bpf}
svc.invalid_service_name=服务名非法: {arg}
svc.invalid_service_name_2=服务名非法: {name}
svc.service_definition_does_not_exist=服务定义不存在: {f}
svc.service_value_contains_illegal_expansion_characters=服务 {name}: {key} 值含非法展开符
svc.service_value_contains_newline=服务 {name}: {key} 值含换行
svc.service_missing_cmd=服务 {name}: 缺少 CMD
svc.service_diagnostics=服务 '{name}' 诊断: {reason}

svc.user_does_not_exist_in_guest_passwd=USER 不存在于 {passwd}
svc.require_idmap_but_multi_uid_mapping_unavailable=REQUIRE_IDMAP=1 但多 UID 映射不可用
svc.require_idmap_but_current_status=REQUIRE_IDMAP=1 但当前为 {status}
svc.restricted_prerequisites_not_met=restricted 前置不满足
svc.failed_start_restricted_proxy=restricted 代理启动失败
svc.guest_cannot_see_bridge_ready_path=guest 看不到 bridge ready 路径
svc.unable_create_run_dir=无法创建 {rd}
svc.service_run_directory_is_symlink=服务运行目录是符号链接
svc.unable_build_bwrap_args_rc_often_old_bwrap=无法构造 bwrap 参数（rc={rc}；常见原因：bwrap 版本不足）
svc.unable_build_bwrap_args=无法构造 bwrap 参数
svc.security_profile_could_not_be_applied=安全档无法应用
svc.resource_limits_could_not_be_applied=资源限额无法应用
svc.landlock_could_not_be_enabled=Landlock 未能启用
svc.capbox_idmap_on_but_multi_uid_mapping_unavailable=CAPBOX_IDMAP=on 但多 UID 映射不可用
svc.unable_inject_info_fd=无法注入 --info-fd
svc.idmap_start_failed=idmap 启动失败
svc.restricted_service_network_bridge_not_ready=restricted 服务网络桥未就绪
svc.service_not_ready_or_start_failed_see_logs=服务未就绪或启动失败（见 service logs）
svc.idmap=  idmap: {status} — {detail}
svc.listening_ports_ss_lntu_head=  监听端口(ss -lntu | head):
svc.msg=    {L}
svc.rootfs_present=  rootfs{d}: 存在
svc.rootfs_missing=  rootfs{d}: 缺失
svc.recent_logs=  最近日志:
svc.service_unknown_subcommand_start_stop_status_logs=service: 未知子命令 {sub}（start|stop|status|logs|list）
svc.depends_has_invalid_service_name=DEPENDS_ON 非法服务名: {d}
svc.dependency_not_running_starting_first=依赖 {d} 未运行，先启动
svc.failed_start_dependency_service=依赖服务 {d} 启动失败
svc.service_not_decimal_number=服务 {who}: {label} 不是十进制数字: {v}
svc.service_outside_32_bit_range=服务 {who}: {label} 超出 32 位范围: {v}
svc.usage_capbox_service_start_name=用法: capbox service start NAME
svc.service_start_unknown_option=service start: 未知选项 {arg}
svc.service_already_running_pid=服务 {name} 已在运行（pid {pid}）
svc.invalid_stop_timeout=STOP_TIMEOUT 非法
svc.invalid_restart_max=RESTART_MAX 非法
svc.invalid_ready_timeout=READY_TIMEOUT 非法
svc.restart_must_no_failure_always=RESTART 只能是 no|on-failure|always
svc.service_unable_resolve_user_guest_passwd=服务 {name}: 无法在 guest passwd 解析 USER={user}
svc.service_invalid_net=服务 {name}: NET 非法: {net}
svc.publish_failed_start_see_logs=PUBLISH 启动失败（见日志）
svc.service_started_supervisor_pid_uid_gid=服务 {name} 已启动（supervisor pid {pid}, uid={uid} gid={gid}）
svc.usage_capbox_service_stop_name=用法: capbox service stop NAME
svc.service_not_running=服务 {name} 未在运行
svc.service_stopped=服务 {name} 已停止
svc.usage_capbox_service_status_name=用法: capbox service status NAME
svc.service_logs_unknown_option=service logs: 未知选项 {arg}
svc.extra_argument=多余参数 {arg}
svc.usage_capbox_service_logs_name=用法: capbox service logs NAME
svc.no_log=无日志: {f}
upgrade.run_capbox_down_before_upgrading=升级前请先 capbox down
upgrade.cancel_wait_all_tasks_before_upgrading=升级前请先取消或等待所有 task
upgrade.run_capbox_service_stop_before_upgrading=升级前请先 capbox service stop {name}
upgrade.found_leftover_state_older_version_stop_services=发现旧版运行记录，请先用旧 CLI 停服并确认没有运行中的旧进程
upgrade.requires_template_directory=--from 需要模板目录
upgrade.upgrade_unknown_argument=upgrade 未知参数: {arg}
upgrade.rollback_does_not_accept=rollback 不接受 --from
upgrade.upgrade_requires_template=upgrade 需要 --from TEMPLATE
common.bwrap_old_details<<
      受影响: CVE-2026-87766 (/oldroot 符号链接逃逸), CVE-2026-41163 (setuid ptrace)
      这些漏洞在沙箱进程启动前触发，--clearenv / fsguard / seccomp 均无法防御
      本检查对 compat、untrusted、strict 同样生效
      升级: sudo apt install --only-upgrade bubblewrap
            若发行版未包含 0.12.0，需从源码或更新的仓库安装
      如确认接受风险，单次允许: capbox --allow-old-bwrap <command>
      持久允许: capbox config set --yes CAPBOX_ALLOW_OLD_BWRAP 1
            （会写入审计日志；doctor 仍为 FAIL）
>>

# doctor report text (_doctor_pass / _doctor_fail / _doctor_warn and *_doctor_report)
doctor.bwrap_installed=bwrap 已安装 ({bwrap})
doctor.bwrap_version_ok=bwrap 版本 {ver}（>= 0.12.0）
doctor.bwrap_below_baseline=bwrap {ver} 低于安全基线 0.12.0
doctor.bwrap_below_allowed_once=bwrap {ver} 低于基线，本次 --allow-old-bwrap 放行（doctor 仍为 FAIL）
doctor.bwrap_below_allowed_persist=bwrap {ver} 低于基线，已被 CAPBOX_ALLOW_OLD_BWRAP 放行（doctor 仍为 FAIL）
doctor.bwrap_unavailable=bwrap 不可用 ({bwrap})；请安装 bubblewrap >= 0.12.0 或设置 CAPBOX_BWRAP
doctor.workspace_dangerous=工作区为 {home} 或 / ({workspace})；会把整棵目录 RW bind 进容器。请用项目内 .capbox/ 或 CAPBOX_ROOT=/path/to/project
doctor.workspace_safe=工作区安全 ({workspace})
doctor.audit_workspace_unsafe=工作区不安全
doctor.userns_ok=userns 全权限 (uid=0, CapEff={caphex})
doctor.userns_probe_failed=userns 全权限探测失败：容器内无法获得 uid0 + 全量 capability（检查内核 unprivileged_userns_clone 与 bwrap 版本）
doctor.userns_not_probed=userns 全权限未探测（bwrap 不可用）
doctor.idmap_module_missing=UID 映射模块未加载（lib/idmap.sh）
doctor.deps_complete=依赖命令齐全 (tar/curl/flock/timeout)
doctor.deps_missing_timeout=缺少 timeout（exec --timeout 将失效），其余依赖齐全
doctor.deps_missing=缺少依赖命令: {cmds}
doctor.rootfs_ready=rootfs 就绪 ({rootfs}, {size})
doctor.rootfs_missing=rootfs 缺失或不可用 ({rootfs})；请运行: capbox init --distro {distro}
doctor.resolv_ready=resolv.conf 已就绪 ({path})
doctor.resolv_missing=resolv.conf 尚未生成（首次 exec 时会自动生成）
doctor.mirror_skipped_none=CAPBOX_MIRROR=none，跳过镜像源连通性检查
doctor.mirror_url_empty=镜像源 URL 为空（检查 CAPBOX_MIRROR_{distro}）
doctor.mirror_reachable=镜像源连通 ({url})
doctor.mirror_unreachable=镜像源不可达 ({url})；检查网络或 CAPBOX_MIRROR 配置
doctor.host_net_ok=宿主网络可用
doctor.host_net_probe_failed=宿主到公网镜像的探测失败（可能是离线环境）
doctor.net_none=CAPBOX_NET=none，容器内无网络（--unshare-net）
doctor.net_restricted_mirror=CAPBOX_NET=restricted：镜像连通性取决于 allowlist 代理（见下方网络模式项）
doctor.missing_curl_skip_net=缺少 curl，跳过网络连通性检查
doctor.socks5_apt_unsupported=socks5 代理下 apt 不原生支持：建议改用 http 代理，或在容器内配置 proxychains
doctor.proxy_configured=代理已配置 ({proxy})
doctor.proxy_unset=代理未配置（直连）
doctor.apk_repos_injected=apk 镜像源已注入
doctor.apk_repos_missing=缺少 {path}（重新运行 capbox init）
doctor.apt_repos_injected=apt 镜像源已注入 ({which})
doctor.apt_repos_missing=缺少 apt 源文件（{sl} 或 {d822}）；重新运行 capbox init
doctor.env_cleared=环境变量已清空（宿主敏感变量不继承；白名单 HOME/PATH 可用）
doctor.env_not_cleared=环境变量未清空或白名单缺失（probe rc={rc} out={out}）；应无条件 bwrap --clearenv 后再 --setenv
doctor.skip_env_old_bwrap=跳过环境清空探测（bwrap 版本低于安全基线）
doctor.skip_env_no_bwrap=跳过环境清空探测（bwrap 不可用）
doctor.skip_env_no_rootfs=跳过环境清空探测（rootfs 或 bwrap 不可用）
doctor.config_preoccupy_no_log=无法定位 guest 侧 logs/audit.jsonl，不能确认只读
doctor.guest_wrote_config=guest 写入了宿主 config.env（缺失/已存在路径未只读保护）
doctor.guest_wrote_services=guest 创建了宿主 services/_doctor_probe.env（services 目录未只读保护）
doctor.guest_wrote_protected=guest 可写受保护配置路径（probe out={out}）
doctor.guest_wrote_audit_log=guest 写入了宿主 logs/audit.jsonl（logs 未只读保护）
doctor.config_preoccupy_ok=配置路径预占生效（缺失/已存在的 config.env、services/ 与 logs/audit.jsonl 均不可被 guest 写入）
doctor.skip_preoccupy_capbox_dir=跳过配置预占探测（CAPBOX_DIR 不在工作区视图内）
doctor.skip_preoccupy_old_bwrap=跳过配置预占探测（bwrap 版本低于安全基线）
doctor.skip_preoccupy_no_bwrap=跳过配置预占探测（bwrap 不可用）
doctor.skip_preoccupy_no_rootfs=跳过配置预占探测（rootfs 或 bwrap 不可用）
doctor.daemon_running=守护容器运行中 (pid {pid})
doctor.daemon_not_running=守护容器未运行（按需用后台任务运行 capbox up）
doctor.summary_baseline_fail=自检结果: 安全基线不满足（退出码 6）；{fails} 项 FAIL，{warns} 项 WARN
doctor.summary_fail=自检结果: {fails} 项 FAIL，{warns} 项 WARN
doctor.summary_pass_with_warns=自检结果: 全部通过（{warns} 项 WARN）
doctor.summary_pass=自检结果: 全部通过
doctor.audit_baseline_fail=安全基线不满足，{fails} 项 FAIL
doctor.audit_fail={fails} 项 FAIL，{warns} 项 WARN
doctor.idmap_multi=UID 映射 multi（{detail}）
doctor.idmap_drop_helper_ok=drop-priv helper（{detail}）
doctor.idmap_drop_helper_unavailable=drop-priv helper 不可用（{detail}）；--uid 将依赖 guest setpriv/python/chpst/su
doctor.idmap_single=UID 映射 single（{detail}）。chown/setgroups/多用户服务会失败
doctor.idmap_blocked_on=UID 映射被阻塞且 CAPBOX_IDMAP=on（{detail}）
doctor.idmap_fallback_single=UID 映射不可用，已回退 single（{detail}）
doctor.idmap_status_unknown=UID 映射状态未知
doctor.cgroup_v2_writable=cgroup v2 可写（{detail}）
doctor.cgroup_v2_no_delegate=cgroup v2 存在但不可委派：{detail}
doctor.cgroup_unavailable=cgroup 不可用：{detail}
doctor.disk_max_honored=DISK_MAX 可兑现：{detail}
doctor.disk_max_not_honored=DISK_MAX 无法兑现：{detail}
doctor.resources_unset=资源限额未配置（MEMORY/CPU/PIDS/DISK 为空）
doctor.resources_mode=RESOURCES_MODE={mode}
doctor.memory_max_set=已配置 MEMORY_MAX={value}
doctor.cpu_max_set=已配置 CPU_MAX={value}
doctor.pids_max_set=已配置 PIDS_MAX={value}
doctor.disk_max_set=已配置 DISK_MAX={value}（guest {guest}）
doctor.disk_guest_path_invalid=DISK_MAX 的 guest 路径非法
doctor.image_dir_present=镜像目录 {path}（约 {n} 个归档）
doctor.image_dir_missing=镜像目录尚未创建（image export 时建立）
doctor.package_lock_present=存在 package.lock
doctor.net_invalid=CAPBOX_NET 非法（{value}）；拒绝当作 open
doctor.net_mode_none=网络模式 none（--unshare-net，容器内无网络）
doctor.net_mode_open=网络模式 open（共享宿主网络；兼容别名 host）
doctor.net_mode_restricted_ok=网络模式 restricted（unshare-net + allowlist 代理；{pre}；ALLOW={allow})
doctor.net_mode_restricted_prereq=网络模式 restricted 但前置未满足（需要 python3、nsenter、非空 CAPBOX_NET_ALLOW）；exec 将失败
doctor.fs_rootfs_ro_overlay_ok=ROOTFS_RO=1 且 overlay 实测可用（写入进入 upper）
doctor.fs_rootfs_ro_overlay_unavailable=ROOTFS_RO=1 但 overlay 不可用：根将只读挂载
doctor.fs_rootfs_ro_off=ROOTFS_RO 未启用（rootfs RW bind，兼容默认）
doctor.fs_hide_binds_ok=FS_HIDE/FS_BINDS 配置校验通过（禁止工作区外 bind）
doctor.fs_hide_binds_invalid=FS_HIDE/FS_BINDS 配置非法
doctor.landlock_invalid=CAPBOX_LANDLOCK 只能是 on 或 off（当前: {value}）
doctor.landlock_off=Landlock 关闭（未设置时 strict 默认开启，compat/untrusted 默认关闭）
doctor.landlock_helper_failed=Landlock 已启用，但无法构建 helper（需要宿主 gcc -static 与 lib/guest/capbox-landlock.c）
doctor.landlock_kernel_unsupported=Landlock 已启用，但内核不支持（需要 5.13+ 且 LSM 已启用）
doctor.landlock_abi=Landlock ABI {abi}（挂载完成之后限制 VFS；不限制 TCP 端口；允许目录之下不能再挖洞）
doctor.security_compat=安全档 compat（默认兼容：全量 capability、无 seccomp；不削弱现有行为）
doctor.security_userns_boundary_compat=userns 边界：guest root ≠ 宿主 root；无 seccomp 时攻击面较大，不可信负载请改 CAPBOX_SECURITY_PROFILE=untrusted|strict
doctor.security_profile_ok=安全档 {profile}（seccomp BPF={bpf}，capability drop，disable-userns={dus}）
doctor.security_idmap_skip_disable_userns=不可信负载不要和多 UID idmap 一起用：已跳过 --disable-userns，guest 仍可嵌套 user namespace。装包可以开 idmap；跑不可信命令请 CAPBOX_IDMAP=off（或单 UID）后再用 untrusted/strict
doctor.security_bpf_failed=安全档 {profile} 但无法生成 seccomp BPF（拒绝伪实现）
doctor.security_need_seccomp_tools=安全档 {profile} 需要 python3 + lib/seccomp-gen.py + libseccomp
doctor.security_userns_boundary_recorded=userns 边界已记录：harden 降低 guest 攻击面，不声称宿主级隔离

# Shared CAPBOX_*_DETAIL / CAPBOX_BWRAP_VERSION_DETAIL / cgroup find-why text
common.bwrap_version_unparseable=无法解析 {bin} --version（需要 >= 0.12.0）
common.bwrap_version_detail_below=bwrap {ver} 低于 0.12.0（发行版撤回的 0.11.x 补丁不算；需要 >= 0.12.0）
idmap.detail_off=CAPBOX_IDMAP=off（强制单 UID）
idmap.detail_missing_helpers=缺少 newuidmap/newgidmap（安装 uidmap 包）；内核仅允许单 UID 自映射
idmap.detail_no_subuid=用户 {user} 在 /etc/subuid 无可用条目
idmap.detail_uid_map_unparseable=CAPBOX_UID_MAP 无法解析: {spec}
idmap.detail_gid_map_unparseable=CAPBOX_GID_MAP 无法解析: {spec}
idmap.detail_tmp_dir_failed=无法创建 idmap 探测临时目录
idmap.detail_probe_file_failed=无法创建 idmap 探测文件
idmap.detail_map_write_failed=newuidmap 存在但写入多行映射失败：{detail}
idmap.drop_helper_missing_src=缺少 capbox-drop-priv.c
idmap.drop_helper_no_gcc=没有 gcc/cc，无法构建静态助手
idmap.drop_helper_gcc_failed=gcc -static 失败: {err}
idmap.drop_helper_ready=静态助手已就绪，可供只读 bind（{bin}）
idmap.drop_helper_missing_after_build=构建后仍缺少助手
res.cgroup_dual_hint=兑现限额需同时满足：(1) 进程自身 cgroup 可写（才能把任务迁入子 cgroup）；(2) 限额根为空且已委派（可 mkdir、写 cgroup.subtree_control 与 memory.max）。可 systemctl --user start capbox.slice，设 CAPBOX_CGROUP_ROOT 指向该 slice，并在可写的 user scope 中运行。
res.detail_no_sys_fs_cgroup=无 /sys/fs/cgroup
res.detail_not_cgroup_v2=非 cgroup v2 统一层级（缺 cgroup.controllers）
res.detail_root_ok_self_not_writable=限额根探针通过（{root}），但进程自身 cgroup 不可写，无法迁入子 cgroup。{hint}
res.detail_cgroup_root_writable=CAPBOX_CGROUP_ROOT={root}（真实探针：subtree_control+memory.max 可写）
res.detail_writable_cgroup_root=可写 cgroup 根: {root}（真实探针：subtree_control+memory.max 可写）
res.detail_cgroup_root_unwritable_fallback=不可写或子 cgroup 缺少可写 memory.max
res.detail_cgroup_root_unusable=CAPBOX_CGROUP_ROOT={root} 不可用：{reason}
res.detail_no_usable_cgroup_parent=无法获得可用 cgroup 父目录（self={self}）；{reason}。控制器有 {controllers}
res.detail_no_usable_cgroup_parent_no_delegate=无法获得可用 cgroup 父目录（self={self}）；{reason}。控制器有 {controllers} 但当前路径无有效委派。{hint}
res.detail_mkdir_evidence=mkdir 证据: {err}
res.find_why_not_dir=不是目录
res.find_why_mkdir_failed=无法 mkdir 子目录: {err}
res.find_why_subtree_control=无法写入 cgroup.subtree_control(+memory): {err}（限额根须为空且已委派；父 cgroup 内有进程时会 EBUSY）。{hint}
res.find_why_no_memory_max=子 cgroup 无 memory.max（父级未能委派 memory）。{hint}
res.find_why_memory_max_unwritable=无法写入子 cgroup memory.max: {err}。{hint}
res.find_why_no_usable_parent=无可用 cgroup 父目录
res.disk_detail_unset=未配置 CAPBOX_DISK_MAX
res.disk_detail_guest_path_invalid=CAPBOX_DISK_GUEST_PATH 非法（必须是绝对路径，且不能含 .. 或 /.）
res.disk_detail_missing_tools=缺少 losetup/mkfs.ext4/mount（需 e2fsprogs + util-linux）
res.disk_detail_no_loop_control=无 /dev/loop-control
res.disk_detail_priv_direct=priv=direct；loop→{guest}（需 mount 权限，非 rootless）
res.disk_detail_priv_sudo=priv=sudo -n；loop→{guest}（需宿主授权，非 rootless）
res.disk_detail_no_priv=无 loop/mount 特权: {lsout}；需要 root/disk 组或 sudo -n（拒绝假装已限额）
res.disk_detail_state_symlink=state/disk 是符号链接，拒绝建立配额盘
res.disk_detail_quota_dir_not_real=配额目录不是真实目录
res.disk_detail_loop_setup_failed=建立 loop 配额盘失败（priv={mode}）
res.disk_detail_no_dashdash=argv 中没有 --，无法把配额盘挂进 guest
