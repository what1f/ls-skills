# rex 调度指南

所有被调度的 Agent 放进专用 session `agents`，每个 Agent 一个 tab（window），tab 名写任务名（如 `review-auth`）。

## 启动

```sh
# 复用或新建 agents session
rex session inspect agents >/dev/null 2>&1 || rex new agents -c "$PWD" --window shell
# 一个 Agent 一个 tab，不抢焦点
B=$(rex window new -s agents <任务名> -c "$PWD" --focus=false --json -- <agent 命令> | jq -r '.block_ids[0]')
```

## 状态与派活

- 状态：`rex block call -s agents -b "$B" program_status | jq -r '.records[0].state'`，值为 `working`、`idle`、`done`、`blocked`、`error`。Claude Code、Codex 和 Antigravity（`agy`）会上报；Pi 不上报，记录为空。
- 派活：先等到 `idle`（Pi 读屏看到底部出现模型名那行），否则输入会丢。记下 `T=$(date +%Y-%m-%dT%H:%M:%S)`，然后：
  ```sh
  rex send -s agents -b "$B" '<任务>'; sleep 1; rex send-key -s agents -b "$B" enter
  ```

## 等结果

用后台命令挂起下面的循环，退出后读屏。只认晚于 `T` 的状态，防止上一轮的 `idle` 让它立刻返回：

```sh
until rex block call -s agents -b "$B" program_status | jq -e --arg t "$T" '.records[0] | select(.state=="done" or .state=="idle" or .state=="blocked" or .state=="error") | select(.updated_at > $t)' >/dev/null; do sleep 15; done
```

Pi 改看屏幕：忙的时候输入框上方有 `Working...`，消失即完成：

```sh
sleep 5; while rex capture -s agents -b "$B" --trim | tail -n 20 | grep -q 'Working\.\.\.'; do sleep 10; done
```

## 读屏、切换与关闭

- 读屏：`rex capture -s agents -b "$B" --trim | tail -n 80`
- 切焦点（仅用户要求切过去时）：`rex -C <client> do session.select session_id=<agents 的 session id>`（`rex client ls` 查 client）
- 关闭：`rex block close -s agents "$B"`
