# Antigravity CLI 独立 Ticket 会话

## SEC-AGY-00 Antigravity CLI 适用边界

### 适用
supervisor 被指定用 Antigravity Headless CLI 逐张开发用户指定模块或 `tasks.md` 中的 Ticket。

### 步骤
1. 此文件维护 Antigravity 的入口、Headless、会话、Skill、权限和故障；任务范围、依赖、单/多模块顺序、验收、返工、全量完成统一按 `KNOW-DISPATCH-00`。
2. **工作区必须是本次指定任务所属的目标开发仓根目录**；supervisor 不改目标业务代码，也不把上次历史目标目录当作这次的默认值。目标 CLI 自行按对应目标根 `AGENTS.md` 加载适用规则。
3. Ticket 之间是独立会话、按依赖单个串行；同一 Ticket 未验收时恢复其保存的 `conversation_id`。

### 坑
- 旧经验把工作区固定成后端目录是错误调度边界；由本轮路径动态决定目标根。
- Antigravity 的 Slash 机制独立于 Codex，不能用 Codex 的 Skill 检测方式代替。

## SEC-AGY-01 Headless 入口辨识与预检

### 适用
`agy` 无效、启动了 IDE 而非 CLI、Headless 参数无响应或未登录。

### 步骤
1. Windows 的 `agy.cmd` 可能只是 IDE 启动器，退出码 0 且没有正文不等于开发成功；在实际主机先检查：

   ~~~powershell
   Get-Command agy -ErrorAction SilentlyContinue
   $agy = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
   if (-not (Test-Path -LiteralPath $agy)) { throw 'Antigravity Headless CLI 不可用' }
   & $agy --version
   & $agy --help
   & $agy models
   ~~~

2. **2026-10-08 历史验证**：`ZC2026090353` 的 `$env:LOCALAPPDATA\agy\bin\agy.exe` 曾为 `1.3.1`，PATH 未必识别 `agy`。每次执行前仍要在目标主机复核绝对路径、版本、帮助与认证。
3. **首次正式 Ticket 调用即可验证 Headless 输出**，不在每张任务前另跑 `--mode plan` 探针。仅当可执行文件身份或 Headless 能力有疑点时，才在目标根用 `--mode plan --output-format json` 做针对性诊断；空 stdout 或退出码 0 不能证明开发成功。
4. `/implement` 是否为真正原生 Skill，要查当前环境展开证据；不得加 `--disable-slash-commands`。

### 坑
- IDE 启动器告警“unknown option -p”却退出 0，必须识别 Headless `agy.exe`。
- 无法定位 Headless 可执行文件要阻塞并报告，而非用 IDE 启动器冒充。

## SEC-AGY-02 单轮执行、新会话与原 Ticket 续接

### 适用
Antigravity 首次开发当前 Ticket 或对尚未验收的**同一 Ticket** 继续修复。

### 步骤
1. 按用户指定范围确定 `$targetRoot` 与唯一 Ticket，并按 `SEC-DISPATCH-07` 选择 Gemini 3.8 Flash Medium/High 或用户指定的真实 `--model` 参数；进入目标仓核对当前 CLI 帮助。首次任务**不加** `--conversation` 或 `--continue`：

   ~~~powershell
   $targetRoot = '<真实目标仓库绝对路径>'
   $agy = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
   $prompt = '/implement 仅开发 Ticket <ID>：<Ticket绝对路径>；先加载目标 AGENTS.md、按 SEC 读取规则与 Spec；逐项测试验收；不得自行启动其他 Ticket。'
   Push-Location $targetRoot
   try {
       & $agy -p $prompt --model gemini-3.8-flash-medium --output-format stream-json --print-timeout 30m
   # 用户要求 High 时改为 gemini-3.8-flash-high。
   } finally {
       Pop-Location
   }
   ~~~

