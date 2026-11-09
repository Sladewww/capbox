# 严格包锁

需要宿主 Python **3.10+**。

`image lock save` 生成 schema-1 JSON 锁，记录发行版、架构和完整已安装包/版本集合。空清单、包查询失败或不完整的 dpkg 状态会被拒绝。

```sh
capbox image lock save
capbox image lock show
capbox image lock verify
capbox image lock restore /path/to/package.lock
capbox recipe apply --locked /path/to/package.lock capbox.recipe
```

`verify` 比对当前完整集合：缺包、多余包、版本不符都是错误。`restore` 经 `capbox pkg` 安装精确的 `name=version`，再校验结果。装包时的常规网络例外与 Alpine 脚本兼容过滤仍然生效。

锁定配方应用会在提交配置前检查锁是否满足配方请求的每个包（含显式版本）。版本不可用、发行版/架构不符、锁损坏或版本不匹配都会失败，不会回退到未钉死版本。已有更新包可能阻止包管理器自动降级；失败是显式的。包管理器变更不做事务回滚：恢复前请备份重要 guest 状态。

锁记录包版本，不归档软件源内容，也不钉死宿主内核。要长期可重建，请另留可信软件源快照或 CapBox rootfs 导出。锁恢复成功只验证包身份/版本，不保证任意应用文件内容。

0.3.6 之前的 `package.lock` 文本文件只是清单，没有严格重放契约。`verify`/`restore` 会拒绝它；在你要记录的环境上重新跑 `image lock save`。该文件是数据，从不被 source。
