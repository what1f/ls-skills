---
name: hello-go
description: 用 hello-go CLI 生成问候语。当用户要求打招呼、生成问候语、或提到 hello-go 时使用。这是仓库的 Go 示例 skill。
metadata:
  version: "0.0.0" # x-release-please-version
  requires: "hello-go>=0.1.0"
---

# hello-go

生成问候语。

## 环境准备

命令不存在，或 `hello-go version` 低于 frontmatter 中 `metadata.requires` 的版本时，安装后重试一次：

```sh
curl -fsSL https://raw.githubusercontent.com/what1f/ls-skills/main/install.sh | sh -s -- hello-go
```

Windows PowerShell：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/what1f/ls-skills/main/install.ps1))) hello-go
```

## 命令

用 `hello-go --help`、`hello-go <command> --help` 查看完整参数。

```sh
hello-go greet --name Ada                 # 输出问候语
hello-go greet --name Ada --format json   # 结果在 data.message
```

## 规则

- 需要解析结果时加 `--format json`：stdout 只有一个 JSON 对象，`ok` 为 false 时读 `error.code` 与 `error.message`。
- 退出码 2 表示参数错误，查 `--help` 修正后重试；退出码 3 表示需要用户介入，停止重试并把 `error.message` 转告用户。