2. `-p/--print` 是非交互模式，`--output-format text|json|stream-json` 在支持的版本上可用；`--print-timeout` 根据实际任务与 `--help` 选择。监控机器输出中的 `init/step_update/result/usage`，保留终态、实际退出码与日志。
3. 从真正的机器事件取得该 Ticket 的 `conversation_id`，保存 `(目标根,模块,Ticket ID)` 映射；若首次调用没有会话 ID，不能假装可精准续接。
4. 同一 Ticket 仍有未通过 TC、测试或权限问题时，在目标根用 `agy --conversation <conversation-id> -p <修复提示> --model gemini-3.8-flash-medium --output-format stream-json` 续接并保留终态/测试事件（执行前核对当前版本帮助）；只修复本 Ticket。不要用可能接错任务的 `--continue`。
5. 新 Ticket 另开不带历史 ID 的 `agy -p`；实际验收、任务状态回写及下一张选票交由 supervisor 的 `SEC-DISPATCH-03/04`。

### 坑
- 返回 `SUCCESS` 或退出 0，不代表所有测试都成功。
- `--input-format stream-json` 是特殊 stdin 协议，不能与普通 `-p` 示例混用；必须按 `--help` 配对输出协议。
- 同 Ticket 不应该每次重开新 `conversation_id`。

## SEC-AGY-03 目标规则、Headless 权限与验收

### 适用
Antigravity 无法运行 Shell/写文件/测试，或规则没生效导致交付不完整。

### 步骤
1. 当前 Ticket 需按**目标项目**自己的 `AGENTS.md` 路由实际存在的 MDC、Spec 锚点与知识切片；supervisor 仅负责确认加载/执行证据，不能拿本仓 `AGENTS.md` 替代目标项目规则。
2. 查看当前主机 `$env:USERPROFILE\.gemini\antigravity-cli\settings.json`（若存在）里的 `permissions.allow/ask/deny`；Windows Headless 中 `ask` 可能无法进行交互而拒绝。按目标项目允许范围检查权限，不能默认启用 `--dangerously-skip-permissions`。
3. `--sandbox` 只改变隔离行为，不等于获取任意权限；出现真实拒绝，记录命令、stderr 和机器事件并返回 supervisor 的 `BLOCKED/NEEDS_FIX`。
4. 验收必须同时包含正确 Skill 展开、交付文件、真实测试命令/结果、适用 TC、目标 `tasks.md` 状态和受控 Git 差异；完成后回到 `SEC-DISPATCH-04` 检查下一张。

### 坑
- Headless 的权限软拒绝可能只表现为最终文本“完成”但无真实工具执行。
- 不能复制某个后端项目的 Git 规则来管所有外部仓；以当前目标仓自己的规则为准。
- 不要因任务失败就升级危险权限。

## SEC-AGY-04 Antigravity Slash/Skill 触发证据

### 适用
执行 `/implement` 开发 Ticket 或检查 Antigravity 原生命令展开能力。

### 步骤
1. 正常开发**不额外跑 `/grill-me` 探针**；只有正式 Ticket 出现 Slash/Skill 展开错误需要定位时，才可在目标仓使用只读 `/grill-me` 并检查 `conversation_id`、`init` 和终态。这不构成 implement 完成证明。
2. 正式 Prompt **以 `/implement` 开头**，让 Antigravity 原生 Slash 入口具备正确展开位置；Supervisor 记录统一意图 `implement` 即可，不在 Slash 前面拼 `$implement`。禁止 `--disable-slash-commands`，并核实目标主机 `implement/SKILL.md` 的实际可用性。
3. 在 `stream-json` 的 `init.expanded_commands` 检查 `implement` 的展开，再核对 `result.status` 为 `SUCCESS`、权限事件和真实工具/测试结果；若当前版本事件字段不同，以实测 `--help`/机器输出为准，缺证据不能宣称成功。
4. 保存首次 `conversation_id` 以续接失败 Ticket；下一 Ticket 启动全新对话，绝不沿用上个 ID。

### 坑
- 只看到自然语言“已加载 Skill”不能通过门禁。
- `grill-me` 能展开不代表 `implement` 能展开；必须分别核对。
- 为排障禁用 Slash 或绕过权限，会使开发结果不可验证。
