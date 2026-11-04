# ls-skills

<p align="center">
  <a href="./README.zh-CN.md">简体中文</a>
</p>

Skills for AI agents, plus the command-line tools behind them (Go / Zig). All open source.

## Skills

| Skill | What it does | Install |
| --- | --- | --- |
| [imgen](skills/imgen/SKILL.md) | Generate and edit images (photos, illustrations, icons, UI mockups, sprites) with OpenAI, Gemini or a Codex login; transparent backgrounds, cutouts and resizing | `npx skills add what1f/ls-skills --skill imgen` |

## Install a skill

Any agent that supports skills (Claude Code, Codex, Cursor and others):

```sh
npx skills add what1f/ls-skills                    # pick the skills to install
npx skills add what1f/ls-skills --skill imgen      # install one
```

Claude Code plugin marketplace (updates with each release):

```
/plugin marketplace add what1f/ls-skills
/plugin install imgen@ls-skills
```

The first time an agent uses a skill, it installs the CLI the skill needs.

## Install a CLI

macOS / Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/what1f/ls-skills/main/install.sh | sh -s -- <tool> [version]
```

Windows PowerShell:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/what1f/ls-skills/main/install.ps1))) <tool> [version]
```

Installs to `~/.local/bin` (`%LOCALAPPDATA%\ls-skills\bin` on Windows); set `LS_INSTALL_DIR` to change it. The installer checks SHA-256, and every release carries GitHub build provenance you can verify with `gh attestation verify <file> --repo what1f/ls-skills`.

| Tool | What it does |
| --- | --- |
| [imgen](tools/imgen) | Generate and edit images with OpenAI, Gemini or a Codex login; local cutout and resize |

## Contributing

You need Go (version in `go.mod`) and Zig (version in `.zig-version`).

```sh
make help
make check
go run ./cmd/repo new <name> --lang go|zig|none
```

Layout, the CLI contract, how to write skills and how releases work are in [AGENTS.md](AGENTS.md). PR titles follow [Conventional Commits](https://www.conventionalcommits.org/); they decide the version of each tool and skill.

### One-time maintainer setup

- Settings → General → Pull Requests: allow squash merge only, and use the PR title as the commit message by default.
- Settings → Actions → General: allow GitHub Actions to create and approve pull requests.
- Add a `RELEASE_PLEASE_TOKEN` secret: a fine-grained PAT scoped to this repo with Contents and Pull requests write access, or a GitHub App token. Without it Release PRs are opened by `github-actions[bot]` and their CI waits for manual approval.

## License

[MIT](LICENSE)
