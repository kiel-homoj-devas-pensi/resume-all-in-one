# resume_domain

纯 Dart 领域包，提供：

- Canonical Resume Schema v0.1 实体与严格 JSON round-trip。
- 未知字段保留、显式 Schema 版本和迁移入口。
- 结构化 validation 与阻止提交的错误边界。
- 不修改原对象的 ResumePatch、反向 Patch、ResumeDiff 和审阅结果。

该包不依赖 Flutter、数据库、网络、Model Provider 或 UI。

验证命令：

```powershell
dart pub get
dart format --output=none --set-exit-if-changed lib test
dart analyze
dart test
```
