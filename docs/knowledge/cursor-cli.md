# Cursor CLI 独立 Ticket 会话

## SEC-CUR-00 Cursor CLI 适用边界

### 适用
supervisor 接到用户指定的 Cursor CLI 开发任务，需要将一张 Ticket 交给目标仓库中的 Cursor Headless 会话。

### 步骤
1. 本文件只维护 Cursor 的安装、认证、Headless、Skill、权限和会话恢复；选定范围、单/多模块 `tasks.md`、依赖、验收、状态回写、异常恢复统一由 `KNOW-DISPATCH-00` 定义。
2. 工作目录是**用户本次指定的任务路径所属的目标开发仓**，不是 supervisor，也不固定为任何历史项目；先在目标仓加载其 `AGENTS.md`、适用项目规则、Ticket/Spec 锚点。
3. 开发遵守当前目标项目的 Git、权限、敏感信息和提交规范。此文件的历史实例路径仅为验证记录，不得当作调度限制。

### 坑
- 先前的“只允许 digital-logistics 当前端”约束不适用于 supervisor；本仓专门调度用户指定的**外部目标仓**。
- Cursor 负责当前 Ticket 的实现，supervisor 负责下一 Ticket 选票与外部验收；不能让 Cursor 自行扩大发包范围。

## SEC-CUR-01 Windows 安装、认证与工作区信任

### 适用
调用 Cursor 时 PATH 不识别、登录失败、Workspace Trust Required 或权限拒绝。

### 步骤
1. 在目标执行主机核验 `Get-Command agent,cursor-agent -ErrorAction SilentlyContinue`；必要时检查 `$env:LOCALAPPDATA\cursor-agent\agent.cmd`。在主机上运行 `--version`、`--help`、`status`，记录当前实际版本、入口和认证状态：

   ~~~powershell
   $cursor = Join-Path $env:LOCALAPPDATA 'cursor-agent\agent.cmd'
   if (-not (Test-Path -LiteralPath $cursor)) { throw 'Cursor CLI 不可用' }
   & $cursor --version
   & $cursor --help
   & $cursor status
   ~~~

2. **2026-10-08 实测**：`ZC2026090353` 的 `agent.cmd` 为 `2026.10.01-e373342`，PATH 未必命中。`CURSOR_API_KEY` 已存在于 Machine（系统）环境变量，但远程启动的 PowerShell `Process` 环境没有继承它；**必须先按 `SEC-CUR-05` 加载到当前进程，才能正确查询模型与调用 CLI**。此前在没有加载 Key 时 `status` 可能显示已登录，但 `models` 报 `Authentication required`；加载 Key 后 `status` 反而可能显示 `Not logged in`，而 `models` 和实际模型请求均成功。`status` 不是 API Key 模式唯一验收依据。
3. **API Key 模式优先按 `SEC-CUR-05` 从当前 Process/User/Machine 环境变量加载已有 `CURSOR_API_KEY`，临时注入当前 PowerShell 进程，再由 `agent models` 和真实只读请求确认认证**；不要打印、硬编码、日志记录或重新写入 Key。工作区信任 `--trust` 仅用于明确可信的工作区，不代替写权限审批；`--force` 不是常规认证/信任解决方案。
4. 实际命令参数、可用模式和续接格式以目标主机当前 `--help` 为准。`agent models` / `agent --list-models` 需要真实可用的认证；若返回 `Authentication required`，先核对当前进程是否已从持久环境变量加载 Key，而不是重复 `agent login` 或盲目重新安装。

### 坑
- PATH 里没有 `agent` 并不代表安装不存在；先检查绝对 `agent.cmd` 路径。
- **Machine/User 已有 Key，Process 未继承**：这是本次实测的核心原因；在调用 Cursor 的**同一个 PowerShell 进程**中读取并赋给 `$env:CURSOR_API_KEY`，确保后续子进程继承，切勿在命令行参数中写 Key。
- **`agent status` 和模型调用结果矛盾**：API Key 模式以 `agent models` 和实际请求结果判断可用性；不要仅凭 `Not logged in` 认定认证失败。
- `--trust` 不能隐式授予任意 Shell 或项目写权限。

