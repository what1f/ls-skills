---
name: agent-dispatch
description: 启动并调度其他编码 Agent（Claude Code、Codex、Pi）干活：在 rex、herdr 里交互式开会话派任务、等结果、追问，没有这些工具时用非交互模式。用户说「交给 Codex」「让 Claude Code 做」「开个 pi」「派个 Agent」「多开几个 Agent 并行」「用 rex/herdr 起一个 agent」「找 gpt/opus 帮忙看看」时使用。
metadata:
  version: "0.1.0" # x-release-please-version
---

# agent-dispatch

在终端复用工具里交互式启动 Claude Code、Codex、Pi，派任务、等结果、追问。

## 1. 选调度器

rex 和 herdr 都是普通命令行工具，不需要自己跑在里面也能调度。`command -v rex herdr` 看装了哪个：

- 都装了：按用户偏好选（用户指定的、CLAUDE.md 或记忆里提到常用的、自己当前所在的那个），没有线索时用 rex。
- 只装了一个：用它。
- 都没装：非交互模式。

交互式是默认：Agent 跑在真实 TUI 里，能追问、能返工，用户随时能进去看或接手。只有用户要求、或没有调度器时才用非交互模式。

## 2. 启动参数

| | Claude Code | Codex | Pi |
| --- | --- | --- | --- |
| 模型 | `--model opus` / `sonnet` / 全名 | `-m gpt-6.1-sol` | `--model <provider>/<id>`，`pi --list-models` 查 |
| effort | `--effort low\|medium\|high\|xhigh\|max` | `-c model_reasoning_effort=low\|medium\|high\|xhigh` | `--thinking off\|minimal\|low\|medium\|high\|xhigh\|max` |
| 免审批 | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` | 本身没有审批 |
| 跳过启动弹窗 | — | `--dangerously-bypass-hook-trust -c check_for_update_on_startup=false` | `--approve`（项目信任） |
| 非交互 | `claude -p "<任务>"` | `codex exec --skip-git-repo-check -o <输出文件> "<任务>"` | `pi -p "<任务>"` |

下文的 `<agent 命令>` 指一整条交互式启动命令，例如：

```sh
claude --dangerously-skip-permissions --model opus --effort medium
codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -c check_for_update_on_startup=false -m gpt-6.1-sol -c model_reasoning_effort=medium
pi --approve --model deepseek/deepseek-v4-pro --thinking medium
```

用户没指定模型或 effort 时不传，用 Agent 自己的默认配置。

## 3. 派任务

所有被调度的 Agent 都放进一个专用空间 `agents`，不和用户自己的会话混在一起。每个 Agent 一个 tab，tab 名写任务名（如 `review-auth`），用户一眼能认出。

任务超过一行时先写进文件，比如 `/tmp/agents/<任务名>.md`，prompt 只写「读 /tmp/agents/<任务名>.md 并按要求执行」。

### rex

```sh
# 复用或新建 agents session
rex session inspect agents >/dev/null 2>&1 || rex new agents -c "$PWD" --window shell
# 一个 Agent 一个 tab，不抢焦点
B=$(rex window new -s agents <任务名> -c "$PWD" --focus=false --json -- <agent 命令> | jq -r '.block_ids[0]')
```

- 状态：`rex block call -s agents -b "$B" program_status | jq -r '.records[0].state'`，值为 `working`、`idle`、`done`、`blocked`、`error`。Claude Code 和 Codex 会上报；Pi 不上报，记录为空。
- 派活：先等到 `idle`（Pi 读屏看到底部出现模型名那行），否则输入会丢。记下 `T=$(date +%Y-%m-%dT%H:%M:%S)`，然后：
  ```sh
  rex send -s agents -b "$B" '<任务>'; sleep 1; rex send-key -s agents -b "$B" enter
  ```
- 等结果：用 run_in_background 挂起下面的循环，退出后读屏。只认晚于 T 的状态，防止上一轮的 `idle` 让它立刻返回：
  ```sh
  until rex block call -s agents -b "$B" program_status | jq -e --arg t "$T" '.records[0] | select(.state=="done" or .state=="idle" or .state=="blocked" or .state=="error") | select(.updated_at > $t)' >/dev/null; do sleep 15; done
  ```
  Pi 改看屏幕：忙的时候输入框上方有 `Working...`，消失即完成：
  ```sh
  sleep 5; while rex capture -s agents -b "$B" --trim | tail -n 20 | grep -q 'Working\.\.\.'; do sleep 10; done
  ```
- 读屏：`rex capture -s agents -b "$B" --trim | tail -n 80`
- 关闭：`rex block close -s agents "$B"`

### herdr

```sh
# server 没运行时（返回 server_not_running）先在后台拉起
herdr status | grep -q 'status: running' || { nohup herdr server >/dev/null 2>&1 & sleep 2; }
# 复用或新建 agents workspace；新建时的 root pane 给第一个 Agent 用
herdr workspace list | jq -r '.result.workspaces[] | select(.label=="agents") | .workspace_id'
herdr workspace create --label agents --cwd "$PWD" --no-focus   # 返回 .result.root_pane.pane_id
# 再加一个 Agent：新开 tab，返回 .result.root_pane.pane_id
herdr tab create --workspace <ws> --label <任务名> --cwd "$PWD" --no-focus
# 在 pane 里启动，返回时 Agent 已就绪
herdr agent start <任务名> --kind claude|codex|pi --pane <pane> -- <agent 参数>
```

- `--` 后面只写参数，不写程序名，例如 `-- --model opus --effort medium --dangerously-skip-permissions`。
- 派活并等待：`herdr agent prompt <任务名> '<任务>' --wait --timeout 1800000`
- 读屏：`herdr agent read <任务名> --source recent-unwrapped --lines 120`
- 状态：`herdr agent get <任务名>`；三个 Agent 都能识别状态。
- 关闭：`herdr tab close <tab>`

### 非交互

用第 2 节的「非交互」一行加上模型、effort、免审批参数，用 run_in_background 执行。Codex 用 `-o` 把最终回复写进文件，再读这个文件。

## 4. 用户要看时

用户问 Agent 在哪、想进去看时，告诉用户空间和 tab 名；要求切过去时再切：

- rex：`rex -C <client> do session.select session_id=<agents 的 session id>`，`rex client ls` 查 client
- herdr：`herdr agent focus <任务名>`；用户不在 herdr 里时，让用户运行 `herdr` 打开界面

## 规则

- 启动后先读屏。遇到弹窗（信任目录、更新提示、登录）时截下内容告诉用户，别自己选。需要登录时停下，交给用户。
- `blocked` 表示 Agent 卡在审批或提问上：读屏后告诉用户，别替用户回答。
- `error` 多半是额度用完或登录失效：读屏确认原因，告诉用户，换别的 Agent 或模型前先问用户。
- 等待超时不代表任务没送达，先读屏，再决定要不要重发。
- 返工在原来的 tab 里接着发，新任务开新 tab。
- 只关自己开的 tab；`agents` 空间里用户开的东西不动。
