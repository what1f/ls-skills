# hc (herdr-core) 调度指南

`hc`（herdr-core）通过直接启动交互式命令并监听终端 OSC 7501 上报状态，原生支持 Claude Code、Codex、Pi 和 Antigravity（`agy`）。

## 启动与派活

```sh
# 后台启动 Agent，--cwd 指定工作目录，--name 写任务名
hc run --bg --name <任务名> --cwd "$PWD" -- <agent 命令>
# 等就绪后再发任务，避免启动期间丢输入
hc wait <任务名>
hc send --wait <任务名> '<任务>'
```

- 也可以在 `hc run` 末尾直接带初始任务字符串（模板或支持首条消息的命令），但需检查返回的 `first_message.sent`；若为 `false`，先 `hc read` 确认界面状态再决定是否重发。
- Codex 在 `hc` 里运行需加 `--no-daemon`，否则其命令会在 `hc` 外部执行。

## 等结果与状态

- 单任务等待：`hc send --wait <任务名> '<任务>'` 或 `hc wait <任务名>`（默认 180 秒超时会返回 `reason: timeout`，可继续 `hc wait`）。
- 多任务并行等待：`hc wait --children all` 或 `hc wait --children any`。
- 状态：`hc get <任务名>`（或加 `--json`），通过 OSC 7501 识别 `idle`、`working`、`done`、`blocked`、`error`（Claude Code、Codex、`agy` 均可识别）。

## 读屏、接管与关闭

- 读屏：`hc read --lines 80 <任务名>`（`--lines 0` 只看当前可见屏幕；`working`/`blocked`/`error` 时不会发送滚屏按键）。
- 接管查看：`hc attach <任务名>`（`Ctrl+\` 退出，不结束进程）。
- 关闭：`hc kill <任务名> && hc rm <任务名>`

## 旧版 herdr 兼容（无 `hc` 时）

若环境里只有旧版 `herdr`：

```sh
herdr status | grep -q 'status: running' || { nohup herdr server >/dev/null 2>&1 & sleep 2; }
herdr workspace list | jq -r '.result.workspaces[] | select(.label=="agents") | .workspace_id'
herdr workspace create --label agents --cwd "$PWD" --no-focus
herdr tab create --workspace <ws> --label <任务名> --cwd "$PWD" --no-focus
herdr agent start <任务名> --kind claude|codex|pi --pane <pane> -- <agent 参数>
herdr agent prompt <任务名> '<任务>' --wait --timeout 1800000
herdr agent read <任务名> --source recent-unwrapped --lines 120
herdr agent get <任务名>
herdr tab close <tab>
```

旧版 `herdr agent start --kind` 仅支持 `claude|codex|pi`，调度 `agy` 时改用 `rex` 或非交互模式。