## SEC-CUR-02 Headless 单轮调用与结构化输出

### 适用
每张新的 Ticket 使用 Cursor CLI 创建独立的 Headless 开发会话并保留机器日志。

### 步骤
1. Supervisor 根据用户路径确定目标根和唯一 Ticket；**必须先按 `SEC-CUR-05` 在执行 CLI 的 PowerShell 进程加载已有 API Key**，再按 `SEC-DISPATCH-07` 选已验证的 `grok-4.7-medium` / `grok-4.7-high` 或用户指定型号。目标仓须完成 Workspace Trust（不要对未知目录直接 `--trust`）；首次下发**不带** `--resume` / `--continue`：

   ~~~powershell
   $targetRoot = '<真实目标仓库绝对路径>'
   $cursor = Join-Path $env:LOCALAPPDATA 'cursor-agent\agent.cmd'
   $prompt = '/implement 仅开发 Ticket <ID>：<Ticket绝对路径>；先加载目标 AGENTS.md 和适用规则、Spec 锚点，TDD 验收并返回证据；不自行启动下一 Ticket。'
   Push-Location $targetRoot
   try {
       # 先按 SEC-CUR-05 在本 PowerShell 进程加载已有 CURSOR_API_KEY
       $cursorModel = 'grok-4.7-medium' # 用户说 High 则用 grok-4.7-high
       & $cursor -p --model $cursorModel --output-format stream-json $prompt
   } finally {
       Pop-Location
   }
   ~~~

2. `-p/--print` 用于 Headless；`--mode=ask`、`--mode=plan` 用于分析/规划，正式开发时选择支持实施的 Agent 模式。确认当前版本支持 `--output-format stream-json`，逐行读取直到终态，不能只取首行。
3. 保存每张 Ticket 的 Cursor 会话/Chat ID、进程退出码、stderr、`type/subtype/is_error/result`、命中工具事件、测试证据和实际文件差异。若事件无法解析/工具未执行，返回 supervisor 的 `NEEDS_FIX/BLOCKED`。
4. 统一开发意图由 Supervisor 记录为 `implement`；**Cursor Prompt 以 `/implement` 开头**，不要在它前面拼 `$implement` 而影响 Slash 识别。必须在当前版本的结构化结果中核验真实 Skill 展开/加载；不可仅凭提示词宣称成功。

### 坑
- 只有最终回复却没有落盘和测试不能标记 Ticket 完成。
- `--output-format json` 最终响应不一定携带全部工具证据；排障优先使用结构化流。
- 一个 Headless 调用只对应一张 Ticket，不让 Cursor 在内部再批量下发其它 Ticket。

## SEC-CUR-03 目标规则、原 Ticket Resume 与权限

### 适用
同一 Ticket 未通过验收，需要继续它的原会话，或核对 Cursor 对目标仓库的规则/权限。

### 步骤
1. 确认目标 `AGENTS.md` 与其真正存在的 `.cursor/rules/*.mdc` / 其它项目规则文件；不要假定所有 `alwaysApply:false` MDC 会无条件自动加载。要求 Cursor 按 Ticket 涉及范围精确读取，检查实际工具读取记录。
2. 原 Ticket 未通过：用已保存的准确 `chat-id`，在目标根按当前 `agent --help` 调用 `agent -p --resume <chat-id> --model <已核验的Cursor模型标识及档位> --output-format stream-json <修复提示>`；保存续接的终态/测试事件。修复提示只含当前 Ticket 未通过的 TC、错误和相关锚点。**同 Ticket 同会话，新 Ticket 新 `agent -p`**，不能用 `--continue` 猜。
3. 权限检查可参照用户级 `$env:USERPROFILE\.cursor\cli-config.json` 及目标仓自身 `.cursor\cli.json`（若存在）的 `permissions.allow/deny`。任何无人值守写入/命令授权遵循目标项目策略；`--force/--yolo` 可能放宽权限，**不得为修复失败默认追加**。
4. Cursor 只处理当前唯一 Ticket；不能把目标项目 A 的 `AGENTS.md`、Git 工作树、会话或权限套用给项目 B。验收与状态回写归 `SEC-DISPATCH-03/04`。

