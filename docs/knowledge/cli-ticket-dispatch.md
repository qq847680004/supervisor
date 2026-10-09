# 独立 CLI Ticket 顺序调度与验收闭环

## SEC-DISPATCH-00 Supervisor 调度边界与共用约束

### 适用
用户在 supervisor 中指定一个或多个外部项目模块目录或 `tasks.md`，要求使用某一种开发 CLI 顺序完成其中的 Ticket。

### 步骤
1. **角色**：supervisor 只解析任务、调度独立 CLI 进程、保留会话与证据、检查状态、验收、续接和汇总；目标 CLI 才在用户指定的**目标开发仓库**中改代码、测试、按目标项目规则回写。禁止把 supervisor 作为目标开发根目录。
2. **执行模型**：单任务队列、同一时刻最多一张 Ticket 被开发。每张新 Ticket 对应一个新 CLI 会话；同张 Ticket 未验收则仅续接它的原 session/conversation ID。**无需 subagent、fork、多代理协作或并行 worktree 调度**；由命令启动器依次调用独立 CLI 即可。若 supervisor 自身运行在 Codex 中，必须先确认其 shell 能调用外部进程；沙盒失败时不能以文字回答冒充下发成功。
3. **权限与归属**：先读 supervisor 两条经验规则；目标开发会话必须在目标仓库根目录加载该仓的 `AGENTS.md` 与相关规则、Spec、Ticket。目标项目的 Git/提交/安全边界高于通用 Skill；supervisor 不复制或覆盖它们。
4. **结果判定**：不能用退出码 0、自然语言“已完成”、`tasks.md [x]` 中任何单一信号代替完成验收。无可恢复会话、权限拒绝、真实依赖缺失、不可修复的测试/契约错误应记录为 BLOCKED，不得空循环。

### 坑
- Supervisor 不是后端/前端开发仓；目标根目录完全由用户本次指定的路径确定。
- CLI 新进程不等于“多代理架构”，但如果由一个 Codex 进程内的 shell 启动，会受到该 Codex 的沙盒限制；失败要报告，不能绕过。

## SEC-DISPATCH-01 单/多模块路径输入、任务盘点与依赖选票

### 适用
用户提供 `D:\2026work\work\digital-logistics\docs\scratch\data-governance` 或该目录下的 `tasks.md`，也可以同时提供多组模块/任务清单。

### 步骤
1. 将每个**用户显式指定**的绝对路径规范化（Windows 的 `Resolve-Path -LiteralPath`）；目录入口定位该目录直属 `tasks.md`；文件入口只接受存在的 `tasks.md`。去重但保留用户给定的顺序。路径不存在、无 `tasks.md`、含歧义时只报告相应路径，**不自动扫描其它模块**。
2. 对每份 `tasks.md`，向上定位唯一**目标开发仓库根目录**（以实际仓库边界与根 `AGENTS.md` 核对）；**清单中 `docs/scratch/.../ticket-*.md` 这样的路径相对目标仓库根目录解析**，仅明确写为 `./ticket-*.md` 的模块内相对路径才相对该 `tasks.md` 目录解析，绝对路径只接受用户明确授权且属于当前目标仓的文件。用 `Resolve-Path -LiteralPath` 校验路径存在、归属仓库及大小写/规范化后位置，拒绝越界与歧义；不得将 `supervisor` 作为 `-C`，多仓任务各用自己的目标根。
3. 读取指定范围内全部 `tasks.md`，解析每行 `[ ]/[x]`（同时支持无序列表 `- [ ]` / `* [ ]` 及有序数字列表 `1. [ ]`）、仓库相对 Ticket 路径、行级 `Blocked by` 及顺序；Ticket ID 以文件首行 `# Ticket: [T-...]`（支持可选方括号）为准。**分别从任务行和 Ticket 的 `Blocked by` 字段用 Ticket ID 模式（如 `T-GOV-001`）提取全部 ID，去重、排序后按集合比较；兼容破折号、英文逗号、中文顿号、反引号和空格，`None` 为无依赖，不能只按逗号 `split`。** 同 ID 重复、文件重复引用、依赖集合真实冲突才阻塞，并核对状态和 `TC-*`；建立 `(目标根,模块,Ticket ID,任务文件,Ticket文件,依赖)` 映射。
4. 调度前先**盘点既有状态与前置校验**：`[x]` 也须核查 Ticket 的适用 `TC-*` 勾选、交付物和可信测试/验收记录；不一致记为 `NEEDS_FIX`，已验证完成记为 `DONE`。对当前最靠前的未完成 Ticket（`[ ]`），在实际下发 CLI 前执行一次等同于完成时标准的**前置独立验收校验**；若已完成则直接回写 `[x]` 并标记 `DONE` 推进下一张；若未完成且存在有效历史会话，必须在同一窗口/同一会话续接，无历史会话才作为全新任务启动。
5. 建立选定范围内依赖图、校验循环/缺失/矛盾。跨模块、跨项目引用只核验**明确可定位**的依赖状态，不擅自把范围外的 Ticket 放入执行队列。依赖未验证完成则 `BLOCKED_BY_DEPENDENCY`；清单冲突/循环记明确阻塞原因。
6. 按用户指定顺序优先，其次模块输入顺序、`tasks.md` 顺序，选择**第一张**未完成且依赖通过的 Ticket。优先恢复已有该 Ticket 会话；无既有会话才创建新会话。只要上一张仍运行，不启动另一张。
7. 每张通过验收后必须重新读取**全部指定范围**的任务状态与受影响依赖，再重新选票，直到每个指定清单均已验证全 `[x]`；若仅剩不可执行/不可恢复的任务则停在阻塞报告，不得把“没有可选票”说成“全部完成”。

