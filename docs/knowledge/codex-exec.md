# Codex Exec 独立 Ticket 会话

## SEC-CODEX-01 Windows 安装、认证、版本与故障预检

### 适用
supervisor 被指定用 Codex CLI 在某个**目标仓库**顺序下发 Ticket，或 CLI 无法启动/无法执行命令。

### 步骤
1. 在**实际执行主机**核验 `Get-Command codex -ErrorAction SilentlyContinue`、`codex --version`、`codex login status`、`codex exec --help` 与 `codex exec resume --help`；`codex exec` 是 Codex CLI 子命令，不单独安装。安装/登录按官方文档 `https://developers.openai.com/codex/non-interactive` 和 `https://developers.openai.com/codex/cli/reference`。
2. 记录执行主机、用户、CLI 实际路径、版本、认证、参数支持情况。**2026-10-08 实测记录**：`ZC2026090353` 上 `codex-cli 0.161.0`、`Logged in using ChatGPT`、`Get-Command codex` 可用；历史“该主机未安装”结论已过期。
3. 同一轮任务在本机首次选择 Codex 执行器时核验一次安装、认证与命令格式；后续 Ticket 直接复用，只有环境变化或真实失败时才重新检查。**不为每张 Ticket 额外开启只读 Codex 会话进行 Shell/规则探针**；项目规则与 Shell 执行证据在正式 Ticket 会话内确认。若启动器无法执行命令，报告阻塞，不能伪造下发成功。
4. 仅在真实执行失败时调查 Windows Codex 沙盒：曾实测 `Failed to create unified exec process: helper_unknown_error: setup refresh had errors`，底层为 `node_repl.exe` 被占用（`os error 32`），连普通 Shell 都无法运行。记录 `~/.codex/.sandbox/sandbox.<date>.log`，定位文件占用/运行时；**不为每张 Ticket 重复诊断，不默认关闭沙盒或升级危险权限**。

### 坑
- `thread.started` 仅证明模型会话创建，**不能证明 shell 执行成功或代码开发成功**。
- CLI 状态可能随主机变化；同一轮顺序任务不重复运行 CLI/沙盒探针，仅在换主机、变更配置或真实报错时重新诊断。
- PowerShell 无人值守管道可能出现 `Reading additional input from stdin...`；避免向 CLI 留着未关闭的交互输入，首选管道传入完整提示词并保留日志。

## SEC-CODEX-02 独立 Exec 单轮调用与参数

### 适用
从 supervisor 下发任务时，需要单独运行一个指向目标仓的 Codex Exec 会话。**为规避 Codex 父进程沙盒导致的嵌套执行限制，优先由 Codex 进程之外的独立 PowerShell 调度脚本启动，详见 `SEC-CODEX-06`。**

### 步骤
1. **每次从用户路径确定目标根** `$targetRoot`，并从 `tasks.md` 定位唯一 Ticket。不能固定 `digital-logistics`，也不能使用 supervisor 当前目录代替 `-C`。
2. 命令入口（变量由调度器按选票填写；一次只执行当前 Ticket）。**执行时按 `SEC-DISPATCH-07` 给 `codex exec` 及原会话 `resume` 传入本轮选定的 `-m`、`-c` 推理档位**；用户未指定时默认 ChatGPT 6.1 Sol Medium：

   ~~~powershell
   $targetRoot = '<已验证的目标仓库绝对路径>'
   $prompt = @'
   $implement
   在目标仓按 AGENTS.md 和适用规则开发唯一 Ticket <ID>：
   <Ticket 的绝对路径>。
   验证所需 Spec 锚点和全部 Acceptance Tests。
   不启动其他 Ticket/CLI，不自行跨项目，不绕过权限。
   遵守目标项目提交规则，返回测试和变更证据。
   '@
   $prompt | codex exec -C $targetRoot --sandbox workspace-write --json -m gpt-6.1-sol -c 'model_reasoning_effort="medium"'
   # 用户要求 High 时把 medium 改为 high；模型 ID 仍需以当前 CLI 实际支持情况为准。
   ~~~

