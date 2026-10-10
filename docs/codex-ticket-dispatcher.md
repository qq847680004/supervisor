# Codex Ticket PowerShell 调度器

实现：scripts/Invoke-CodexTicketDispatcher.ps1（Windows PowerShell 5.1+）。

## 启动条件

调度器必须由 **Codex 进程之外** 的 Windows Terminal、普通 PowerShell 或独立任务计划程序启动。不能在 Codex exec_command/shell 中运行本脚本后声称已经解决了父 Codex 的沙盒嵌套问题。此方案不会关闭子 Codex 本身的 workspace-write 沙盒。

1. 明确指定一个或多个绝对目标模块路径或 tasks.md 路径；必须属于含 AGENTS.md 的 Git 仓库。
2. 提供独立、人工审定的 AcceptanceManifest JSON，逐 Ticket 声明交付物和真正可执行的测试命令；没有清单时只允许 DryRun。脚本从不自动“猜”测试脚本，也不执行从 Ticket 文本抽取的任意 shell 命令。
3. 先在普通 PowerShell 中运行（示例目标路径需替换为本次目标）：

    cd D:\2026work\work\supervisor
    powershell.exe -NoProfile -File .\scripts\Invoke-CodexTicketDispatcher.ps1 -TaskPaths 'D:\TARGET-REPO\docs\scratch\module-a' -DryRun

4. 确认任务和依赖后，创建验收清单，再正式启动：

    powershell.exe -NoProfile -File .\scripts\Invoke-CodexTicketDispatcher.ps1 -TaskPaths 'D:\TARGET-REPO\docs\scratch\module-a','D:\TARGET-REPO\docs\scratch\module-b\tasks.md' -AcceptanceManifest 'D:\ABSOLUTE-PATH\acceptance.json'

   **默认开发模型：gpt-6.1-sol / Medium。** 用户在 ChatGPT 中说“用 High 模型”或“改成 High”时，Supervisor 应保持模型 ID `gpt-6.1-sol` 不变，将下次尚未启动的 Codex 调用的 `model_reasoning_effort` 设置为 `high`；同 Ticket Resume 也遵循当前用户档位。未指定时保持 `medium`。用户无需自己编写 PowerShell 档位参数；执行层内部仍需使用 Codex 支持的 `-c model_reasoning_effort=...` 实现，**High 不是另一个 CLI 模型 ID**。该模型 ID 是否可用，以正式 CLI 调用结果为准，不自动更换模型。CodexPath 默认 codex.cmd，可用于明确指定受信任的 CLI 路径。

## 验收清单格式

顶层 tickets 中每个 Ticket ID 必须包含至少一项 deliverables（仓库相对路径）和至少一个 tests（数组）。tests 的 file 为直接执行的测试命令，不经过 Invoke-Expression；args 按顺序传入，测试工作目录固定是该 Ticket 所在 Git 仓库根目录。例如：

    {
      "tickets": {
        "T-ABC-001": {
          "deliverables": ["src/module-a/service.ts"],
          "tests": [
            { "file": "npm.cmd", "args": ["test", "--", "module-a"] }
          ]
        }
      }
    }

修改目标项目配置/文档的 Ticket 也要显式声明交付物、可运行的检查命令，不允许用空测试跳过。测试命令与项目安全规则应由用户审查；调度器只防止把模型回复当成独立测试，不提供 OS 沙盒隔离。目标项目必须由开发 CLI 自行回写真实的 TC 和 tasks.md 状态。

## 开工告知与可观察进度

- 确认范围/依赖后，Supervisor 应先告诉用户：本轮模块/目标 Ticket、当前选票的 Ticket ID 与文件路径、目标根、CLI、真实模型 ID + Medium/High 档位、已验收数/总数以及新会话还是 Resume；确认实际进程启动后再说“运行中”。
- 外部 PowerShell 调度器实时打印 `[PLAN]`、`[STARTING]`、`[RUNNING]`、`[SESSION]`、`[VERIFY]`、`[TEST]`、`[DONE]`、`[NEEDS_FIX]`、`[BLOCKED]`、`[ALL_DONE]` 状态；日志同步保存在 `.supervisor-runtime/<batch>/progress.log`，可用 `Get-Content '<batch>\progress.log' -Wait -Encoding UTF8` 查看。
- 进度数字 `[X/Y DONE]` 仅按**独立验收已通过的 Ticket** 统计，不根据 Codex 事件数、ExitCode=0 或 tasks.md 的勾选估算工作完成率。工具事件只表示有活动；运行中每隔约 30 秒且无关键事件才打印一次心跳（不是完成证据）。
- Terminal 中的进度不会自动推送进 Web ChatGPT 的聊天气泡；Supervisor 若实际在聊天中指挥调度，需要从进程输出确认里程碑后主动转述，不能伪称支持后台推送。外部 CLI 运行任务的日志和进度仅在可访问的终端或文件中展示。

## 模型额度用尽与人工恢复

