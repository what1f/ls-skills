---
name: imgen
description: TODO 做什么 + 何时用。写进用户的真实说法、链接域名、同义词，例如「当用户提到 X、Y 时使用」。
metadata:
  version: "0.0.0" # x-release-please-version
  requires: "imgen>=0.1.0"
---

# imgen

TODO: 一句话定位。

## 环境准备

命令不存在，或 `imgen version` 低于 frontmatter 中 `metadata.requires` 的版本时，安装后重试一次：

```sh
curl -fsSL https://raw.githubusercontent.com/what1f/ls-skills/main/install.sh | sh -s -- imgen
```

Windows PowerShell：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/what1f/ls-skills/main/install.ps1))) imgen
```

## 命令

用 `imgen --help`、`imgen <command> --help` 查看完整参数。

```sh
# TODO: 常用命令，每条一行注释说明做什么
```

## 规则

- 需要解析结果时加 `--format json`：stdout 只有一个 JSON 对象，`ok` 为 false 时读 `error.code` 与 `error.message`。
- 退出码 2 表示参数错误，查 `--help` 修正后重试；退出码 3 表示需要用户介入，停止重试并把 `error.message` 转告用户。