### 坑
- `--continue` 可能指向其他任务，必须精确用保存的 Chat ID。
- 不同 Ticket 共用会话会污染范围与检查结果。
- 用户指定多个项目时，必须针对每个项目独立切换工作根、读取规则。

## SEC-CUR-04 Cursor Skill 触发证据

### 适用
正式开发使用 Cursor 原生 `/implement`，需确认真实 Skill 展开而非模型模拟调用。

### 步骤
1. **默认直接执行正式 Ticket，不额外跑探针。** 仅当原生 `/implement` 的解析/展开异常时，才可在目标仓用只读 `agent -p --output-format stream-json '/grill-me 只输出第一轮问题，不修改文件'` 辅助定位；这不替代 implement 的真实执行。
2. 正式 Prompt **以 Cursor 已确认可用的 `/implement` 为首个命令**，后面附唯一 Ticket 和目标规则要求；统一意图名称 `implement` 在调度记录保留即可。检查用户/项目中实际存在的 `implement/SKILL.md`；历史用户级位置 `C:\Users\fan\.cursor\skills\implement\SKILL.md` 只用于辅助定位。
3. 在 `stream-json` 查找 Skill 原生展开或读取 `implement/SKILL.md` 的 `readToolCall` 等工具证据，再核验开发动作、权限事件与完整终态；没触发就阻塞，不降级成普通“开发 Ticket”提示。
4. **2026-10-08 历史观察**：`/grill-me` 曾触发读取 `grilling/SKILL.md`，只能证明该测试环境的 `grill-me` 入口有效，**不能代替 implement 验证**。

### 坑
- 单看提示词写着 `/implement` 或结果“已应用 Skill”没有机器证据，不能放行。
- 不能为了探测 Skill 而额外修改真实 Ticket；正常开发在正式会话内核对事件，异常时才使用只读诊断。

## SEC-CUR-05 CURSOR_API_KEY 环境变量认证与 Grok 4.7 模型确认

### 适用
Cursor CLI 可以运行但 `agent models` / `--list-models` 返回 `Authentication required`，或 `status` 与模型调用结果矛盾；通过 Windows 已有 `CURSOR_API_KEY` 调用 Grok 4.7 Medium/High。

### 步骤
1. **先区分两种认证方式**：`agent login` 负责交互式账号登录；本流程通过 `CURSOR_API_KEY` 做 API Key 认证，不需要重复执行 `agent login`。**`agent status` 不能单独验证 API Key**：本机实测未注入 Key 时曾显示已登录但请求报 `Authentication required`；注入 Key 后显示 `Not logged in`，但模型查询和真实请求成功。
2. **本机 Windows 关键问题**：`ZC2026090353` 在 2026-10-08 发现 `CURSOR_API_KEY` 存于 `Machine` 作用域，但远程执行器启动的 PowerShell 进程没有继承。不能只看 `[Environment]::GetEnvironmentVariable('CURSOR_API_KEY','Machine')` 是否存在；Cursor 子进程实际读取的是当前进程的 `$env:CURSOR_API_KEY`。**仅在执行 CLI 的那个 PowerShell 进程内，从已有 Process/User/Machine 变量读取，必要时注入 Process**（不打印密钥，不更改机器或用户级存储）：

   ~~~powershell
   $cursor = Join-Path $env:LOCALAPPDATA 'cursor-agent\agent.cmd'
   if (-not (Test-Path -LiteralPath $cursor)) {
       $cursor = (Get-Command agent -ErrorAction Stop).Source
   }
   if ([string]::IsNullOrWhiteSpace($env:CURSOR_API_KEY)) {
       $key = [Environment]::GetEnvironmentVariable('CURSOR_API_KEY', 'User')
       if ([string]::IsNullOrWhiteSpace($key)) {
           $key = [Environment]::GetEnvironmentVariable('CURSOR_API_KEY', 'Machine')
       }
       if ([string]::IsNullOrWhiteSpace($key)) {
           throw '未找到现有 CURSOR_API_KEY；需要用户提供安全的认证配置'
       }
       $env:CURSOR_API_KEY = $key
       Remove-Variable key
   }
   # 在同一 PowerShell 进程中继续调用 Cursor；不要输出 Key
   $models = & $cursor models 2>&1
   $exitCode = $LASTEXITCODE
   if ($exitCode -ne 0) { throw 'Cursor 模型查询失败；检查实际进程环境、Key 权限和原始错误' }
   $modelText = $models | Out-String
   foreach ($id in @('grok-4.7-medium', 'grok-4.7-high')) {
       if ($modelText -notmatch [regex]::Escape($id)) { throw "模型不可用：$id" }
   }
   'Cursor Grok 4.7 Medium/High 模型列表验证成功'
   ~~~

