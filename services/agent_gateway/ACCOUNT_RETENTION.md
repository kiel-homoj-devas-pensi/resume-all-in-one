# 停用账号普通业务记录清理

本模块处理账号停用后60个自然日到期的普通身份、会话、权益和用量记录。停用当时即清除登录手机号、密码并撤销会话；新的 `account_retirements.deactivated_at_utc` 与停用写在同一事务中，未成功登记不能报告停用成功。到期清理删除普通关联记录及账号本身，不建立保留旧账号ID/手机号摘要的“匿名”对照表。数据库删除不等同于SQLite空闲页、WAL、云备份和供应商副本的即时物理擦除，后者须按各自的备份与恢复流程处理。

原SQLite v8和MySQL v7的迁移定义、摘要保持不变；新的退休登记版本分别为SQLite v9和MySQL v8。迁移仅由明确的维护操作执行。Web进程不自动DDL、不自动回填老记录；不知道停用时间的历史账号仅输出数量并要求核查，不能从注册时间、会话时间或迁移时间猜测，也不能重新起算60日。

配置 `AGENT_GATEWAY_ENABLE_ACCOUNT_RETENTION=true` 要求同时启用已有的同库权益和恢复码结构。受保护生产启动入口已启用此项，升级前必须完成新版本迁移及权限核对，否则新进程拒绝启动。旧进程和生产数据库未因此被本地开发自动改变。开发期未开启此项的旧合成夹具保留原结构兼容；它们不能作为已执行正式留存规则的证据。

## 维护入口

在本服务虚拟环境执行，`PYTHONPATH` 指向本服务 `src`。以下命令默认只读；涉及的数据库路径/DSN、TLS CA和到期配置沿用已配置的运行环境，不能将凭据放进命令行或报告：

```text
python scripts/manage_account_retention.py check
python scripts/manage_account_retention.py migrate --apply --confirmed-target --confirmed-quiescent
python scripts/manage_account_retention.py purge --apply --confirmed-target
```

迁移只接受已验证的SQLite v8或MySQL v7完整结构，已有新结构重复执行会核对并返回。MySQL DDL自动提交；连接/提交结果不明时禁止盲重试，先只读核对。仅允许已中断产生、完全一致且空的未标记退休登记表恢复迁移，其余结构拒绝处理。CLI没有DDL/账号授权功能；数据库所有者另行审核授权后才可启用。

清理默认一次最多扫描100批，每批20个账号，每个账号每批最多清理200个云版本。扫描位置仅保留在进程内，不打印账号ID。受阻账号不会让后面的到期账号永远扫描不到。云版本过多时从最新版本开始按外键关系分批删除，下轮重跑继续；不在Web请求中运行清理，也不在本地开发时注册生产计划任务。上线须将该命令纳入受控的定期维护调度，并对未完成结果和执行失败告警，检查到期积压。实际调度频率和运行证据须在部署时验收，当前不能宣称云端已自动清理。

`status=attention_required`、退出码3包含需继续处理的情况：未知旧停用时间、尚未核实的执行/对账、已记录的有限期合法保留、数据不一致、云版本尚未清完或扫描达到上限。这不是全部清理完成。运行中/`reserved`或`pendingReconciliation`任务不会被当成“未执行”删除，不自动退费、恢复额度或恢复账号；管理人员应及时核查结算，处理后重跑。安全日志、短信预算/发送凭据、请求受理记录、法定委托处理及影响评估记录不由此命令清理，不把60日套给所有类别。

经核实成立的更早删除请求，可由可信的人工处理模块在核验并停用账号后调用 `AccountRetentionWorker.fulfillEarlierDeletion`，不等待60日。该方法不暴露为公开接口，证明摘要不能替代实际核验记录；正在执行/未知任务及具体合法保留须立即人工核查并如实反馈，不能成为无限延期的理由。

`recordRetentionHold` 只供已存在、可核查的法定义务或实际争议使用，必须给出证据摘要和结束时间，不能以假想争议、普通待办或无期限理由设置。它暂停整个账号的本轮删除，因此仅适用于证据已证明整组普通记录确有必要的情况；若实际仅需保留部分记录，先在独立案件/法定记录体系内最小化保全必要部分，再解除此阻挡并删除无必要部分。没有此类事实时不创建保留。超过期限后可继续清理，不能用滚动续期代替范围和期限判断。

## MySQL身份与最小权限

原Web身份只新增 `account_retirements` 的 `SELECT` 及 `INSERT(account_id,deactivated_at_utc)`；不能有此表的`UPDATE`/`DELETE`、DDL或数据库级写授权。启动校验两列INSERT及无额外表/列写权限。`hold_*`只能由适当维护身份按已核查事实设置，Web不可写。

迁移使用 `GATEWAY_DATABASE_MIGRATION_DSN` 的独立维护身份。清理使用 `GATEWAY_DATABASE_RETENTION_DSN` 的专用 `resume_retention...` 身份，主机/端口/库名和服务器身份必须与业务连接一致。CLI先用只读业务连接验证完整结构，再用独立清理连接处理；不增加Web的DELETE权限，也不复用有DDL的迁移身份执行日常清理。

专用清理身份须无激活角色、无授权转授、无库级/全局写授权，精确允许以下13表的`SELECT, DELETE`：`accounts`、`account_sessions`、`subscription_snapshots`、`usage_operations`、`usage_reconciliations`、`cloud_account_state`、`cloud_documents`、`cloud_versions`、`cloud_operations`、`cloud_consents`、`account_privilege_grants`、`account_recovery_codes`、`account_retirements`；另只读 `gateway_schema_migrations`。CLI按实际`SHOW GRANTS`校验，额外INSERT、UPDATE、DDL、其他表或大范围授权都会拒绝。SQLite无法提供等效数据库内角色隔离，须继续使用既有受限目录/进程身份；本地合成验证不替代生产ACL和权限验收。

恢复旧备份后须先核对已办结删除/停用决定并重放清理，禁止将历史备份直接作为重新激活依据。独立结果缓存现有24小时规则、游客/试用身份库、邮件服务和供应商副本另有生命周期，不由此账号库事务宣称同步物理清除。本模块没有发送真实短信、调用模型或执行云端迁移。