### 坑
- 用户只传某模块目录时，不应顺手执行同仓其它模块。
- 跨模块 `Blocked by` 是放行条件，不是扩大发包范围的许可；范围外未通过即阻塞依赖它的 Ticket。
- `Status: ready-for-agent`、`[x]` 或旧日志都不能单独证明完成；每轮必须复查现场。
- `tasks.md` 用逗号、Ticket 用顿号或破折号表达依赖是正常格式差异；应抽取实际 Ticket ID 集合后比较，不能误报冲突。
- 目标项目若在 `docs/` 等子目录建有独立 Git 仓库，单纯 `git rev-parse --show-toplevel` 会停在子目录，导致根目录与相对路径拼接为 `docs/docs/...` 且脱离主工程代码；必须向上追溯包含目标 `AGENTS.md` 的最外层业务开发仓根。
- Windows PowerShell 5.1 调度脚本含多字节中文字符时必须保留 UTF-8 BOM，否则多字节编码错断会破坏引号导致语法解析异常。
- 提取 Ticket ID 模式时若依赖 `\b` 单词边界，当 ID 前置字符为非 ASCII 的中文标点或 CJK 汉字时（CJK 在 Unicode 正则中属于 `\w` 字符类），单词边界将失效导致漏匹配并误报依赖冲突；必须采用前后环视 `(?<![A-Za-z0-9])T-...(?![A-Za-z0-9-])` 确保提取绝对健壮。

## SEC-DISPATCH-02 指定 CLI 与每 Ticket 独立会话下发

### 适用
已识别目标仓/目标 Ticket、依赖满足，需要按用户指定 CLI 启动它的新开发会话。

