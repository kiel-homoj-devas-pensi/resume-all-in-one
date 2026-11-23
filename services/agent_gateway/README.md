# Agent Gateway



Task 017 提供本机合成探测契约；Task 018 增加 SQLite、Fake 手机验证、账号会话、Fake 月订阅边界和幂等用量账本；Task 019 增加默认关闭的 GLM-5.3 适配器、三项版本化 Prompt 和严格字段投影。自动化测试默认使用 Fake Provider，不访问公网。真实 GLM 模式只允许合成数据验证，当前仍不包含真实短信、支付、生产账号或真实用户数据上线授权。



## AI内容来源响应

新网关仅在实际联网且有可用候选的200响应中提供成对的 `X-Resume-AIGC-Version: 1` 和 `X-Resume-AIGC`。原0.3.0成功JSON字段保持兼容；第二个头是七字段canonical UTF-8 JSON的无填充base64url，原文最多4096字节、编码最多5462字符。新客户端验证版本、大小、结构和任务绑定后保存。旧端忽略响应头不表示已保存来源标识。

本服务公开名称为 `Ji Ouqi`，对应项目维护者（示例），是名称而非官方赋码；制作/传播编号使用真实usage任务UUID。已实际收到的受支持标准上游标识保留制作方及制作编号，传播侧明确更新；原七字段另保全于ReservedCode2的upstreamLabel及受保护结果回执，不验证或背书原供应商签名。真实供应商字段位置、生产代理头限制和旧端兼容仍需部署前核查，不能依据模型名猜标签。来源、结果和用量回执同缓存恢复，旧无标签回执不补造来源。

## 短信费用明细留存与汇总

启用enableSmsAttemptRetention需完整SQLite11/MySQL10及同库账号留存。全部短信尝试创建90自然日后清除逐次资料，仅留全局累计次数/预留金额；unknown/reserved另记“结果未确定”的累计子集。旧SQLite10/MySQL9定义保持，显式迁移增加两列，预算不变、无退款/重发/额度恢复；缺结构或账册失配拒绝启动/发送。不自动迁移或启用生产清理。

`manage_account_retention.py migrate-sms-summary`执行需要`--apply --confirmed-target --confirmed-quiescent`及独立迁移配置；`summarize-sms-attempts`默认只读，执行需`--apply --confirmed-target`及独立汇总角色。其他清理/批准使用新库时加`--with-sms-summary`。SQLite备份明确选`--schema-version 11`，7/9/10保持原结构验证。恢复不能回退已发生费用、复活已删除资料或重发未知请求；必须单独演练。本地合成及供应商替身测试不代表生产验收。2026-10-21已在独立回环MySQL8.0.46（TLS证书与主机名验证）通过最新迁移、实际最小汇总角色、并发归档/预留及InnoDB回滚验证；未连接生产。

手机号目的互斥沿用既有事务行锁，锁键改为固定256个桶、按用途区分，不再为每个手机号长期保存完整摘要；同号必定同桶，碰撞只让独立请求串行。真实MySQL验证同号并发只保留最新有效验证码、碰撞号码各自仍可验证。旧版遗留的phone_verification_guards摘要行只能在未来停写部署时，由管理身份确认目标后清空该纯互斥表；不得运行中清空，不能顺带删除验证码、费用或防重账册。原Schema与Web权限不变。

本机SQLite人工对账入口`reconcile_usage.py`只读验证已有结构，不再调用initialize。默认保留v5；当前库必须显式`--schema-version 11`，旧7/9/10也分别校验，不自动升级或猜测回退。仍要求人工核对Provider凭证并传入`--confirm-verified`；相同证据重跑幂等，结构错误先拒绝，不释放未知费用或自动重发。该入口不支持MySQL目标，实际MySQL仍使用既有受控维护流程，不把SQLite命令用于RDS。

## Windows 本机环境



```powershell

cd services\agent_gateway

$gatewayPython = "D:\DevelopWorkplace\ToolChains\Python\3.14.7\python.exe"

& $gatewayPython -m venv .venv

.\.venv\Scripts\python.exe -m pip install -r requirements-lock.txt

```



本项目固定使用 Python.org 的标准 Windows CPython 3.14.7，不使用同版本的 MSYS2/mingw 构建。原因和工具路径见 [运行时说明](../../../../CodexProject/resume-all-in-one/docs/adr/ADR-004-gateway-python-runtime.md) 与 [版本约束](../../../../CodexProject/resume-all-in-one/docs/VERSION_CONSTRAINTS.md)。



## 质量门



```powershell

$env:PYTHONPATH = "src"

.\.venv\Scripts\python.exe -m ruff format --check src tests scripts

.\.venv\Scripts\python.exe -m ruff check src tests scripts

.\.venv\Scripts\python.exe -m mypy src tests scripts

.\.venv\Scripts\python.exe -m pytest

.\.venv\Scripts\python.exe scripts\export_openapi.py

git diff --exit-code -- openapi\v0.10.json

```



## 本机启动



开发期业务 endpoint 没有默认 token。启动前必须显式设置仅供本机测试的 Bearer token：



```powershell

$env:AGENT_GATEWAY_TEST_BEARER_TOKEN = "replace-with-a-local-test-token"

$env:AGENT_GATEWAY_ENABLE_TASK018_FAKE_IDENTITY = "true"

$env:AGENT_GATEWAY_TASK018_DATABASE_PATH = ".local\task018-gateway.db"

$env:AGENT_GATEWAY_REMOTE_PROVIDER_MODE = "fake"

.\.venv\Scripts\python.exe -m uvicorn --app-dir src --factory agent_gateway.app:createApplication --host 127.0.0.1 --port 8000 --no-access-log

```



可访问：



- `GET /health/live`：进程存活；

- `GET /health/ready`：开发期 token 与 Fake Provider 静态 readiness；

- `POST /v1/agent/requests`：只接受 `gatewayContractProbe` 和合成输入；

- `POST /v1/accounts`：只接受 `+1555000` 测试号段和固定 Fake 所有权证明；

- `POST /v1/account-sessions`：返回只出现一次的 opaque session token；

- `GET /v1/account/access/{capability}`：返回服务端套餐与免费额度决策；

- `POST /v1/resume-ai/requests`：使用账号会话、订阅/额度预留和最小字段投影执行三项远程 AI 能力；

- `GET /docs`：本机 OpenAPI 页面。



`AGENT_GATEWAY_TEST_BEARER_TOKEN` 不是生产鉴权方案，不得放入仓库、日志、fixture 或客户端。

Task 018 Fake 身份必须显式开启；固定证明不是短信验证码，只能配合保留的合成号段测试。客户端不能直接写订阅或结算用量 operation。



