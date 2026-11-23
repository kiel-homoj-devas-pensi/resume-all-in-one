# Agent Runtime

Task 006 的离线最小 Runtime：白名单 Tool Registry、`read_resume`、`validate_resume`、`build_patch`、幂等/超时/取消和确认闸门。

生产代码只依赖 `agent_protocol` 与 `resume_domain`；测试使用 `local_storage` 验证确认后确实生成不可变新版本。