### 步骤
1. 用户指定 `codex exec`、Cursor CLI 或 Antigravity CLI 则**只用该 CLI**；未指定则先明确执行器。读取其 `KNOW-CODEX-00` / `KNOW-CUR-00` / `KNOW-AGY-00` 切片；**模型和 Medium/High 档位统一按 `SEC-DISPATCH-07` 解析，完成 CLI 参数映射后才启动 Ticket**。同一轮任务首次使用该 CLI 时核验入口、版本、认证及必要权限，后续 Ticket 复用，真实错误时再诊断，不为每张 Ticket 重复启动探针。
2. 首次调用只针对**当前选中的唯一 Ticket**，在其**目标根目录**启动非交互 CLI，确保工作区、代码/测试权限和目标项目规则匹配。Codex 用 `codex exec -C <目标根> --sandbox workspace-write --json`；Cursor/Antigravity 在目标根切换目录后用各自 Headless 入口。**优先由 Codex 进程外的 PowerShell 调度器顺序启动 Codex**（见 `SEC-CODEX-06`）；仅写出 `.ps1` 不等于已经有可运行调度器，必须确认脚本由独立执行器启动。不要运行多代理、并发任务或无关项目命令。
3. 首次提示词模板（实际注入**绝对路径**与已核验的 Ticket ID，不复制全量 Spec）：

   ~~~text
   <CLI 原生 Skill 入口：Codex=$implement；Cursor/Antigravity=/implement>
   仅开发当前 Ticket：<ID>，文件：<绝对 ticket.md 路径>
   目标仓库根目录：<绝对目标根>；任务清单：<绝对 tasks.md 路径>
   【强制遵守项目规则】：必须强制严格遵守目标项目根目录 AGENTS.md 进行开发：
   1. 全局强制规则（Always Apply）必须首先强制加载并无条件严格遵守；
   2. 领域按需规则（Rules Index）严格按照路径/代码特征与触发动词按需读取对应 .cursor/rules/*.mdc；
   3. 精准读取当前 Ticket 的 docs/specs 锚点（SEC-）并执行 implement/SKILL.md 标准流程。
   【开发与回写规范】：严格采用 TDD 流程交付业务代码与单测，确保本地测试通过；本地测试通过后仅允许将当前 Ticket 内对应 - [x] **TC-* 与 tasks.md 对应行回写为 [x]；回写时强制使用 UTF-8（无 BOM）保存，严禁破坏中文或写成乱码；严禁篡改任何 Spec 契约、Ticket 业务需求或 tasks.md 其他内容；不得扩大目标模块，不调度其它 Ticket/CLI/Agent，不绕过权限，不自动 push。
   ~~~

4. `implement` 是共同开发意图，但**实际入口按 CLI 分开构造**：Codex 首行 `$implement`，Cursor/Antigravity 首行 `/implement`（如果该版本已确认具备原生 Slash 入口），后续正文再写目标路径、规则、Ticket 与测试要求。不能把 `$implement /implement` 拼在同一行当作通用命令。**直接启动正式 Ticket 会话并在本次结构化结果里核对实际规则/Skill/代码/测试**；失败保留该 Ticket 会话处理，不每张另开探针。
5. **每张 Ticket 在进程启动前就记录 `STARTING`，在收到会话 ID 后立即持久化** `(目标根、模块、Ticket ID、CLI、会话ID、进程ID、开始时间、JSONL/stdout/stderr日志路径、退出码、最后状态及测试证据)`；若启动后进程中断可据此恢复。记录在 Supervisor 的受控非提交位置，采用原子写入或先写临时文件再替换，避免断电留下半截状态。**同一张 Ticket 以 `(规范化目标根 + Ticket ID)` 为唯一键，重跑不能重复下发。**
6. 逐行处理 **stdout 的结构化事件**，stderr 单独保存（含启动警告）；保存系统进程真实退出码，确认进程已退出且收到合理终态后再验收。不要把 stderr 混进 stdout 当 JSONL 解析，也不要只凭 `turn.completed`、超时返回或零退出码启动下一张。错误、无会话 ID、进程异常及结构化记录缺失转入 `SEC-DISPATCH-03`。
7. **用户可见播报**：用户指定范围并经核验后，启动 CLI 前告知当前 Ticket ID/文件与目标模块、模型真实 ID + Medium/High 档位、开发 CLI、新会话或原会话续接和已验收 DONE/总数；实际启动后依据 PID、Session、工具事件、独立 TC/测试逐阶段告知 STARTING/RUNNING/VERIFY/TEST/DONE/NEEDS_FIX/BLOCKED。禁止把工具事件数当完成率，或在进程尚未启动时报告“开发中”。多 Ticket 逐张更新，最终归纳 ALL_DONE/PARTIAL；Web 端只能转述真实可取得的外部执行日志，不声称外部 PowerShell 能自动向 ChatGPT 聊天推送进度。

### 坑
- `codex exec` 在目标仓执行，不是在 supervisor 根执行；每张新的 Ticket **不能带旧 session ID**。
- 用户说“依次执行全部任务”不等于允许绕过 CLI 登录、写权限或 Skill 检查。
- Skill 入口必须按所选 CLI 构造并在当次执行中核验；写上 `$implement` 或 `/implement` 都不是已加载的证据。

## SEC-DISPATCH-03 未完成状态诊断、原会话续接与复验

### 适用
开发 CLI 退出、报错、结果不全，或复查现有 `tasks.md` 发现 `[ ]`、证据不一致、已有会话未验收。

### 步骤
1. 每次以**目标仓磁盘现状 + 持久化调度记录**复核任务项、各 Ticket 的 `TC-*`、代码差异、必要测试和原会话日志；按 `NOT_STARTED/STARTING/RUNNING/NEEDS_FIX/BLOCKED/PAUSED_QUOTA/DONE` 分类，并明确记录未完成原因。`tasks.md` 的 `[x]` 不等于已验收，原有代码变更可能来自别的 Ticket，归属必须核对。
2. 发现已有正在运行的进程/会话，**先等待其真实终态或检查是否挂起**，禁止重复派发。无运行进程但保存有该 Ticket 的 session ID，则优先直接评估已有工作成果；未满足验收条件时进入同会话继续。
3. 检查目标 `AGENTS.md`/命中规则、对应 CLI 的**原生 implement Skill**、当前 Ticket 实际交付、必要测试命令/结果以及 Ticket `TC-*` 与任务项是否一致。**允许纯配置/文档 Ticket 无业务代码 diff，但必须存在其定义的真实交付物**。测试被阻止、空回复、权限错误、错标完成或证据归属不明均不能通过。
4. 对可修复的未满足项，整理**最小返工证据包**：Ticket ID、未通过 TC、预期行为、命令/错误原文、相关文件/差异、目标根目录、允许的修复范围；恢复**当前 Ticket 原会话**。Codex 用 `codex exec resume`；Cursor 用 `--resume <chat-id>`；Antigravity 用 `--conversation <conversation-id>`（确切参数以当前 CLI 帮助核对），严禁 `--continue` 猜最新会话。
5. 每轮续接后再按第 1–3 步复验。**有可观测进展就继续本 Ticket**；重复同一种失败而没有新证据、会话无法恢复、依赖/凭据/权限/契约无法解决时明确记为 `BLOCKED`，报告最后错误和恢复前置条件，不无限重试，不擅自以全新 session 冒充历史会话。
6. 若某 Ticket 真实阻塞，仅冻结依赖它的任务。经用户授权的**其它独立且就绪 Ticket** 可以保持一次一张继续；结束时仍需报告所有遗留阻塞，绝不宣称全范围完成。
7. **额度耗尽是整个批次暂停的例外**：真实 CLI 结构化错误或 stderr 明确显示当前模型 Credits/usage quota 已耗尽，则当前进程退出后立刻记录 `PAUSED_QUOTA`（含 Ticket、模型、Session、已完成数、日志），整个批次禁止新 Ticket、原会话自动重试、自动换档/换模型/换 CLI/换账号；不能等待额度重置后自发继续。向用户告知暂停并保留未验收项，只有用户明确批准且额度已恢复后才允许原 Session 续接。仅 `429`、临时限流、网络错误不是额度耗尽的充分证据；不可确认时按普通错误保守阻塞并附日志。

### 坑
- 上次 `tasks.md` 为 `[ ]` 但实际上已有代码/运行会话，不应直接新开一张同 Ticket 会话。
- 修复当前 Ticket 时随意新建 Thread，会丢上下文与验收链；必须核验每张 Ticket 对应的准确会话 ID。
- 失败时不停重试同一 shell/权限命令不是“直到完成”；应报告可执行的修复条件。
- **已验收 Ticket 不可受后续半成品代码反向污染降级**：Ticket 经独立验收记录为 DONE 且 `tasks.md` 保持 `[x]` 后，状态不可在循环中重新执行全量编译验收；否则后续正在开发的未完成 Ticket 会因半成品代码导致模块编译失败，从而将前面早已完成的 Ticket 误判为失败并死循环重做。

## SEC-DISPATCH-04 完成回写、逐张推进与全范围收尾

### 适用
当前 Ticket 返工或首次开发通过，需要回写状态、检查下一张并最终确认指定范围全部完成。

### 步骤
1. 单 Ticket 放行条件：项目规则/Skill 实际生效，变更范围正确，相关测试真实通过，适用 TC 全部满足，依赖已验证完成，无未解决阻塞。仅通过测试/证据后才允许由目标 CLI 或受控调度流程回写 Ticket 的 `TC-* [x]` 和 `tasks.md` 对应 `[x]`；保留证据，复读两处确认一致。
2. 目标项目的 Git 提交、文档归属、敏感信息策略由**目标根 AGENTS.md** 与适用规则决定；supervisor 不自行制定“所有项目统一逐张提交/整组提交”。用户未授权时不要自动 push，不能让通用 `implement` 流程越过目标规则。
3. **回到 `SEC-DISPATCH-01` 重新盘点指定范围内每个 `tasks.md`、Ticket 和依赖**；选择下一个未完成可执行任务，使用**全新的 CLI 会话**；重复 `下发 → 终态 → 独立验收 → 必要时原会话续接 → 回写 → 重新扫描`。
4. 只有本轮用户指定的**所有清单**均已验证每条 Ticket 完成、TC/测试证据一致且无阻塞，才输出 `ALL_DONE`。否则输出各模块 `DONE/TOTAL`、失败 Ticket、依赖、原会话 ID/日志位置、剩余检查与恢复动作，状态为 `PARTIAL/BLOCKED`。
5. 任务完成后记录本轮执行器、目标仓、各 Ticket 独立会话、最终验收与真实提交状况；不声称运行了未执行的测试、不掩盖失败、不把用户未指定的模块算进总数。

### 坑
- 选票只在最初计算一次会过期；每完成一张必须重新读取任务和依赖。
- `[x]`、退出码、模型“完成”三者都不能各自单独证明 `ALL_DONE`。
- supervisor 不能冒充开发者直接修改目标业务代码；只负责任务调度与可审计状态同步。

## SEC-DISPATCH-05 Skill 触发、权限与机器证据门禁

### 适用
调度 Codex/Cursor/Antigravity 任一 CLI 执行 `$implement`，或需要验证真实 Skill、工作区与命令权限。

### 步骤
1. **正常调度不单独运行 Skill/沙盒只读探针。** 本轮首次执行时直接下发一张实际 Ticket，在其正式会话中检查所选 CLI 的 Skill、规则、权限和工具事件；只有正式调用遇到 Skill 展开故障且确有诊断必要时，才额外使用只读探针。
2. **Codex**：提示词显式 `$implement`；检查工具读取/初始化中的 `implement/SKILL.md` 及真实执行；`/implement` 纯文本不能当作原生 Skill 已展开。
3. **Cursor**：在目标根用 `agent -p --output-format stream-json`；若当前版本确实支持原生 `/implement` 则使用并验证 Skill 的读取/展开事件，而不只凭文字回答。
4. **Antigravity**：在目标根用 Headless `agy -p` 的结构化输出；验证 `init.expanded_commands` 是否展开 `implement`、终态 `status` 和真实工具行为；不能启用 `--disable-slash-commands`。
5. 若当前正式会话中的 Skill/工具/权限证据缺失，先在**这张 Ticket 原会话**内补查或修复；不能继续时记为 `BLOCKED/NEEDS_FIX` 并报告。不另开同 Ticket 新会话，也不自动添加 `--force`、`--yolo`、`--dangerously-skip-permissions` 或关闭沙盒。
6. 各 CLI 独有的参数与返回字段在各自经验中维护；此处只维护通用的**证据门禁与三种执行器共用的调度契约**。

### 坑
- `grill-me` 是异常诊断的可选工具，不是每个 Ticket 的必经前置步骤；其成功也不能证明 `implement` 已触发。
- 若提示词返回“已加载”却无工具/事件证据，仍不可放行。
- 使用危险权限掩盖失败，会让任务完成状态不可被信任。

## SEC-DISPATCH-06 调度中断后盘点恢复与阻塞报告

### 适用
supervisor 会话中断、CLI 进程消失、用户再次要求继续，或多个任务目录部分开发完成，需要恢复整个指定范围。

### 步骤
1. 先恢复用户**本轮明确指定**的所有目标路径与 CLI 选择；无法从用户输入和持久化记录可靠确定时只要求补充缺失信息，不擅自换目标。读取每份当前 `tasks.md` 及必要 Ticket/TC/测试和会话记录，重新构建进度表。
2. 对每张 Ticket：`DONE` 有效则跳过；`STARTING/RUNNING` 先核查真实进程及会话，禁止重复启动；`NEEDS_FIX` 且原 ID 有效则同 CLI 原会话续接；`NOT_STARTED` 且依赖满足才新建会话；`BLOCKED` 检查是否已解除；`PAUSED_QUOTA` 保持批次暂停、等用户明确授权并确认额度恢复后再续接，不接受普通重试自动解除。**若有启动日志但无会话 ID，先从原始输出与 CLI 历史恢复准确 ID，确认无法恢复则报告阻塞，不能视为未开始重新派发。**
3. 调度记录至少持久化 `scope/CLI/目标根/Ticket ID/session ID/进程ID/STARTING或终态/失败原因/日志和测试证据路径`，首次进程启动前就记录并在收到会话 ID 时立刻更新；重启时同时检查进程存活、日志和磁盘状态，避免重复启动。范围或执行器变化要明确形成新的调度批次，不覆盖历史会话映射。
4. 对已确定可恢复的任务继续执行 `SEC-DISPATCH-02 → 03 → 04`，逐张直到全部验证完成；仅剩不可恢复阻塞时，按 Ticket 汇总错误、依赖链、必须由谁修复及具体恢复动作后停止。
5. 不允许在目标项目之外乱建 Git worktree，不允许为证明“全部完成”擅自改 `[x]` 或跳过测试；若用户改变目标范围，应重新盘点并重新计算总数。

### 坑
- 仅按缓存的“上次做了几张”恢复会漏掉他人修改；必须以磁盘现状和真实验收证据为准。
- 丢 session ID 后不能假装 `resume` 成功；应说明需先恢复会话映射或经用户明确决定新的修复会话策略。

## SEC-DISPATCH-07 默认开发模型与 High 档位覆盖

### 适用
用户指定使用 Codex Exec、Cursor CLI 或 Antigravity CLI 开发 Ticket，但没有指定模型；或只说“用 High 模型”“改成 High”，要求提高推理档位而不更换模型系列。

### 步骤
1. **默认策略（只影响开发 CLI，不修改 Supervisor 自身模型）**：

   | 开发 CLI | 用户未指定模型时 | 仅要求 High 时 |
   | --- | --- | --- |
   | Codex Exec | ChatGPT 6.1 Sol / Medium | ChatGPT 6.1 Sol / High |
   | Cursor CLI | Grok 4.7 / Medium | Grok 4.7 / High |
   | Antigravity CLI | Gemini 3.8 Flash / Medium | Gemini 3.8 Flash / High |

2. **优先级**：用户本轮明确指定的模型或档位优先。未指定模型和档位则取对应行 Medium；只说“High/high 模型”而没有指定型号，则保持当前选定 CLI 的默认模型系列，将档位改为 High；只说 Medium 同理。用户明确指定其他型号时应保留指定型号，不擅自替换成表中默认。一次任务指定多个模块时沿用本轮选择，直到用户明确修改。
3. **调用参数映射**：表中名称是用户偏好的显示名，不是通用 CLI 参数。首次使用该执行器与模型时，通过当前 CLI 已提供的模型列表、帮助或可信运行记录确定实际支持的 ID/档位参数；后续 Ticket 直接复用。禁止为此额外打开模型测试会话，也不得未经验证直接把显示名称传给 --model。
4. **Codex Exec**：本机历史会话使用过模型 ID gpt-6.1-sol；需以当前环境是否支持为准。开发时在正常 codex exec 命令附加 -m gpt-6.1-sol 和 -c 'model_reasoning_effort="medium"'；用户说 High 则只改为 -c 'model_reasoning_effort="high"'。同 Ticket 的 codex exec resume 支持 -m/-c，续接时应显式沿用当前生效选择，不要无意切回默认档位。
5. **Cursor CLI（已验证）**：默认模型真实 ID 为 `grok-4.7-medium`，High 为 `grok-4.7-high`；在 `ZC2026090353` 上两者均已完成实际只读推理请求。正式调用用 `agent -p --model grok-4.7-medium --output-format stream-json`（High 替换为 `grok-4.7-high`）；同 Ticket `--resume` 也保持所选 ID。**启动前按 `SEC-CUR-05` 从已有 Process/User/Machine 环境变量给当前 PowerShell 进程加载 `CURSOR_API_KEY`**。曾出现 Machine 有 Key、Process 未继承导致 `Authentication required`；`agent status` 不足以判定 API Key 请求能否成功。更换主机、账号或模型列表变化时重新核验，模型不可用则报告，不偷换。
6. **Antigravity CLI**：当前主机 agy models 列表实测包含 gemini-3.8-flash-medium 和 gemini-3.8-flash-high。默认在原 Headless 命令中加入 --model gemini-3.8-flash-medium；用户说 High 改为 --model gemini-3.8-flash-high。--conversation 原会话续接时沿用当前生效型号；更换主机/版本时重新核验模型 ID。
7. **会话一致性**：调度记录保存执行器、模型系列、档位、实际 CLI 模型参数。每张新 Ticket 使用本轮生效选择创建新会话；同 Ticket 续接保持原选择，除非用户明确要求调整。用户中途说“改 High”，仅对后续尚未启动的调用（包括随后续接）生效，不中断已经运行的会话。遇到模型不存在或档位不支持时停止相关任务并报告，不擅自降级或替换执行器。

### 坑
- 将“ChatGPT 6.1 Sol Medium”等显示名称原样传入 CLI，可能被拒绝；必须使用目标 CLI 实际支持的 ID。
- “High”仅覆盖推理档位，不将 Sol、Grok、Gemini 切换成另一个模型系列。
- 为检查模型额外启动探针会浪费时间；本流程只检查模型列表与正式会话返回，不通过换低级模型掩盖启动错误。

## SEC-DISPATCH-08 自动唤醒器与巡检自愈

### 适用
主调度器因配额限制暂停（`PAUSED_QUOTA`）、单票测试/编译失败中断（`BLOCKED` / `NEEDS_FIX`），或需要在后台全自动监视运行终态、定时恢复及状态自愈。

### 步骤
1. **状态检查与自愈核心**：使用 `scripts/Invoke-AutoWakeSupervisor.ps1` 作为机器与 Agent 共用的状态机检测入口：
   - `Check` 模式：分析最新 `state.json` 与 `progress.log`，返回结构化状态：`ACTIVE_RUNNING`、`WAITING_QUOTA`、`READY_TO_RESUME`、`ACTION_REQUIRED`、`ALL_DONE`。
   - `ResumeIfReady` 模式：若当前系统时间已过额度重置窗口（或用户确认授权恢复），自动后台静默调起 `Start-DispatcherHidden.ps1 -ResumeAfterQuota` 恢复批次。
   - `Diagnose` 模式：提取失败 Ticket 的测试输出与诊断信息。
2. **结合 Antigravity 原生唤醒**：
   - 额度等待：检测到 `WAITING_QUOTA` 时，取返回的 `RemainingSeconds`，使用 Antigravity IDE `schedule` 工具注册单次唤醒定时器（`DurationSeconds`），到点自动唤醒 Agent 上下文，无需死循环轮询。
   - 终态通知：后台进程退出时，IDE 原生 Reactive Wakeup 会自动向 Agent 发送通知事件，触发 Agent 执行巡检与决策。
3. **安全自愈红线与转人工分流**：
   - **已约定流程自主解决**：若唤醒后发现的问题属于本仓 `AGENTS.md`、`KNOWLEDGE-INDEX.md` 及四份经验库已覆盖的约定流程（如参数引号转义、编码乱码修复、tasks.md 补标、同会话 resume、额度到期续接等），由 Agent 自主排查修复并继续调度。
   - **未约定流程前置研判与分流**：
     - **研判为可自行解决**：若问题不在已有经验中，但属于工程配置、脚本兼容、测试参数或路径等 Agent 可闭环验证问题，Agent 自主尝试解决（**严格以 2 次为上限**）；**成功解决后必须在同一轮沉淀总结经验**并同步索引；若 2 次仍未解决，立即转入人工流程。
     - **研判为必须人工干预**：若涉及业务架构冲突、未授权破坏性依赖、敏感账号权限缺失或业务歧义导致 Agent 无法自主决断，严禁盲目尝试，**必须直接进入人工流程**。
   - **转人工规范**：严禁无限循环盲目重试，必须立即停止任何自动重试与子 CLI 进程，向用户全面报告受阻 Ticket、现场日志与自愈失败原因（或无法自行决断的依据），转入人工处理流程。
   - 额度重置窗口未过时严禁提前唤醒或重试。

### 坑
- PowerShell 5.1 在启用 `Set-StrictMode -Version Latest` 时，直接访问 PSCustomObject 动态 JSON 属性若该属性不存在会抛出 `PropertyNotFoundStrict`；必须使用 `obj.PSObject.Properties['prop']` 或封装辅助函数访问可选属性。
- PowerShell 双引号字符串内插变量时，若变量紧跟英文冒号（如 `"$bid is $bst: $msg"`），解析器会将 `$bst:` 误作为变量驱动器作用域（类似 `$env:`）而报语法解析错误；必须写成 `"$($bst):"` 或 `"${bst}:"`。
- 解析额度重置时间（如 `try again at 4:28 AM`）时，需按本地时间对比，若时间未到提前发起请求会导致重复触发配额暂停。

## SEC-DISPATCH-09 用户即时命令下发与抢占插队响应

### 适用
- 用户在后台开发调度或长任务运行期间，在对话中即时下发临时指令（例如：紧急终止当前任务、修改模型档位、插入临时重构/格式化排查、修复乱码/破坏性改动、前置校验要求变更等）。
- 需要安全拦截或等待在途 CLI 进程、下发临时独立任务并保证后续主流程无缝接续。

### 步骤
1. **即时指令意图识别与状态快照**：
   - 收到用户即时命令时，首先识别指令类型：`TERMINATE`（终止并暂停）、`INTERRUPT_INSERT`（暂停当前批次并插队执行临时任务）、`IN_FLIGHT_MODIFY`（修改下一次调度的参数如模型档位/规则）；
   - 若当前有正在运行的子 CLI 进程（如 PID 存活）：记录当前 Ticket ID、会话 Session ID 及未完成状态，向用户明确播报，使用系统安全手段杀掉或等待当前子进程收尾，保持主批次状态落盘（`state.json`），禁止状态丢失。
2. **临时独立任务组装与执行**：
   - 将用户即时指令组装为独立的一次性 CLI 会话（`codex exec` / `cursor-agent` / `agy`），指定目标工作区、注入项目根目录强制规则（AGENTS.md、代码格式化、UTF-8 防乱码等），并明确具体的排查/修复交付物和验收目标；
   - 以独立后台任务或受控子进程执行，保存临时任务的 stdout/stderr/exit receipt，并在执行前后通过 Git 状态或 AST/构建校验前后差异。
3. **临时任务闭环验证与结果汇报**：
   - 临时任务执行退出后，运行独立编译与轻量级单测（如 Maven/pytest）验证变更正确性；
   - 向用户做真实结果汇报（包含完成项、修改文件、测试结论、真实退出码）；若遇到模型容量受限（如 `at capacity`）或异常，按照 2 次自愈上限原则处置，无法自愈时客观转人工。
4. **主批次上下文恢复与平滑接续**：
   - 临时任务验收通过后，重新读取目标模块的 `tasks.md` 和最新代码状态，触发一次前置独立验收（`SEC-DISPATCH-01` / 前置校验）；
   - 若原受阻/暂停 Ticket 因临时修复已达到验收条件，则自动补标 `[x]` 并推进下一张；若未完成，则基于既有 Session ID 原会话续接（`resume`），继续主流程，无需用户重头排队。

### 坑
- 收到用户指令时未安全处理在途后台子进程，导致两个 CLI 进程同时写入目标工作区造成文件并发冲突或 Git 脏写。
- 执行用户临时命令时，直接覆盖了主调度器的全局状态（`state.json`），导致主批次已完成的 Ticket 进度或未完成 Ticket 的原 Session ID 丢失。
- 临时命令未指定 UTF-8 编码或缺少项目红线约束，导致临时命令本身再次生成乱码或破坏 Markdown 契约。
- 临时命令执行完后没有重新盘点工作区状态就盲目新建会话，破坏了同 Ticket 续接约束。

## SEC-DISPATCH-10 验收测试防静默放行与前置校验防击穿门禁

### 适用
- 编写、配置或执行 Ticket 独立验收测试脚本（如 `Test-GovernanceTicket.ps1`）、验收清单（`acceptance-manifest.json`）及主调度器任务下发 Prompt 与前置校验；
- 防止因测试脚本静默放行或过窄误杀，以及 Prompt 过度包装导致模型退化为“应试型投机开发”。

### 步骤
1. **Prompt 保持原生极简原则**：
   - 调度器下发给 CLI 的指令必须 100% 还原用户真实手工开发习惯，直接使用 `$implement <ticket-path>`（续接时追加未通过简述），严禁堆砌长篇累牍的生硬规则与条文；
   - 依赖项目根目录 `AGENTS.md` 自带规则驱动，让模型原生发挥 `implement` skill 的 TDD、代码分析与重构能力，防止因过度约束导致模型为了“避错”而仅写单测或仅在内存 Mock。
2. **测试脚本严格禁止静默放行参数**：
   - 多模块 Maven 测试脚本中，严禁添加 `-DfailIfNoTests=false` 或 `-Dsurefire.failIfNoSpecifiedTests=false`；必须让缺失测试用例时直接触发 `BUILD FAILURE` 并返回非零退出码（如退出码 1）；
   - 在多模块工程中，直接指定包含业务与单测的子模块 `pom.xml`（如 `-f .../biz/pom.xml`）执行测试，或在运行前完成本地安装（`install -DskipTests`）。
3. **测试类模式采用兼顾与多候选匹配**：
   - 既不能使用过于宽泛的通配符引发跨模块误判，也不能仅指定单一孤立类名导致模型编写在 Service 主测试类中的合规单测被误杀；
   - 推荐使用逗号分隔的多候选模式（如 `*PlatformScope*,McpApiKeyServiceTest`），只要其中包含有效业务单测即可通过。
4. **真实交付物多重约束**：
   - `acceptance-manifest.json` 中的 `deliverables` 严禁仅填写 Ticket 自身的 markdown 文件；必须将预期的 Java 业务类、Mapper/Service 或 SQL 文件作为交付物强校验项。

### 坑
- 在 Prompt 中塞入过多生硬限制与防御条款，模型会因为“怕违规”而不敢重构或修改已有类，退化为只建一个同名单测应试跑通。
- 测试脚本硬编码过于狭隘的单一通配符，导致模型合规实现的代码因为测试类命名不同而被脚本误杀。
- 验收清单 `deliverables` 仅填 markdown，因任务生成时 markdown 就存在，导致交付物检查失去所有防御价值。