3. **确认的 `--model` 参数**：本机 `agent models` 返回 `grok-4.7-medium`（Grok 4.7 Medium）与 `grok-4.7-high`（Grok 4.7 High），两者均通过真实只读推理请求验证成功。默认 Ticket 开发用 `--model grok-4.7-medium`；用户说 High 则只改为 `--model grok-4.7-high`。不要使用未验证的 `grok-4.7`、假定 `[effort=...]` 与独立模型 ID 等价，或静默切换到 Auto。
4. **只在首次配置、认证出错时验证一次请求**：先进入自行创建的可信临时空目录，非交互模式的 Workspace Trust 可在**确认该目录可信**时使用 `--trust`；再进行只读问答（本机实测成功命令的形式）：

   ~~~powershell
   $testDir = Join-Path $env:TEMP 'cursor-cli-auth-readonly-check'
   New-Item -ItemType Directory -Path $testDir -Force | Out-Null
   Push-Location $testDir
   try {
       & $cursor --trust -p --mode ask --model grok-4.7-medium --output-format json '只回答 CURSOR_API_KEY_OK，不调用工具，不读取或修改文件'
       if ($LASTEXITCODE -ne 0) { throw 'Cursor API Key 实际请求失败' }
   } finally {
       Pop-Location
   }
   ~~~

   本机实测 Medium 返回 `CURSOR_API_KEY_OK`、退出码 0、`subtype: success`，High 返回 `CURSOR_HIGH_OK`、退出码 0、`subtype: success`。**日常每张 Ticket 不重复执行此探针**。
5. **正式开发**：模型列表/认证确认后，**同一个已注入 `$env:CURSOR_API_KEY` 的 PowerShell 进程**，在用户指定的目标仓根目录运行 `& $cursor -p --model grok-4.7-medium --output-format stream-json '/implement ...'`；High 改成 `grok-4.7-high`。`--trust` 只能在目标仓已确认可信时使用，未经信任应由用户进行交互式信任确认。保存实际 session ID，失败按 `SEC-CUR-03` 精确续接；若外部顺序调度器为每张 Ticket 新开 PowerShell **进程**，每个新进程都必须重新从持久环境加载 Key，不能假定会继承另一个已退出进程的 `$env:` 赋值。
6. **诊断顺序**：命令找不到 → 定位实际 `agent.cmd`；`Authentication required` → 查看 Process/User/Machine 是否有 Key、在**当前进程**注入并重试 `models`；`Workspace Trust Required` → 仅对可信目标仓完成交互式信任或使用 `--trust`；模型不存在 → 重新查看 `models`；提示词 Skill 没执行 → 按 `SEC-CUR-04` 查结构化工具事件；权限被拒绝 → 核对目标仓规则，不以 `--force`、`--yolo` 绕过。

### 坑
- `Machine` 已存在 Key 不表示远程服务生成的新 PowerShell 自动继承；**必须在真正调用 `agent` 的进程中设置 Process 环境变量**，只在该进程及子进程内生效。
- `agent status` 的账号登录状态与 API Key 请求认证可能不同；以 `models` 和真实 API 请求判定是否可用。
- `--trust` 解决工作区信任，不解决 API Key；`--force` 影响命令权限，不应当作登录参数。
- 不把真实 Key 值、用户邮箱、会话 ID、Token 或完整含密钥的环境变量输出写入文档、脚本、日志及提示词。
