# Supervisor 项目入口

本仓是 **CLI Ticket 开发调度工作区**，不是前端/后端实现仓库。只负责按用户显式指定的目标路径，读取目标项目的任务状态、依赖和验收证据，调用用户指定的开发 CLI，按顺序逐张调度 Ticket，验收并恢复未完成任务。本仓不直接实现目标项目业务代码，不自动扫描或扩展到未指定的模块。

## 唯一两条项目规则

1. **先读经验**：执行任何调度、排障、CLI 命令前，读取 [经验检索规则](.cursor/rules/personal-knowledge-retrieval.mdc)，先定位 [KNOWLEDGE-INDEX](docs/knowledge/KNOWLEDGE-INDEX.md)，只按需加载相关 `SEC-` 切片。
2. **写经验**：新建、修订、复盘经验时，读取 [经验沉淀规则](.cursor/rules/personal-knowledge.mdc)；修改经验与索引必须同步，并保持四份现有经验文件。

## 调度入口

- **共用流程**：`KNOW-DISPATCH-00`，见 `docs/knowledge/cli-ticket-dispatch.md`。
- **CLI 差异**：按用户指定的执行器加载 `KNOW-CODEX-00`、`KNOW-CUR-00` 或 `KNOW-AGY-00`。
- **默认开发模型**：统一按 `SEC-DISPATCH-07` 设置；用户未指定则采用对应 CLI 的 Medium 默认模型，仅要求 High 时保持模型系列并提升档位。
- **目标路径**：接受一个/多个绝对模块目录或 `tasks.md`，例如 `D:\2026work\work\digital-logistics\docs\scratch\data-governance` 或其 `tasks.md`。必须从目标路径独立识别目标仓库根目录、目标项目自己的 `AGENTS.md` 和实际 Ticket；不要把 `supervisor` 根目录当成开发工作目录。
- **核心约束**：独立 CLI 会话，Ticket 串行执行；不同 Ticket 新会话、同一 Ticket 失败续接原会话；每次重新检查任务、验收和依赖。Codex 开发优先使用**Codex 进程外启动**的 PowerShell 调度器（`SEC-CODEX-06`），不能在 Codex Shell 内启动脚本却声称已避开嵌套。直到指定范围全部验收完成，或遇到真实不可恢复阻塞才停止并报告。禁止换 CLI、扩大范围、伪造完成或绕过权限。
- **规则归属**：supervisor 只执行本仓两条经验规则；**目标开发 CLI** 在目标仓中遵守其 `AGENTS.md`、项目规则、Spec、Ticket 和测试契约。目标仓中的 Git、敏感信息及工作区规则优先于通用 Skill 的可选步骤。

命令执行、读写路径一律按实际权限与当前工具能力进行；不得假定某一 CLI 或 Skill 已可用，必须检查真实返回与运行证据。
