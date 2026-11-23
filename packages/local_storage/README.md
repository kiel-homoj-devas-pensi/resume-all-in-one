# local_storage

Canonical Resume 的 SQLite/Drift 持久化实现。

- 五张表：`resume_documents`、`resume_versions`、`app_settings`、`agent_runs`、`tool_calls`
- 新版本追加与当前指针更新使用同一事务
- 使用预期当前版本 ID 做乐观并发控制
- Canonical JSON 写入和读取均经过 validation
- 文件数据库在后台 isolate 执行，避免阻塞 Flutter UI
- 默认不输出 SQL 或简历正文日志
- Agent 审计只保存状态和工具元数据，不保存正文、参数、结果或密钥

数据库结构和迁移约束见 `docs/specs/local-storage-schema-v1.md`、`docs/specs/local-storage-schema-v2.md` 与 `docs/specs/local-storage-schema-v3.md`。

生成和验证：

```powershell
dart pub get
dart run build_runner build
dart run drift_dev schema dump lib/src/database.dart drift_schemas
dart analyze
dart test
```

修改表结构时必须递增 `schemaVersion`，保留既有 schema 快照并新增迁移测试。