已受保护的 JSON 业务入口按原始字节限制请求体（默认 65,536 字节），正文接收期限由 `AGENT_GATEWAY_MAX_BODY_SECONDS` 配置，默认 10 秒，必须是有限正数。超限返回 413，接收超时返回 408 / `request_timeout`，断流、重复 JSON 键、非 UTF-8、非有限数或超过 64 层容器嵌套返回固定 400；这些情况不进入业务处理。分块合并后回放，空分块不增加帧缓存；失败与取消均释放并发槽位。`/v1/cloud-resumes` 及其子路径的读写同样受守卫保护，读取不接受正文。Gateway OpenAPI v0.10 保留开发云路由及边界响应，包含 v0.9 的独立账号权益查询，并为岗位优化/继续对话增加可选 writingContext（基础简历摘要指纹、用户确认事实、约束）；旧 v0.8/v0.9 冻结，既有成功 DTO 沿用原协议。审计只记固定路由模板，不记录正文、请求头、游标或动态身份值；本机 Uvicorn 使用 --no-access-log；反向代理访问日志仍须独立验收。



## GLM 合成沙箱



真实模式必须同时设置 `AGENT_GATEWAY_REMOTE_PROVIDER_MODE=glm` 和当前进程的 `AGENT_GATEWAY_GLM_API_KEY`。Key 不得写入 `.env`、命令历史、仓库、测试 fixture 或日志；开发、测试、生产分别注入各自的 active Key。模型、推理档位、最大输出和 Provider endpoint 均由 Gateway 固定，客户端不能提交这些参数。



可选 smoke test 只发送脚本内置的合成履历，不读取数据库或用户文件：



```powershell

$env:PYTHONPATH = "src"

.\.venv\Scripts\python.exe scripts\run_glm_synthetic_smoke.py --allow-paid-synthetic --confirmed-model-api-price --max-calls 3 --report ..\..\output\glm-synthetic-review.json

```



命令仅在确认官方当前模型、API、价格与调用预算后执行。未配置 Key 返回 NOT_EXECUTED，退出码 2。三项能力最多各一次，失败即停止、不重试；成功只代表 Schema 校验。固定合成输入/输出与 token usage 写入本地报告供语义审阅，不进入服务端正文存储或终端日志。须逐项核对缺失信息、中文、事实保持和注入文本；semanticReview 初值 notReviewed，不得当作质量通过。生产真实简历仍需智谱保留、删除、训练与处理责任评审。



