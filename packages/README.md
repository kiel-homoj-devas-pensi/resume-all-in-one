# Packages

- `resume_domain/`：Canonical Resume Schema v0.1、validation、迁移入口、ResumePatch 与 ResumeDiff。
- `local_storage/`：SQLite/Drift schema、迁移和 `ResumeRepository` 实现。
- `agent_protocol/`：Agent、Tool 与确认命令的严格可序列化协议。
- `agent_runtime/`：离线 Tool Registry、三个白名单工具和确认写入闭环。
- `model_router/`：Model Provider、可配置 Registry、本地优先 Router 与 Fake Provider。
- `document_io/`：纯文本/Markdown 导入及 Markdown、JSON、中文 A4 PDF 导出。
- `entitlements/`：产品能力、entitlement、quota 与 credits 的无副作用本地访问策略。

设计系统包按后续任务加入。