- Codex 正式会话在结构化 `error` / `turn.failed` 或 stderr 中明确报出 quota exhausted、usage limit reached、credits exhausted、额度耗尽等证据时，当前 CLI 进程终止后立即写入整个批次的 `PAUSED_QUOTA`；记录当前 Ticket、原会话 ID、模型档位、暂停时间及 JSONL/stderr 日志。退出码 `3` 表示额度暂停，而不是测试成功或失败。仅出现普通 `429`、临时限流或网络断线时不自动推断额度耗尽。
- **额度暂停绝不自动重试、切换模型/档位/CLI/账号、启动下一 Ticket，或按恢复时间自动继续**。同参数重复启动会保持暂停，单独的 `-RetryBlocked` 也不能解除额度暂停。
- 用户明确确认额度已恢复、授权继续后，才在原批次命令尾部追加 `-ResumeAfterQuota`；有原 Session ID 且确认旧进程终止时继续原会话。没有 Session ID 则持续暂停并要求人工检查原日志，不擅自开新会话。若额度尚未恢复，下一次实际 CLI 又报额度耗尽，会再次暂停。

## 模型容量受限（at capacity）退避重试与模型轮换机制

- 当 Codex 输出 `Selected model is at capacity. Please try a different model`（或 stderr/JSONL 中出现模型 capacity 过载限制）时：
  1. **随机退避重试**：调度器捕获该错误后，随机等待 2~8 秒（`Get-Random -Minimum 2 -Maximum 9`），然后自动重试继续未完成的任务；若已有 SessionId 则原会话 `resume`，若建联前即过载则允许重新建立会话；
  2. **重试次数上限**：针对 capacity 场景的重试上限单独提升至 **50 次**（`-MaxCapacityRetries 50`）；非 capacity 的普通中断/失败上限默认设置为 **10 次**（`-MaxAttemptsPerTicket 10`）；
  3. **模型轮换机制**：若同一模型连续遇到 3 次 capacity 报错（`-CapacityRotateThreshold 3`），调度器自动轮换到候选池的下一个模型，候选池依次为：`gpt-6.1-sol` $\rightarrow$ `gpt-6-sol` $\rightarrow$ `gpt-5.6-sol` $\rightarrow$ `gpt-5.6-terra`；
  4. **推理档位继承**：若当前批次启动时指定为 High 档位（`-Effort high`），轮换后的模型保持 High 推理档位；其他情况默认 Medium 档位。

## 运行与恢复

- 前置校验：仅解析显式指定的 tasks.md，不递归扫描其它模块；从 Git 定位目标根和 AGENTS.md；比对任务行与 Ticket 的 Blocked by ID 集合，拒绝重复/循环/路径越界。
- 只有前置依赖在选定范围内、已独立验收为 DONE 才放行；选定范围外的依赖默认阻塞，不自动扩权扫描。
- 每张 Ticket 首次用 codex exec -C <目标根> --sandbox workspace-write --json 开新 session；失败时只有捕获正确的 thread_id 才允许 codex exec resume 原会话。
- 普通错误默认最多 10 次尝试（capacity 场景最多 50 次重试）；无会话 ID（非 capacity 异常）、进程下落不明、环境权限不足、测试不通过且次数耗尽、模型/工具失败，均阻塞。阻塞不等于 DONE。
- 强制检查 tasks.md 的 [x]、Ticket 每项 TC-* [x]、交付文件存在、Codex JSONL 的实际 AGENTS/implement/SKILL.md 读取命令证据和真实终态，以及独立测试的进程退出码与原始 stdout/stderr。
- 使用单实例文件锁；在启动之前保存 STARTING，记录 PID/创建时间/session ID、JSONL、stderr、Git status 前后快照和退出收据，原子写入 state.json 并保留 state.json.bak。
- 批次路径默认为 .supervisor-runtime/<scope-hash>（Git 忽略）。同范围重复执行会读取原状态和日志；用户说“High 模型”时由 Supervisor 将内部执行档位切到 High，沿用同一批次和会话，只影响下一次尚未开始的 CLI 调用（外部 PowerShell 脚本本身不会读取 ChatGPT 消息）。范围或验收文件路径改变时将产生新批次，不覆盖旧状态；如已有同一 Ticket 开发会话，会阻止跨批次重复派发。
- 因崩溃丢失 PID 或无法确认进程是否仍运行时，记录 BLOCKED 并保留现有日志及可恢复 thread_id，必须人工核验，而不是猜最新会话。遇到超时但原进程仍活跃，不会下发下一张 Ticket。人工解除故障并核实进程已经终止后，使用同一批次参数附加 -RetryBlocked 可尝试原 session 继续（需 session ID 且未达到尝试上限）；无 session ID 时禁止新开会话冒充恢复。依赖类阻塞会自动重新检查。
- 未经用户授权，不自动 git commit/push。执行器没有权限保证、CLI 规则/Skill 缺失时不放行。
- 日志含原始 CLI 输出，可能包含敏感数据，应限制机器访问权限，严禁提交或共享原始日志。gitignore 防止普通 Git 添加，但不替代文件权限保护。

退出码：0=ALL_DONE，2=有 BLOCKED/PARTIAL，1=前置校验或运行错误，3=PAUSED_QUOTA。测试使用纯本地假 Codex，不会向真实模型发 Ticket：

    powershell.exe -NoProfile -File .\tests\Smoke-Dispatcher.ps1
    powershell.exe -NoProfile -File .\tests\Test-DispatcherCapacity.ps1

当前回归覆盖两张 Ticket 顺序、失败后原会话续接、不同 session、独立测试、重启不重复下发、循环依赖、模型 capacity 退避重试与自动轮换。模拟事件用于测试调度器自身，不能当成真实 Codex 开发/沙盒成功的证据。