只有 Key 时，先在[智谱控制台](https://open.bigmodel.cn/)核对它属于通用 API、当前 glm-5.3 访问权限、余额/赠送额度及[官方价格](https://open.bigmodel.cn/pricing)，记录允许费用上限；无需为本地 Fake 自测充值。不要用 Coding Plan endpoint 替换当前通用 API。Key 仅在启动 Python 的同一个 PowerShell 窗口安全输入：



```powershell

$secret = Read-Host '输入 GLM 测试 Key' -AsSecureString

$env:AGENT_GATEWAY_GLM_API_KEY = [Net.NetworkCredential]::new('', $secret).Password

$env:PYTHONPATH = 'src'

```



不将 Key 写聊天、仓库、.env 或 Flutter 编译参数；关闭窗口后该进程配置结束。报告只能含脚本固定合成数据。费用核对依据控制台实际账单，响应丢失不等于未收费。



## 验证码账户开发自测



保持 Fake 配置并仅监听本机。新客户端用 /v2/account/options 和 /v2/account-verifications，开发码在窗口中显示，不发真实短信；注册后支持当前/全部会话撤销、改密、找回与停用。令牌仍只在内存。账户停用不清空本地简历；只清除本机登录不表示远端撤销。完整契约见[Task026](../../../../CodexProject/resume-all-in-one/docs/specs/task-026-account-lifecycle-v0.6.md)，用量查询见[Task024](../../../../CodexProject/resume-all-in-one/docs/specs/task-024-operation-recovery-v0.4.md)，人工证据处置见[Task025](../../../../CodexProject/resume-all-in-one/docs/specs/task-025-reconciliation-v0.1.md)。



production 执行环境会拒绝开发 Bearer/Fake 身份、短信、Provider 及已知 Fake 注入。开发账号不得开放公网；资源准备及实际验收以[路线图](../../../../CodexProject/resume-all-in-one/AGENTS.md#当前进度)为准。



### PNVS 双遮罩本机凭据录入



[录入脚本](scripts/prepare_pnvs_credentials.ps1)沿用 Windows 当前用户 DPAPI，ID 和 Secret 均在本机密码框按 Ctrl+V 粘贴，不接受明文命令参数。它将两项凭据及固定的签名 `恒创联众`、模板 `100001`、变量 `code`/`min` 一起加密，文件 ACL 仅授权当前 Windows 用户和 SYSTEM；目标必须在仓库外，不能使用网络路径、目录联接、符号链接或备用数据流，已有文件不覆盖。取消不保存。轮换时用新文件路径，验证后再切换后续启动配置。



在本机 PowerShell 执行：



```powershell

Set-Location 'D:\DevelopWorkplace\Projects\AndroidStudioProject\resume-all-in-one\services\agent_gateway'

powershell.exe -NoProfile -STA -File .\scripts\prepare_pnvs_credentials.ps1 -EncryptedCredentialsPath 'D:\DevelopWorkplace\.secrets\resume-gateway-dev\pnvs.dpapi'

powershell.exe -NoProfile -File .\scripts\prepare_pnvs_credentials.ps1 -EncryptedCredentialsPath 'D:\DevelopWorkplace\.secrets\resume-gateway-dev\pnvs.dpapi' -VerifyOnly

```



第一条在两个遮罩框分别输入后点“加密保存”；第二条仅在本机解密检查字段与 ACL，成功显示“配置检查通过”和非密钥模板信息，不返回 ID、Secret、密文或摘要，不检查云端 RAM 权限。文件绑定本机当前 Windows 用户，请用将来启动 Gateway 的同一个用户录入；剪贴板由负责人自行清除。不要把明文放进聊天、`.env`、命令历史、截图、日志或 Flutter 参数，也不要发送 DPAPI 文件内容。



这个入口只准备凭据，不注入环境、不启动 Gateway、不发送短信。[运行加载器](src/agent_gateway/pnvs_credentials.py)支持同一 Windows 用户读取这种格式：持有只读共享句柄期间复用精确权限检查，再调用系统 DPAPI，在内存中验证固定字段；子进程参数只有路径，输出丢弃，失败错误固定。原生明文缓冲释放前清零，但 Python/SDK 字符串无法保证物理擦除。应用工厂通过下述两份配置显式组装真实 Sender，先核对已批准预算再加载 AccessKey。现行方案仍由 Gateway 生成/核验验证码，PNVS 只发送，模板名称不表示新增验证码登录。



维护者可在仓库外**新目录**运行 [合成安全检查](scripts/test_pnvs_credentials.ps1)，只使用脚本内置假凭据，不能用负责人的配置做测试：



```powershell

powershell.exe -NoProfile -NonInteractive -File .\scripts\test_pnvs_credentials.ps1 -TestDirectory 'D:\DevelopWorkplace\Projects\CodexProject\resume-all-in-one\output\pnvs-synthetic-new-run'

```



### 可粘贴的本机加密 Key 输入



Windows PowerShell 的隐藏终端输入若无法粘贴，可以使用带遮罩的本机窗口；脚本保留 UTF-8 BOM，兼容 Windows PowerShell 5.1。先从控制台复制 Key，再运行下面第一条，在窗口中按 Ctrl+V 并点击加密保存。文件由当前 Windows 用户的 DPAPI 保护，不能换用户或换机器解密；只向开发者提供文件路径。



```powershell

.\scripts\prepare_glm_test_key.ps1 -EncryptedKeyPath D:\DevelopWorkplace\.task-backups\resume-all-in-one\restricted\glm-test-key.dpapi

.\scripts\run_glm_synthetic_smoke.ps1 -EncryptedKeyPath D:\DevelopWorkplace\.task-backups\resume-all-in-one\restricted\glm-test-key.dpapi -ReportPath D:\DevelopWorkplace\Projects\CodexProject\resume-all-in-one\output\glm-new-synthetic.json -MaxCalls 3 -BudgetCny 40

```



第二条会产生模型调用费用，需先确认本次剩余预算；示例40不是新的批准额度，当前授权只以辅助区AGENTS和调用账本为准。脚本不会自动重试，失败后先看合成报告和账单；不要把 DPAPI 文件内容、明文 Key 或解密环境打印到聊天。单项诊断可加 `-Capability targetedResumeOptimization -MaxCalls 1 -TimeoutSeconds 180`，这是独立合成检查，不能恢复已丢失的上次结果。当前网关读取120秒、整项125秒，客户端生成135秒；单独延长诊断等待不修改运行时配置。



价格核对入口为[智谱官方定价](https://open.bigmodel.cn/pricing)；模型/API 与 low/high/max 参数见[官方 GLM-5.3 文档](https://docs.bigmodel.cn/cn/guide/models/text/glm-5.3)。脚本始终使用通用 chat/completions endpoint，客户端不接收此 Key。当前验收结果、费用估算和未执行项只在[项目路线图](../../../../CodexProject/resume-all-in-one/AGENTS.md#当前进度)记录。



## PNVS 发送边界



当前已有[官方 SDK 传输边界](src/agent_gateway/pnvs_transport.py)及[HTTP 替身测试](tests/test_pnvs_transport.py)，注册使用已确认的“恒创联众 / 100001 / code、min”，重置按官方用途使用 100003（手机实测待完成）；固定 PNVS endpoint、五分钟自定义码、零自动重试和受理/拒绝/未知结果区分。[持久预算账本](src/agent_gateway/sms_budget.py)覆盖白名单、重启/并发占位、配置指纹和不返还未知尝试；完整约束见[存储契约](../../../../CodexProject/resume-all-in-one/docs/specs/task-029a-gateway-storage-v0.3.md)。[真实 Sender](src/agent_gateway/pnvs_sender.py)连接预算、传输与生命周期，未知结果与终态确认丢失均不重发。两份显式受限配置启用真实工厂；未配置时仍使用既有开发行为，production 拒绝 Fake。准备和检查入口不读负责人实际文件、不发送短信；实际测试须另行明确号码/预算。依赖许可见[版本约束](../../../../CodexProject/resume-all-in-one/docs/VERSION_CONSTRAINTS.md)。



### 受保护运行政策与显式启动



已保存的 AccessKey 文件继续有效，不需要重新录入。另用同一 Windows 用户生成运行文件；窗口输入白名单（每行一个 +86 大陆号码）、总次数、整数分预算、每次占位金额（至少 6 分且按实际成本确定）和未来 UTC 到期时间。所有政策项初始为空，不代填费用。窗口自行生成两个不同的随机 32 字节秘密，用于 OTP 校验和预算审计，不显示或输出秘密。



```powershell

powershell.exe -NoProfile -STA -File .\scripts\prepare_pnvs_runtime.ps1 -EncryptedRuntimePath 'D:\DevelopWorkplace\.secrets\resume-gateway-dev\pnvs-runtime.dpapi'

powershell.exe -NoProfile -File .\scripts\prepare_pnvs_runtime.ps1 -EncryptedRuntimePath 'D:\DevelopWorkplace\.secrets\resume-gateway-dev\pnvs-runtime.dpapi' -VerifyOnly

```



只返回路径、检查结果及到期状态，不显示白名单。保存不写数据库、不批准预算、不读 AccessKey、不发短信。文件不能覆盖；保留原件，不能为重新试验生成秘密后冒充原政策。CurrentUser DPAPI 要求服务与录入使用同一台 Windows 机器及同一用户；其他部署身份需要单独决定受保护配置方式。



先由维护流程准备已有的 SQLite v5 或 MySQL v4。真实工厂与预算工具只读检查完整结构，缺库不创建、旧版不升级。实际库、备份与资源授权需明确；合成演练入口不能用来迁移真实资料。选定存储配置后，在服务目录运行预算命令：



```powershell

$env:PYTHONPATH = 'src'

# 默认只核对，未批准时固定 check_failed，不建立政策。

.\.venv\Scripts\python.exe scripts\approve_pnvs_budget.py --encrypted-runtime-path 'D:\DevelopWorkplace\.secrets\resume-gateway-dev\pnvs-runtime.dpapi'

# 仅在本次政策已经由负责人批准后，由管理身份首次建立。

.\.venv\Scripts\python.exe scripts\approve_pnvs_budget.py --encrypted-runtime-path 'D:\DevelopWorkplace\.secrets\resume-gateway-dev\pnvs-runtime.dpapi' --apply-approved-budget

```



MySQL 默认核对使用业务 DSN，显式写入使用同目标且不同用户的 GATEWAY_DATABASE_MIGRATION_DSN；业务身份不能创建政策或改限制。重复批准只确认相同政策，不补已用次数或金额；提交未知返回 outcome_unknown/退出码 2，先执行默认只读检查。不要在命令、日志或聊天中展示 DSN 内容。SQLite 无数据库用户分权，管理文件访问应通过主机权限控制。



从仓库外配置安全注入两条路径 AGENT_GATEWAY_PNVS_CREDENTIALS_PATH、AGENT_GATEWAY_PNVS_RUNTIME_PATH，不能只配置其中一个或混用 Fake 身份标记。production 另要求既有真实 GLM 配置且无开发 Bearer/Fake Provider；详见账户契约。应用先检查库和运行政策、核对已批准预算，最后加载 AccessKey；重启保留秘密和预算，失败释放拥有的连接池。模块导入无启动副作用，启动使用：



```powershell

.\.venv\Scripts\python.exe -m uvicorn --app-dir src --factory agent_gateway.app:createApplication --host 127.0.0.1 --port 8000 --no-access-log

```



这里监听本机；公开生产还需要 HTTPS、可信代理、备份恢复与实际验收。/health/ready 只反映已装配服务，不调用收费供应商；不能用就绪响应代替实际手机送达、GLM 可用或生产准入。



## MySQL 存储与合成迁移



后续显式云同步的目标协议见 [Task029C](../../../../CodexProject/resume-all-in-one/docs/specs/task-029c-explicit-cloud-sync-v0.1.md)。[完整快照校验器](src/agent_gateway/canonical_snapshot.py)使用现有 Pydantic 和不可变字节保留 Canonical、文档/版本及扩展，并通过与 Dart 共同的合成用例检查兼容性。快照校验器本身不连接云端。[事务存储](src/agent_gateway/cloud_storage.py)复用账户数据库和锁；[显式 SQLite 云迁移](src/agent_gateway/sqlite_cloud_schema.py)仅将已完整核验的既有 v5 合成库追加为 v6，未配置云运行文件时业务工厂仍要求原 v5 / MySQL v4；显式开发云运行文件要求已有 v6/v5，不在启动时迁移。开发切片可验证同意、不可变版本、冲突、稳定操作结果及删除标记；账户生命周期须显式 withCloud=True 才在停用事务中退休云文档。[MySQL 云迁移](src/agent_gateway/mysql_cloud_schema.py)在 v4 后追加 v5 五表，完整核验旧摘要、列、约束、索引和外键；业务身份只显式核验，不建表。开发切片还有只投影元数据的有界列表/历史分页，必须显式传入独立 32 字节 cursorSecret；游标绑定账号、查询及资源，每页复核会话。独立正文清理组件依照保存的保留期分批从新到旧删除历史，最后才清正文并保留删除身份/操作结果；MySQL 清理角色只读身份，账户共享锁/文档排他锁保持与业务互斥，实际兼容云库仍须验收。[开发 HTTP 路由](src/agent_gateway/cloud_routes.py)复用这些实际组件；仅 createApplication(cloudStore=...) 显式注入同库账户/用量、开启停用退休的生命周期及独立游标签名秘密，并完整只读核验结构后才能启用。生产注入在开库前拒绝；常规环境启动仍关闭云能力。只读 /v1/cloud-resumes/options 可发现状态，原快照 PUT、政策/操作/基础请求头与 URI 编码见同一目标协议。受限开发配置已可由正常工厂装配，说明如下；后台清理调度与客户端入口尚未完成，生产仍须完整闭环。



### 云运行文件和正常启动



[准备工具](scripts/prepare_cloud_runtime.ps1)只接收公开政策字段，自动生成独立32字节游标秘密，用现有 CurrentUser DPAPI/精确ACL保存到仓库外新文件。八字段固定为 schemaVersion=1、syntheticOnly=true、policyVersion、region、contentRetentionDays、backupRetentionDays、resourceIdentity、cursorSecretBase64。政策不代填；标签使用64字符以内ASCII标识，保留天数0..3650。最后一项不由操作者录入，也不出现在命令或输出。已有文件不覆盖，失败不会留下新配置。



下面是填写格式；占位符须替换为明确的合成开发值，不能代替真实区域/保留/备份批准：



```powershell

powershell.exe -NoProfile -NonInteractive -File scripts\prepare_cloud_runtime.ps1 `

  -EncryptedRuntimePath '<仓库外新cloud-runtime.dpapi路径>' `

  -PolicyVersion '<明确合成版本>' -Region '<明确合成地区标签>' `

  -ContentRetentionDays <明确整数天数> -BackupRetentionDays <明确整数天数> `

  -ResourceIdentity '<明确合成资源标签>'

powershell.exe -NoProfile -NonInteractive -File scripts\prepare_cloud_runtime.ps1 `

  -EncryptedRuntimePath '<同一加密路径>' -VerifyOnly

```



仅准备/本机检查，不连接数据库、不读取PNVS AccessKey、不发短信。启动继续用原生Uvicorn工厂，不需要自定义启动代理；配置路径与账号数据库位置显式注入：



```powershell

$env:AGENT_GATEWAY_CLOUD_RUNTIME_PATH = '<已核对加密路径>'

$env:AGENT_GATEWAY_ENABLE_TASK018_FAKE_IDENTITY = 'true'

# SQLite 使用已有 v6 的 AGENT_GATEWAY_TASK018_DATABASE_PATH；MySQL移除此路径并使用已有v5、同一DSN/TLS/到期配置。

.\.venv\Scripts\python.exe -m uvicorn --app-dir src --factory agent_gateway.app:createApplication --host 127.0.0.1 --port 8000 --no-access-log

```



账户、用量、withCloud生命周期和CloudResumeStore由同一工厂装配。若选择PNVS则移除Fake身份标志，保留既有两份PNVS文件与事先批准的同库预算；云文件不能批准预算，游标秘密等于OTP/审计秘密时在AccessKey加载前拒绝。配置不可与手工账户/生命周期/云存储注入混用，避免两个政策来源。生产云路径在读取任何文件或开库前拒绝。



启动只检查已有完整云结构，缺库/旧版/外来表均失败，不创建或升级。SQLite基础合成库须先显式由 GatewayDatabase.initialize 准备v5，然后通过既有 migrateSqliteCloudSchema 追加v6；重复迁移用同一个迁移函数只核验v6，不再调用基础initialize。MySQL准备仍用下面已有CLI与独立迁移身份，真实停写要求保持。



[Python加载](src/agent_gateway/cloud_runtime.py)复用锁文件、系统DLL、DPAPI与字段解析，不输出配置/秘密/底层异常。本机VerifyOnly检查权限及字段，实际加载再拒绝重复JSON键并严格复核类型。默认启动无云文件仍返回关闭，不产生随机游标签名秘密。同一文件/身份/资源重启可续页；轮换先生成仓库外新文件、再切换启动路径，旧游标需从第一页重查，账号/内容/原操作不改写。不要删除尚需核对的旧配置或把新秘密复用为OTP/审计秘密。部署到其他Windows用户/机器需重新安全配置，不能把CurrentUser文件当作可移植生产秘密存储。



云切片继续使用下面已有的合成迁移入口及同一套 MySQL/TLS/到期配置。无云运行配置的业务工厂仍拒绝云 v5；这些命令只准备或核验专用合成库。只读命令不写账户、云内容或预算。



```powershell

$env:PYTHONPATH = 'src'

.\.venv\Scripts\python.exe scripts\run_mysql_synthetic_contract.py --synthetic-only --with-cloud --dry-run

# 单个管理者操作，确实停止业务写入后才确认；使用不同用户、同一库的迁移 DSN。

.\.venv\Scripts\python.exe scripts\run_mysql_synthetic_contract.py --synthetic-only --with-cloud --migrate --confirmed-quiescent

```



MySQL DDL 可能自动提交。空云表中断可恢复，已有云表先核验结构与空值；未知表、结构不符或未标记的非空云表在新增 DDL 前拒绝。全部核验成功后才记录 v5；重复执行仅确认，不重置内容。提交确认丢失返回 UNKNOWN（退出码 2），保留现状并对同一目标运行只读核验，禁止自动重放、清表或回退。正文版本及操作结果的业务角色仅 SELECT/INSERT；同意只更新 revoked_at_utc，文档/计数只授予实际需要的更新列。业务角色不能执行 DDL、覆盖或删除历史。真实资源、资料迁移及政策仍需另行确认。



Task029A 将账户/会话、权益/用量/对账、验证码/限流与账户管理统一到所选后端。[存储契约](../../../../CodexProject/resume-all-in-one/docs/specs/task-029a-gateway-storage-v0.3.md)定义后端与事务；SQLite 原运行配置继续有效。完整服务可在显式 Fake 开发配置下选择 mysql，但必须通过完整 v3/v4 结构检查，不能自动迁移或回退 SQLite。MySQL 存储适配不表示真实 PolarDB-X 或生产服务已经验收；当前证据见[开发进度](../../../../CodexProject/resume-all-in-one/AGENTS.md#当前进度)。



配置名与占位符见 [.env.example](.env.example)。服务不自动读取该文件，实际 DSN/CA/到期值由仓库外安全配置或进程环境注入；不把密码放在命令或终端输出。MySQL 使用 PyMySQL 1.2.3（MIT）与证书/主机名验证，最大四连接、五秒等候和 I/O 超时。凭据轮换后重建连接池/服务进程，断开的连接会丢弃，下一请求重连；没有事务自动重试。



仅在专用 `resume_gateway_synthetic` 前缀库和真实到期信息已落实、确认仅写合成数据后执行：



```powershell

$env:PYTHONPATH = 'src'

.\.venv\Scripts\python.exe scripts\run_mysql_synthetic_contract.py --synthetic-only --dry-run

.\.venv\Scripts\python.exe scripts\run_mysql_synthetic_contract.py --synthetic-only --migrate

.\.venv\Scripts\python.exe scripts\run_mysql_synthetic_contract.py --synthetic-only

```



第一条只读检查已迁移 schema，未建表时失败；第二条要求 `GATEWAY_DATABASE_MIGRATION_DSN` 的独立用户，同一目标库，串行执行迁移后运行合成契约；第三条仅用业务身份验证已有 schema、账户/用量/生命周期行为。无配置输出 SKIP，不是联调成功。DDL 权限只给迁移身份；业务身份对七张业务表和验证码保护表授予必要 SELECT/INSERT/UPDATE，停用还需要 DELETE subscription_snapshots，对版本表只读。失败 DDL 可能保留空表；检查结构后可重跑，版本最后记录。异构结构、未知版本或已有未标版本新表数据拒绝；不清表。



MySQL 独立链依次为 v1 账户/会话、v2 权益/用量/对账、v3 验证码/限流与保护行（九表），v4 再追加短信预算与尝试（十一表）；SQLite 保留 v4 历史并追加 v5。新短信表使用下面的显式选择，不批准或初始化发送政策；业务身份对新表的列级权限见存储契约。真实 PolarDB-X 的锁、外键/CHECK 与二进制键语义须实际实例验收。本机合成记录保留供核查；这些入口不发送短信/模型请求。



需要 MySQL v4 时，先在已确认的专用合成库显式运行 `.\.venv\Scripts\python.exe scripts\run_mysql_synthetic_contract.py --synthetic-only --migrate --with-sms-budget`；未确认的新表数据拒绝迁移，不清表。



数据导入的版本对应为 SQLite v4→MySQL v3、SQLite v5→MySQL v4；先准备合成源并由独立迁移身份建好对应空目标，再演练：



```powershell

# 只读核对，不初始化或改动源文件；输出只有表计数/摘要和目标状态。

.\.venv\Scripts\python.exe scripts\import_sqlite_synthetic.py --synthetic-only --source <仓库外合成SQLite路径>

# 确认源和目标业务停止写入，验证码摘要秘密一致；只允许空目标或已完整相同的目标。

.\.venv\Scripts\python.exe scripts\import_sqlite_synthetic.py --synthetic-only --source <同一合成SQLite路径> --apply --confirmed-quiescent --confirmed-otp-secret-preserved

```



默认 dry-run 使用业务身份只读，apply 使用不同的 `GATEWAY_DATABASE_MIGRATION_DSN` 身份；目标须为同一专用合成库。源上限为对应七表/九表合计一万行，对可见账户号码拒绝真实格式，拒绝未知源版本或标成旧版的后续账表；稳定 ID、摘要、UTC、已结算/待对账与挑战记录、已有短信预算及尝试逐项保留，不导入 SQLite 版本表。数据按外键顺序在单事务写入并核对，失败全部回滚；非空且不完全相同的目标拒绝覆盖。MySQL 的保护行按后续操作创建，不伪造源表。



提交确认丢失返回 UNKNOWN（退出码 2），先保留两端并用相同源执行默认只读核对。完全相同表示已有结果；重复 apply 仅确认，不再写入。未知或混合结果不得自动重放、清表或切回旧库。工具不停止业务写入，两个确认参数必须如实反映维护窗口；源的读取快照不能代替目标停写。保留 OTP 摘要密钥是验证码仍可消费的条件，不能借迁移自动轮换密钥。这是合成演练入口，真实资料迁移仍需另行确认对象、备份与回滚界线。



## 服务端账号角色与永久会员



`AGENT_GATEWAY_ENABLE_ACCOUNT_PRIVILEGES` 默认 `false`，原有 SQLite v5 / MySQL v4（或显式云 v6/v5）启动规则不变。显式启用时，启动只读核对 **SQLite v7 / MySQL v6**，不建库、不升级、不自动授予。新版本沿旧迁移追加 `account_privilege_grants`，保留旧 DDL/摘要；结构包含既有云表，不代表开启云上传。升级后要保留该开关，不能用旧基础库初始化入口重启或回退数据库版本。



普通账号的角色为 `member`；管理员角色为 `admin`。会员权益独立为 `none` 或 `permanent`，没有伪造远期到期日、月度续费和支付订单。永久会员实际参与服务端访问判断和用量预留，返回既有 `plan=pro`；管理员角色本身不解锁 AI。原有请求容量、并发、排队/超时及未知结果对账仍执行，永久免会员费不等于供应商免费。此切片仅维护管理员身份，没有新增远程管理后台或授予接口。



客户端以账号会话调用 `GET /v1/account/privileges`，成功协议独立为 `0.1.0`：



```json

{"protocolVersion":"0.1.0","accountId":"account-example","role":"admin","membership":"permanent"}

```



旧身份、访问和生命周期 DTO 不增加字段；未启用新能力返回 503 / `account_privileges_unavailable`，不能把这一状态当作免费用户。无效会话使用既有 401。调用者不能通过 URL、请求正文或手机号指定另一个账号，也没有 HTTP 权限写入入口。身份和权益应按同一个会话解释，退出或切换账号后不复用旧结果。



### 显式迁移与受控授予



Windows 的实际 MySQL 权益操作使用 [安全录入窗口](scripts/manage_account_privileges_secure.ps1)及其[私有 stdin 入口](scripts/manage_account_privileges_secure.py)。公开参数只包含数据库目标、CA/到期及已验证账号的稳定ID、grant ID、权益、操作人和证据摘要；手机号与数据库密码由本人在窗口填写，仅经有界 UTF-8 私有管道传递，不写入参数、环境或普通日志。默认只读计划使用业务身份；显式 `-Apply` 还需独立维护密码和窗口确认。两身份须实际匹配同一数据库实例，单次只授一项已有领域权限，不迁移Schema、不调用短信或模型。



管理员与永久会员分别使用稳定的 grant ID。写入后用新的业务连接按同一完整 grant 计划只读回查，并核目标角色/会员当前仍有效；提交未知时只运行原 grant 的只读计划，不自动重发、换ID或只查Schema就认定成功。界面截图不得包含填入的手机号。此入口的本机合成验证不表示云端已部署或真实指定账号已授权。



管理脚本 [manage_account_privileges.py](scripts/manage_account_privileges.py) 使用既有数据库环境配置。SQLite 要求已有绝对文件路径；MySQL 修改要求独立 `GATEWAY_DATABASE_MIGRATION_DSN`，与业务身份不同、目标主机/端口/库相同。迁移仅从已有 SQLite v5/v6 或 MySQL v4/v5 追加；已有最新结构只核验。MySQL 空表 DDL 中断可恢复，未标记的非空表、外来表、结构错误或摘要错误拒绝。SQLite v5→v6 与 v6→v7 是两个事务；后一阶段失败保留可检查的 v6，原账号/资料不清空，修复后可继续。



```powershell

$env:PYTHONPATH = 'src'

# 默认只读；旧版会明确检查失败，不隐式升级。

.\.venv\Scripts\python.exe scripts\manage_account_privileges.py check

# 管理者已核对备份、目标，并实际停止写入后显式迁移。

.\.venv\Scripts\python.exe scripts\manage_account_privileges.py migrate --apply --confirmed-quiescent

```



迁移与授予分开执行。已有账号须正常注册并完成手机号验证；阿里云测试号码登记不等于本应用账号已验证。授予时从受限配置仅向管理命令进程注入 `AGENT_GATEWAY_PRIVILEGE_TARGET_PHONE`，不把真实号码写入源码、命令参数、APK、日志或公开文档。每项授权需要稳定 account ID、永久保持不变的 grant ID、操作人标识与批准证据的 SHA-256。下列命令先返回可审阅计划；确认同一目标和证据后才加 `--apply`：



```powershell

.\.venv\Scripts\python.exe scripts\manage_account_privileges.py grant --account-id '<verified-account-id>' --grant-id '<stable-admin-grant-id>' --privilege admin --operator-id '<operator-id>' --evidence-sha256 '<64-lowercase-hex>'

.\.venv\Scripts\python.exe scripts\manage_account_privileges.py grant --account-id '<verified-account-id>' --grant-id '<stable-member-grant-id>' --privilege permanentMember --operator-id '<operator-id>' --evidence-sha256 '<64-lowercase-hex>'

.\.venv\Scripts\python.exe scripts\manage_account_privileges.py revoke --account-id '<same-account-id>' --grant-id '<same-grant-id>' --operator-id '<operator-id>' --evidence-sha256 '<revocation-evidence-sha256>'

```



脚本复核账号存活、目标号码和规范 UTC 验证时间，拒绝未验证/未来时间；不会发验证码或创建账号。数据库当前不保存历史验证供应商的来源，因此该检查不能独立证明某条历史行来自真实 PNVS；维护者还须核对批准证据，生产启动仍拒绝 Fake 身份。工具不能替代真正注册验证。



相同 grant ID 只属于一个稳定账号，重复相同授予返回已有结果，改变账号/权限/证据拒绝。撤销保留原授予和撤销审计，同一账号同一权限不能换 grant ID 悄悄重授；恢复权限需要另行明确的受控生命周期能力。停用后手机号可以重新注册，但新账号不继承旧角色/会员；没有按号码登录时自动升权。提交结果未知返回退出码 2 / `outcome_unknown`，先只读核对，禁止自动重放。



MySQL Web 业务身份对 `account_privilege_grants` **只授 SELECT**；管理身份才有 INSERT/UPDATE，不能把管理 DSN 注入 Web 进程。除此之外保留既有账号、会话和用量权限。由于新结构可承接已有云资料，账号停用始终退休旧云资料，即使云路由关闭；业务角色还需 `cloud_account_state` 的 SELECT/INSERT/UPDATE(last_sequence)、`cloud_documents` 的 SELECT/UPDATE(deleted_at_utc,last_sequence)、`cloud_consents` 的 SELECT/UPDATE(revoked_at_utc)，不新增历史正文写入权限。SQLite 依靠主机文件权限隔离维护命令与非受信用户。



### SQLite v7 在线备份与隔离恢复核对



[备份 CLI](scripts/backup_sqlite.py)使用既有 `AGENT_GATEWAY_TASK018_DATABASE_PATH`，后端必须为 SQLite。源须为已存在的本机绝对文件路径，目标须为已存在受限目录中的新文件；数据库及备份目录都由维护者设置 Windows ACL，不放公开目录或网络共享。仅预先核准的备份操作加 `--apply`，缺少该参数不写文件：



```powershell

$env:PYTHONPATH = 'src'

.\.venv\Scripts\python.exe scripts\backup_sqlite.py --destination '<已有受限目录中的新绝对备份路径>' --timeout-seconds 60 --apply

```



工具以只读连接打开源，通过 `sqlite3.backup` 包含已提交 WAL 数据，绝不直接复制 live.db 或 WAL。自有子进程完成备份、完整 `integrity_check`、外键与精确 v7 结构检查、哈希和刷新后，父进程才在目标同目录原子发布单文件。开始前与发布前都检查目标主文件及其 `-wal`、`-shm`、`-journal`；任一名称已占用（包括悬空符号链接）均拒绝，保留原文件，绝不删除旧 sidecar。原子发布同时拒绝目标主文件的并发占用，不覆盖；目标文件系统不支持硬链接时直接失败，不降级覆盖。目标目录必须受信，维护期间不要让其他进程打开同一目标名称或写入其 sidecar。默认总工作期限60秒，可设大于0且至多3600秒，超时仅终止自有子进程并清理其临时文件；退出清理另有至多两次5秒子进程终止等待。正常失败不留下已发布目标；系统断电或强杀父进程可能留下 `.gateway-backup-*` 暂存目录，不能视为有效备份，须确认无备份进程后由维护者核对处理。成功只输出 `backup_verified`、SHA-256和字节数；失败固定状态，不输出源数据或内部错误。源不创建、不迁移、不重置预算，备份不包含外部受限配置/密钥。



至少上线前、迁移/授予前及日常定期保留多代备份，并把一份受保护副本保存至 ECS 外。恢复演练先验证备份哈希，将副本放到新的隔离路径，在独立命令进程将数据库路径指向该副本，运行 `manage_account_privileges.py check`（同时另以只读 SQLite 连接运行 `PRAGMA integrity_check` 和 `PRAGMA foreign_key_check`）；隔离演练禁止连接短信/模型。核对账号、权益及账本后才评估切换，工具不自动替换活动库、不清除旧库或 WAL、不启动任何业务服务。实际恢复旧备份会回退会话撤销、短信预算和 AI 用量，须先停止服务与外部调用、保存现状并对账，未知结果不得自动重发或因恢复补回预算。CurrentUser DPAPI 配置另有受限恢复要求；只备份数据库并不能恢复整个服务。当前证据为本机合成验证，不能代替 ECS 实机或真实业务恢复验收。



PNVS 预算工具兼容此显式开关：启用后只读核验 v7/v6；关闭仍严格核验旧 v5/v4，不猜测版本或自动迁移。预算缺失仍须其独立 `--apply-approved-budget` 操作，账号会员授权不会创建短信预算、补额或发送短信。



### Windows MySQL 生产候选的受保护启动入口



[录入窗口](scripts/prepare_gateway_startup.ps1)复用现有 CurrentUser DPAPI 与精确 ACL 模块，新增一份仓库外密文束。模型 Key、**业务身份** MySQL DSN 在遮罩框录入；另外三项是 TLS CA、PNVS 凭据/运行文件的绝对路径。新格式为六个固定字段（含 schemaVersion=2），不要求填写数据库或应用截止日期；仍兼容旧 schemaVersion=1 密文，其中历史试用日期只校验格式，不作为生产连接到期条件。无需重写现有凭据。合成/维护工具可继续使用单独、明确的限时数据库配置。不接受迁移/管理 DSN、Fake、Bearer、云同步或自定义监听字段。



云机先由负责人设置专用运行身份，再用**同机同用户**录入所有 DPAPI 文件。程序代码及目录由维护者控制；运行用户不应有修改启动程序/依赖的权限。秘密文件只允许当前用户和 SYSTEM；已有文件不覆盖，轮换使用新路径，保留旧配置以便核对。剪贴板由负责人自行清理。CurrentUser 密文无法直接从开发机复制后换云机/身份解密。已有 OTP/审计秘密不能用重新生成的新文件冒充原政策迁移。



在已安装锁定依赖的 Gateway 发布目录执行（命令只含密文路径）：



```powershell

powershell.exe -NoProfile -STA -File scripts\prepare_gateway_startup.ps1 -EncryptedStartupPath 'C:\ResumeGatewayData\secrets\startup.dpapi'

powershell.exe -NoProfile -NonInteractive -File scripts\prepare_gateway_startup.ps1 -EncryptedStartupPath 'C:\ResumeGatewayData\secrets\startup.dpapi' -VerifyOnly

powershell.exe -NoProfile -NonInteractive -File scripts\start_protected_gateway.ps1 -EncryptedStartupPath 'C:\ResumeGatewayData\secrets\startup.dpapi' -CheckOnly

```



`VerifyOnly` 仅本机启动束字段/当前身份/权限检查。`CheckOnly` 进一步从固定发布目录启动 Python，真实解密三份 DPAPI 文件、拒绝重复键与未知字段，核验 CA 文件存在、DSN 格式和数据库 UTC 到期及 PNVS 结构；它**不构造应用、连接数据库、批准预算、迁移、创建账号、发送短信或调用模型**。它不证明 CA 信任/实际 TLS、云端 RAM 权限、数据库 v6 或余额，输出固定安全状态，不回显 Key/DSN/号码/路径内容。



在数据库 v6 已经由独立管理步骤完成、同库 PNVS 预算已获准写入、真实业务身份权限已核对之后，才运行去掉 `-CheckOnly` 的同一启动命令。固定 `production`、MySQL、真实 PNVS、GLM 和账号权益；固定 `127.0.0.1:8000`、单 worker、不记录 access log，不允许 CLI 切换 reload/监听地址/worker。直接把解密结果传给 Settings，**不注入秘密环境变量**；不读取普通 Gateway 环境变量覆盖。继承迁移/管理 DSN 环境变量时拒绝启动，维护命令应使用独立进程和身份。



Web 业务账号仍必须仅 SELECT 权益授予表，独立管理账号才可写授予。字段名称不能证明数据库实际 GRANTS；部署时须独立核对角色/表/列权限，本工具不创建或调整数据库用户。真实启动会由既有应用工厂连接数据库、核验既存结构和 PNVS 同库预算，不自动迁移或补预算；失败固定消息，不靠 SQLite/Fake/开发模式兜底。任何收费短信/模型调用仍需独立批准，创建配置和启动入口不授予这类费用许可。



此入口不注册 Windows 服务/计划任务、不修改防火墙、不生成真实密钥；受管任务动作只能保存程序和密文路径，必须与录入的 Windows 身份一致。退出远程桌面后的存活、开机自动恢复、ECS Windows Server 兼容性和真实在线仍须实机验收。合成专项 `tests/test_protected_startup.py` 验证 DPAPI 往返、ACL/损坏拒绝、无网络 CheckOnly、固定装配、失败脱敏及 PowerShell→Python 启动链；Linux CI 只条件跳过 Windows 原生集成，通用装配/边界测试仍运行。



### 首次准备专用空 MySQL 数据库



[prepare_mysql_schema.py](scripts/prepare_mysql_schema.py)与合成业务契约脚本分开：不创建数据库/用户，不写Fake账号、短信预算或权益。配置只在独立受控维护进程获取，管理DSN不得进入正常Web启动环境。默认`plan`只用业务DSN读取可见结构；表级权限可能隐藏其他对象，这个结果不能单独证明全库为空。`check`只认可完整v6。



实际专用目标、停写与空库均核准后，才显式申请写入：



```powershell

$env:PYTHONPATH = 'src'

.\.venv\Scripts\python.exe scripts\prepare_mysql_schema.py plan

.\.venv\Scripts\python.exe scripts\prepare_mysql_schema.py check

# 仅经确认的维护操作；连接串和密码不写命令参数。

.\.venv\Scripts\python.exe scripts\prepare_mysql_schema.py plan --apply --expected-host '<verified-host>' --expected-port 3306 --expected-database '<dedicated-database>' --confirmed-quiescent --confirmed-dedicated-empty

```



沿用`GATEWAY_DATABASE_DSN`、TLS CA和UTC到期配置；仅apply读取独立`GATEWAY_DATABASE_MIGRATION_DSN`。双配置先核host/port/database，连接后核实际DATABASE、CURRENT_USER和server_uuid；管理身份必须有目标库级或全局SELECT以检查所有表，实际最小权限仍须另核。命名维护锁只能串行同一准备工具，不能证明其他写入者已停。



纯空库才按既有17项DDL创建，完整结构校验后事务记录原六个摘要；完整v6重复执行仅核验。部分DDL、未知对象、异构或非空均拒绝，不自动续跑或清库。DDL隐式提交或最终提交确认丢失时返回退出码2/`outcome_unknown`，先同目标只读check；完整v6才能确认，部分结构必须人工审查并另定恢复操作，不自动重放。正常Gateway只读验证v6，不调用此初始化工具。


### 原任务短期恢复（2026-10-17增量）

新客户端在生成时带`X-Result-Recovery: 0.1.0`。受保护Windows启动从原密文配置目录推导同级`ai-results`，使用[scripts/prepare_remote_result_cache.ps1](scripts/prepare_remote_result_cache.ps1)预先准备专用普通运行SID目录，正常启动只核ACL，不创建或修正未知目录。原配置密文、RDS Schema和权限不改变。先核实际线上增量是否已部署，不照开发源码假定生产具备能力。

模型调用前预留恢复位置；结果使用该普通用户CurrentUser DPAPI加密保存，最多128条、单条明文256KiB、自原任务开始保留24小时，不因查询延长。保存生成候选与用量回执，不保存提交原文、照片、令牌或供应商密钥。过期时拒绝恢复，运行中每60秒及启动清理。此为短期结果恢复，不是云同步或长期备份。`operations.log`只写安全元数据，5MB并最多2份轮转；专用目录不进入普通分发包。

`GET /v1/resume-ai/recovery-options`用于发布预检；`POST /v1/resume-ai/results/lookup`正常认证查询原任务，返回原成功响应、运行中202、未知409或已完成且过期410，绝不触发模型。连接取消后原任务继续；缓存完整回执后发生用量提交中断，可以只修复同一用量。原v0.4操作查询与旧客户端不变。不能恢复旧版本从未缓存的结果，不能以连接失败当作未收费证据，不自动重发未知请求。客户端不提供承担未知费用或手动解锁选项。

## 2026-10-22 持续开放（同一 1.10）

默认关闭。生产受保护启动只读取同数据根的 `open-test/policy.json`：

```json
{"schemaVersion":2,"enabled":true}
```

目录和文件沿原服务 SID 的严格 Windows ACL；不放源码、APK或凭据目录内，不由客户端参数开启。非法字段、重复键及歧义类型均拒绝。schemaVersion=2 无截止日期，跨公开日期和自然年持续生效；历史显式限时 schemaVersion=1 文件仅作兼容。启用后，全部注册及匿名游客的现有 AI 成果次数、原共享模型启动次数、游客总调用次数、旧测试截止及短信人工总次数/预算不阻断新请求。此开关不新增云同步、会员支付或其他尚未开放功能，不绕过成年声明及发送知情确认。仅运营者主动将 enabled 改为 false 并重启才关闭当前持续开放配置。不读取充值余额，不自动充值、重发或退款。

`/v1/account/quota/{capability}` 增加布尔 `isUnlimited`，为 true 时 allowed=true/reason=allowed；monthlyLimit、remainingMonthlyGenerations 仍是原有限额度及实际剩余（可能为0），不是巨大占位数字。旧 `/access` 精确字段不变。账号与游客仍写原用量、防重、未知结果、原结果恢复及费用账；重复同键不能再次调用供应商。并发、队列、输入、超时、验证码冷却、手机号和来源防刷继续生效。

不更改 SQLite11/MySQL10 Schema。现有短信表 CHECK 的存储 ceiling 仅在同一预留事务中精确增长到 max(原批准cap,实际累计)，不是放大业务限额。配置原cap和原政策 fingerprint 始终独立核验；关闭后即使用量超过原cap仍能读账/结算/90日汇总，新增短信按原cap及原截止拒绝。手机号和逐次明细的既定保留规则不变。旧模型启动账也保留全部记录，配置存在但 disabled 时仍可回读超出旧上限的历史。**启用后保留 disabled 的配置文件，不能删除账册或删除配置来重置历史。**

部署前先排空、在线一致备份并核对实际源及库版本，沿既有迁移链到 MySQL10；本开关不另加迁移。以数据库所有者明确审核后，仅给原 web 用户补 `UPDATE(maximum_attempts,budget_cents)` 两列，禁止授予 fingerprint、unit、expiry 更新或表级 UPDATE；服务启动校验四个精确 counter/ceiling 更新列。可运行 `python scripts/prepare_open_test.py --policy <绝对路径>` 输出本地计划及待审核 GRANT SQL，命令不执行 SQL/请求供应商。不要重放初始建库脚本或旧试用提额脚本；原任务身份、CurrentUser DPAPI、短信/智谱凭据、用量/预算库和原结果目录保持。当前公共端点、各库版本和实际两列权限须在部署时独立核验。

有限运行恢复使用配置中原 cap，不能把增长后的表内 storage ceiling 反读成新的批准额度。将来确需更改有限短信政策时，要先按保留累计金额审核维护计划；旧 prepare_volunteer_trial 的原值 SQL 不能直接套在已增长的 ceiling 上。