3. **正式开发直接运行上述唯一一次 `codex exec`，不先另开只读会话**。`--sandbox workspace-write` 是本次开发会话的安全模式，Windows 上仍可能触发 Codex 自身的沙盒初始化；不代表再启动一个代理或测试会话。省略参数也不保证关闭沙盒，实际模式受配置影响。按实际 `codex exec --help` 校对必要参数；模型 ID 以本 CLI 可用值为准。
4. **Ticket 新会话禁止** `resume` / `--ephemeral`；持久化本次返回的 `thread.started.thread_id`。只有同一 Ticket 续接时才用 `exec resume`。超时/错误也要保留首次事件日志与退出码。
5. Codex 启动会话时可自动注入目标根目录 `AGENTS.md`，但不等于已加载关联的 `.mdc`、经验切片或 Skill。**在本张正式 Ticket 会话内**要求读取并确认必要文件及 `$implement`，核对真实工具事件；缺失则在当前会话内补足或报阻塞，不另外启动一轮探针。

### 坑
- 固定某个业务仓库目录，会导致 supervisor 的多项目输入失效；目标根必须动态解析。
- `/implement` 在纯文本提示词中不等于 Codex 原生 Skill；需另验证 `$implement` 的真实加载。
- 不能把外层任务调度和内层实际开发混同：**独立 PowerShell 调度脚本要从 Codex 进程外部启动**，才不会经过父 Codex 的 shell 工具沙盒。若在 Codex 会话内执行 PowerShell 脚本，仍属于父 Codex 启动子进程，并未规避嵌套。

## SEC-CODEX-03 新 Ticket 新 Thread、原 Ticket Resume

### 适用
第一张 Ticket 完成后准备开发下一张，或当前 Ticket 测试失败需继续修复。

### 步骤
1. 每张 Ticket 首次调用独立 `codex exec -C <targetRoot> --sandbox workspace-write --json`，取 `thread.started.thread_id`，绑定到 `(目标根,模块,Ticket ID)`；禁止用上一 Ticket 的 ID 续接新的 Ticket。
2. 当前 Ticket 原会话返工用该 CLI 当前版本支持的 `codex exec resume` 语法（先运行 `codex exec resume --help`）；在目标根上下文执行，并保留 `$implement`、Ticket ID、失败 TC、错误原文和测试命令。例如：

   ~~~powershell
   $targetRoot = '<目标仓库绝对路径>'
   $sessionId = '<本张 Ticket 首次 thread.started.thread_id>'
   $fix = '$implement 继续当前 Ticket，仅修复未通过 TC；复验后输出测试证据，遵守目标 AGENTS.md'
   Push-Location $targetRoot
   try {
       codex exec resume --json -m gpt-6.1-sol -c 'model_reasoning_effort="medium"' $sessionId $fix
       # 用户要求 High 或其它型号时按 SEC-DISPATCH-07 替换参数。
   } finally {
       Pop-Location
   }
   ~~~

3. 续接也使用 `--json` 保存真实结构化事件/退出码与测试证据；恢复前确认原会话不在运行，避免一张 Ticket 并发执行。原 ID 丢失时先从已记录的 JSONL 或 CLI 历史核对精确映射；确实无法恢复则记阻塞，不以 `--last` 猜测。
4. Ticket 真正完成后返回 supervisor 的 `SEC-DISPATCH-04` 重新盘点；后续 Ticket 使用新的 `codex exec`。

### 坑
- `--ephemeral` 会破坏后续恢复能力；开发调用不要使用。
- 因为上一次退出码为 0 就换下一张，是跳过 TC/测试验收的常见错误。
- 新 Ticket 不使用 `resume --last` 或猜最近 Thread。

## SEC-CODEX-04 JSONL 事件和测试验收证据

### 适用
需要判断 `codex exec` 是否实际运行、测试是否通过以及能否恢复原会话。

### 步骤
1. `--json` 是**逐行 JSONL**，分别解析顶层 `type`；开始事件 `{"type":"thread.started","thread_id":"..."}`，跟踪 `item.started/item.completed`、`turn.completed/turn.failed`、`error`。注意 `thread_id` 是字段名，不是 `thread.started.thread_id` 的嵌套对象。
2. 结合真实退出码、stderr、命令调用事件、测试原始结果、文件差异与 Ticket TC；`turn.completed` 和退出码 0 只证明本轮完成，**不证明 Ticket 完成**。
3. 使用受控非提交目录存储脱敏的 JSONL、最后回复、Session ID、执行命令与验收结果；凭据不落日志。让 supervisor 复读目标项目 `tasks.md`、Ticket 状态，并依 `SEC-DISPATCH-03` 返工/阻塞。
4. 工具事件里出现 `command_execution failed`、权限被拒绝、没有实际测试或没有预期代码产出时，按 `NEEDS_FIX/BLOCKED` 处理，不自动放行。

