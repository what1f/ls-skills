# ls-skills

<p align="center">
  <a href="./README.md">English</a>
</p>

一组给 AI Agent 用的 skill，以及它们背后的命令行工具（Go / Zig），全部开源。

## Skill 清单

| Skill | 作用 | 安装 |
| --- | --- | --- |
| [imgen](skills/imgen/SKILL.md) | 用 OpenAI、Gemini 或 Codex 登录生成和编辑图片（照片、插画、图标、UI mockup、sprite），支持透明背景、抠图和缩放 | `npx skills add what1f/ls-skills --skill imgen` |

## 安装 skill

任意支持 skill 的 Agent（Claude Code、Codex、Cursor 等）：

```sh
npx skills add what1f/ls-skills                    # 选择要装的 skill
npx skills add what1f/ls-skills --skill imgen      # 只装一个
```

Claude Code 插件市场（可随版本更新）：

```
/plugin marketplace add what1f/ls-skills
/plugin install imgen@ls-skills
```

Agent 首次使用 skill 时会按说明自动安装所需的 CLI。

## 安装 CLI

macOS / Linux：

```sh
curl -fsSL https://raw.githubusercontent.com/what1f/ls-skills/main/install.sh | sh -s -- <tool> [version]
```

Windows PowerShell：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/what1f/ls-skills/main/install.ps1))) <tool> [version]
```

默认装到 `~/.local/bin`（Windows 为 `%LOCALAPPDATA%\ls-skills\bin`），可用 `LS_INSTALL_DIR` 修改。安装器会校验 SHA-256；每个 Release 还附带 GitHub 构建来源证明，可用 `gh attestation verify <file> --repo what1f/ls-skills` 验证。

| 工具 | 说明 |
| --- | --- |
| [imgen](tools/imgen) | 用 OpenAI、Gemini 或 Codex 登录生成和编辑图片，本地抠图和缩放 |

## 参与开发

需要 Go（版本见 `go.mod`）和 Zig（版本见 `.zig-version`）。

```sh
make help
make check
go run ./cmd/repo new <name> --lang go|zig|none
```

目录约定、CLI 合同、skill 写法和发版规则见 [AGENTS.md](AGENTS.md)。PR 标题需符合 [Conventional Commits](https://www.conventionalcommits.org/)，它决定各个工具和 skill 的版本号。

### 维护者一次性设置

- Settings → General → Pull Requests：只开启 squash merge，默认使用 PR 标题作为 commit 信息。
- Settings → Actions → General：允许 GitHub Actions 创建和批准 pull request。
- 添加 `RELEASE_PLEASE_TOKEN` secret（只授权本仓库、有 Contents 和 Pull requests 写权限的 fine-grained PAT，或 GitHub App token）。不配时 Release PR 由 `github-actions[bot]` 创建，上面的 CI 要手动批准才会运行。

## License

[MIT](LICENSE)
