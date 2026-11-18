---
name: agent-dispatch
description: 启动并调度其他编码 Agent（Claude Code、Codex、Pi、Antigravity / agy）干活：在 rex、herdr 里交互式开会话派任务、等结果、追问，没有这些工具时用非交互模式。用户说「交给 Codex」「让 Claude Code 做」「开个 pi」「交给 agy」「用 Antigravity 做」「派个 Agent」「多开几个 Agent 并行」「用 rex/herdr 起一个 agent」「找 gpt/opus/gemini 帮忙看看」时使用。
metadata:
  version: "0.1.1" # x-release-please-version
---

# agent-dispatch

在终端复用工具里交互式启动 Claude Code、Codex、Pi、Antigravity（`agy`），派任务、等结果、追问。

## 1. 选调度器

rex 和 hc（herdr-core）都是普通命令行工具，不需要自己跑在里面也能调度。`command -v rex hc herdr` 看装了哪个：

- 都装了：按用户偏好选（用户指定的、CLAUDE.md 或记忆里提到常用的、自己当前所在的那个），没有线索时用 rex。
- 只装了一个：用它。
- 都没装：非交互模式。

交互式是默认：Agent 跑在真实 TUI 里，能追问、能返工，用户随时能进去看或接手。只有用户要求、或没有调度器时才用非交互模式。

## 2. 启动参数速查

| | Claude Code | Codex | Pi | Antigravity (`agy`) |
| --- | --- | --- | --- | --- |
| 模型 | `--model opus` / `sonnet` / 全名 | `-m gpt-6.1-sol` | `--model <provider>/<id>` | `--model <id>` |
| effort | `--effort low\|medium\|high\|xhigh\|max` | `-c model_reasoning_effort=...` | `--thinking off\|...\|max` | `--effort low\|medium\|high\|xhigh\|max` |
| 免审批 | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` | 本身没有审批 | `--dangerously-skip-permissions` |
| 非交互 | `claude -p "<任务>"` | `codex exec --skip-git-repo-check -o <输出文件> "<任务>"` | `pi -p "<任务>"` | `agy -p "<任务>"` |

用户没指定模型或 effort 时不传，用 Agent 自己的默认配置。完整示例、模型列表命令、跳过弹窗参数和各 Harness 注意事项见 [references/harnesses.md](references/harnesses.md)。

## 3. 按调度器执行

任务超过一行时先写进文件（如 `/tmp/agents/<任务名>.md`），prompt 只写「读 `/tmp/agents/<任务名>.md` 并按要求执行」。

- 使用 **rex** 时读 [references/rex.md](references/rex.md)。
- 使用 **hc（herdr-core）** 或旧版 **herdr** 时读 [references/hc.md](references/hc.md)。
- **非交互模式**：用上表「非交互」命令加上模型、effort、免审批参数在后台执行；Codex 用 `-o` 写文件后再读该文件。

## 4. 规则

- 启动后先读屏。遇到弹窗（信任目录、更新提示、登录）时截下内容告诉用户，别自己选。需要登录时停下，交给用户。
- `blocked` 表示 Agent 卡在审批或提问上：读屏后告诉用户，别替用户回答。
- `error` 多半是额度用完或登录失效：读屏确认原因，告诉用户，换别的 Agent 或模型前先问用户。
- 等待超时不代表任务没送达，先读屏，再决定要不要重发。
- 返工在原来的 tab/终端里接着发，新任务开新 tab/终端。
- 只关自己开的 tab/终端；用户原有的会话和终端不要动。
- 用户问 Agent 在哪或想进去看时，先告诉用户空间/终端名；用户明确要求切过去时再按对应调度器文档操作。