### 坑
- 把所有 JSONL 行合并成一个 JSON 对象或错误查找 `thread.started.thread_id` 会造成会话 ID 丢失。
- 自然语言“测试通过”不能替代执行工具返回的原始结果。

## SEC-CODEX-05 $implement 直接开发与异常处理

### 适用
由独立调度器向目标仓发起单张 Codex CLI 开发会话，在同一次运行中验证目标规则、Skill 和交付结果。外部 PowerShell 启动方式见 `SEC-CODEX-06`。

### 步骤
1. **正常开发不先启动只读探针、`grill-me` 或额外的沙盒检测会话。** 按 `SEC-DISPATCH-02` 直接执行当前 Ticket 唯一的 `codex exec`。每张新 Ticket 新会话，当前 Ticket 未通过则只续接它的原会话。
2. 在本次**正式开发会话**的提示词中显式 `$implement`，要求按目标 `AGENTS.md` 读取必要规则、Ticket/Spec。直接从此次运行的工具事件检查 `implement/SKILL.md`、Shell、代码修改与测试；若缺证据，在当前会话中补查，无法完成则报告阻塞，不另开探针。
3. 出现 Windows `node_repl.exe` 文件占用、沙盒 `setup refresh` 失败、权限拒绝时应定位本地进程/沙盒日志；**不能自动升级到 `danger-full-access`、`--dangerously-bypass-approvals-and-sandbox`**。
4. Codex 当前会话到达真实终态后，由 Supervisor 核对当前 Ticket TC、测试和代码变更；没通过则原会话续接修复，通过才启动下一张独立会话。**不创建子代理、不并行调度、不重复启动 Codex 检测。**

### 坑
- `--sandbox workspace-write` 属于正常 Codex 会话的受限写入模式，Windows 仍可能初始化本地沙盒；去掉额外探针**不能保证完全不运行 Windows 沙盒**。`thread.started` 成功也不证明 Shell 正常。
- Skill 标签、自动注入 `AGENTS.md` 和真正加载自定义规则/执行开发，是三个不同的验证对象。

## SEC-CODEX-06 外部 PowerShell 串行调度与父进程隔离

### 适用
supervisor 要连续开发用户指定的单个/多个模块的全部 Ticket，希望尽可能避免「Codex 会话内部再启动 codex exec」引起的父会话 Shell 沙盒/审批限制，但仍保留每张 Ticket 独立 CLI 会话和失败续接。

### 步骤
1. **首选外部 PowerShell 执行器**：由 Supervisor 读取用户指定范围并制定队列/规则，使用独立的 PowerShell 调度脚本逐张执行。脚本须由普通 Windows PowerShell/Windows Terminal、独立任务计划程序或不处于 Codex 进程树中的外部执行器启动。**不得在正在运行的 Codex Agent 的 shell/exec_command 中执行该脚本**；否则 PowerShell 本身仍是 Codex 的子进程，无法绕开其工具沙盒。
2. **分清编排与执行**：Supervisor 负责按 `KNOW-DISPATCH-00` 确定目标仓根目录、一个/多个 `tasks.md` 的本轮范围、依赖、当前状态和所需工作；外部脚本负责**等待上一张真实终态，再启动下一张**。不创建 Codex subagent、不并行启动 Codex、不通过 Codex exec 再启动别的 Codex。
3. **首次执行入口**：脚本为每张尚未开发且依赖满足的 Ticket 构造独立 Prompt，`-C` 必须传入该 Ticket 所属目标仓根目录；示例为单张调用片段（需由脚本代入真实变量）：

   ~~~powershell
   $targetRoot = '<根据本轮用户路径确定的目标仓绝对路径>'
   $ticketPath = '<当前唯一 Ticket 的绝对路径>'
   $prompt = '$implement' + [Environment]::NewLine +
       "仅开发当前 Ticket：$ticketPath。先读目标仓 AGENTS.md、规则、Spec；完成测试并报告证据，不启动其它 Ticket。"
   $prompt | codex exec -C $targetRoot --sandbox workspace-write --json -m gpt-6.1-sol -c 'model_reasoning_effort="medium"'
   # 用户要求 High 时把 medium 改为 high；模型 ID 仍需以当前 CLI 实际支持情况为准。
   ~~~

