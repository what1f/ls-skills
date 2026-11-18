# Harness 启动参数与注意事项

用户未指定模型或 effort 时不传对应参数，使用各 Agent 的默认配置。

## 交互式启动示例

```sh
# Claude Code
claude --dangerously-skip-permissions --model opus --effort medium

# Codex（含跳过启动弹窗参数）
codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -c check_for_update_on_startup=false -m gpt-6.1-sol -c model_reasoning_effort=medium

# Pi
pi --approve --model deepseek/deepseek-v4-pro --thinking medium

# Antigravity (agy)
agy --dangerously-skip-permissions --model gemini-4-hydrogen-medium --effort medium
```

## 各 Harness 说明

### Claude Code (`claude`)
- 模型：`--model opus` / `sonnet` / 全名
- effort：`--effort low|medium|high|xhigh|max`
- 免审批：`--dangerously-skip-permissions`
- 非交互：`claude -p "<任务>"`

### Codex (`codex`)
- 模型：`-m <model>`（如 `gpt-6.1-sol`）
- effort：`-c model_reasoning_effort=low|medium|high|xhigh`
- 免审批：`--dangerously-bypass-approvals-and-sandbox`
- 跳过启动弹窗：`--dangerously-bypass-hook-trust -c check_for_update_on_startup=false`
- 非交互：`codex exec --skip-git-repo-check -o <输出文件> "<任务>"`（用 `-o` 把最终回复写进文件后再读取）
- 在 `hc` 里运行时额外加 `--no-daemon`。

### Pi (`pi`)
- 模型：`--model <provider>/<id>`，可用 `pi --list-models` 查询
- effort：`--thinking off|minimal|low|medium|high|xhigh|max`
- 免审批：本身无审批弹窗
- 跳过项目信任弹窗：`--approve`
- 非交互：`pi -p "<任务>"`
- 状态上报：`rex` 下不上报 `program_status`，需通过读屏判断（底部出现模型名即就绪，忙时输入框上方有 `Working...`）。

### Antigravity (`agy`)
- 模型：`--model <id>`，可用 `agy models` 查询
- effort：`--effort low|medium|high|xhigh|max`
- 免审批：`--dangerously-skip-permissions`
- 非交互：`agy -p "<任务>"`
- 状态上报：`rex` 和 `hc` 均识别（`app: "antigravity"`）。