4. 外部调度器**一次只执行一张**：从当前 `tasks.md`、TC、持久化记录和依赖复算可执行 Ticket，启动前记 `STARTING`；收到 `thread.started` 后立即持久化 `thread_id`。等待子进程结束，把**stdout JSONL 和 stderr 分开存储**，保存真实退出码/测试结果，独立验收；未通过就对同一 ID `codex exec resume` 修复，通过并回写后才重新选下一张。绝不对全部 Ticket 用简单 `foreach` 不验收地连续发包。
5. **跨轮恢复**：脚本/调度记录保存 `目标仓 + 模块 + Ticket ID + thread_id + 最后终态/错误 + 测试证据`；进程中断后先盘点既有会话和当前磁盘状态，有可续接会话先恢复；不存在有效会话且确属未开始的 Ticket 才开新会话。依赖阻塞不擅自扩大开发范围。
6. **故障边界**：外部 PowerShell 仅绕开“父 Codex 的命令执行工具”这一层，不保证子 Codex 自己的 Windows 沙盒能正常初始化。此前 `node_repl.exe` 被占用引发的 `setup refresh had errors`，**即使从外部 PowerShell 启动也可能复现**；遇到时保留日志、暂停有关 Ticket 并排查文件占用，不自动使用危险权限参数。
7. **已实现的脚本入口**：本仓 `scripts/Invoke-CodexTicketDispatcher.ps1`，操作指引在 `docs/codex-ticket-dispatcher.md`，本地模拟测试为 `tests/Smoke-Dispatcher.ps1`。脚本需要本轮明确指定模块/tasks.md 和人工审定的 AcceptanceManifest 才允许正式派发；无验收清单时只可 `-DryRun`。它实现受控串行启动、状态原子持久化、PID/会话 ID、JSONL/stderr/退出码、Git 状态快照、独立运行测试与原会话续接；循环/越界/缺依赖或证据不足时停止，不自动跳票。**这些模拟测试不能证明真实 Codex Windows 沙盒已可用。** 必须由 Codex 进程外的独立 PowerShell 执行器启动；只在 Codex shell 中调用脚本仍是嵌套，不得报告为已解决沙盒问题。
8. **开发进度可观察性**：Codex 调度器按批次生成受控 `progress.log`，终端打印带时间戳的 PLAN/STARTING/RUNNING/SESSION/VERIFY/TEST/DONE/BLOCKED/PAUSED_QUOTA 等事件。每张票打印真实 Ticket 文件、模块、CLI、模型 ID 和 Medium/High、Session、PID、真实测试收据以及 `已独立验收数/总数`。`turn.completed` 仅启动独立验收，不能被标 DONE；长时间无工具事件时按实际进程存活报告等待状态。日志在 `.supervisor-runtime/<batch>/progress.log`，不会自动转发到 ChatGPT 网页对话，Supervisor 必须根据真实可见证据向用户同步阶段信息。
9. **额度耗尽暂停实现**：现有 `scripts/Invoke-CodexTicketDispatcher.ps1` 从 CLI JSONL 错误和 stderr 判断明确的额度耗尽，在 CLI 子进程终态后记录 `PAUSED_QUOTA`、保留原 Session 与日志、整个批次停止下发，退出码 3；普通重启和 `-RetryBlocked` 不会解除，用户确认额度恢复并明确授权后使用 `-ResumeAfterQuota` 才能继续原会话。CLI 报错只有单独 `429` 或短期限流不能自动断言额度耗尽。模拟测试见 `tests/Smoke-QuotaPause.ps1`，它不证明真实模型额度状态。

### 坑
- 只是把 `codex exec` 包在 `.ps1`，再由 Codex 的 shell 启动，仍然是**Codex → PowerShell → Codex** 的嵌套调用。
- 外部脚本串行不等于自动验收；没核对 TC、真实测试、依赖、状态回写就启动下一张，仍然违反 `KNOW-DISPATCH-00`。
- 外部启动方式不会关闭子 Codex 的 `workspace-write` 沙盒，也不应以绕过安全控制为目的。
