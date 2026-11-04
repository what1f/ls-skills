# ls-skills

这个开源仓库同时放 CLI（Go / Zig）和配套的 Agent skill，CLI 通过 GitHub Release 分发。

## 目录

| 路径 | 职责 |
| --- | --- |
| `tools/<name>/` | 一个 CLI：`tool.yaml`（元数据与版本）、`cli/`（源码）、`CHANGELOG.md`、`README.md`（给人看的英文说明，可加 `README.zh-CN.md` 中文版，两者顶部互相链接），可选 `AGENTS.md`（只写该工具的额外要求） |
| `skills/<name>/` | 一个 skill：`SKILL.md`、`CHANGELOG.md`，可选 `references/`、`scripts/`、`assets/` |
| `packages/go/clikit`、`packages/zig/clikit` | CLI 合同的公共实现：version、`--format`、输出格式、退出码 |
| `cmd/repo`、`internal/repo` | 仓库工具：结构检查、同步、交叉编译、脚手架；新建工具的模板在 `internal/repo/templates/` |
| `install.sh`、`install.ps1` | 用户安装 CLI 的唯一入口 |
| `release-please-config.json`、`.release-please-manifest.json`、`.claude-plugin/marketplace.json` | 生成文件：用 `make sync` 维护，手改会被检查拦下 |

- `tools/<name>` 和 `skills/<name>` 同名配对，配对关系写在 `tool.yaml` 的 `skill:` 字段；没有 skill 的工具写 `skill: null`，也可以只有 skill 没有 CLI。

## 命令

```sh
make check [TOOL=foo]                  # 提交前必跑：结构、fmt、vet、测试、本机构建并校验 version
make sync                              # 新增、删除或改名工具/skill，以及修改 description 后运行
make build TOOL=foo [PLATFORM=linux-arm64 | ALL=1]   # 交叉编译到 dist/foo/
go run ./cmd/repo new foo --lang go|zig|none [--no-skill]   # 新建工具或 skill
```

`go run ./cmd/repo help` 列出全部子命令。

## 新增工具或 skill

1. 一律用 `go run ./cmd/repo new` 生成，不要从别的目录复制。`--lang none` 只生成 skill，`--no-skill` 只生成 CLI。
2. 实现命令；把 SKILL.md 和工具 README 里的 TODO 都换成真实内容。
3. `make check TOOL=foo` 通过。
4. PR 标题写成 `feat(foo): ...`。

## 仓库约束

结构检查会强制执行，违反时 `make check` 会给出原因：

- 只有根目录一个 `go.mod`；`tools/`、`skills/`、`packages/` 下不放 `go.mod`、`go.sum` 或嵌套的 `.git`。
- 全仓库只用一个 Zig 版本（`.zig-version`），每个 `build.zig.zon` 的 `minimum_zig_version` 要和它一致；Zig 工具通过 `.path` 依赖引用 `packages/zig/clikit`。
- `CLAUDE.md` 一律是指向同目录 `AGENTS.md` 的符号链接。
- 工具名和 skill 名用 kebab-case，并且等于目录名。

## 版本与发布

由 release-please 管理。每个 `tools/<name>` 和 `skills/<name>` 都是独立的包，有自己的版本号和 `CHANGELOG.md`。

- **版本号与 CHANGELOG 只由 Release PR 修改。** 带 `x-release-please-version` 标记的行都是版本源，包括 `tool.yaml`、SKILL.md 的 `metadata.version`、`build.zig.zon` 和 marketplace.json，发版时会一起更新。可以在 Release PR 里润色 CHANGELOG 的措辞。
- **PR 标题用 Conventional Commits**（squash 合并后它就是 commit 信息）：
  - `feat` 升 minor，`fix`、`perf` 升 patch，加 `!` 升 major（1.0 之前升 minor）
  - `docs`、`chore`、`refactor`、`test`、`ci` 不触发发版
- **哪些改动会进 Release PR**：commit 按路径归属。改到了哪个 `tools/<name>/` 或 `skills/<name>/`，哪个包就会进 Release PR。
  - skill 的内容就是产品本身，改 SKILL.md 或 `references/` 要用 `feat` 或 `fix`，用 `docs` 不会发版。
  - 只改 `packages/`、`cmd/`、`internal/` 不会触发任何发版。如果希望某个工具带着公共包的改动发版，同一个 PR 里要有这个工具目录下的改动，比如对应的测试。
- **发布链路**：合并 Release PR 后自动打 tag、建 Release，然后 `publish` workflow 编译全部平台，生成 `checksums.txt` 和构建来源证明，上传到 Release。
  - tag 格式：CLI 是 `<tool>-vX.Y.Z`，skill 是 `<skill>-skill-vX.Y.Z`
  - 上传失败时，在 Actions 里手动运行 `publish` 并传入同一个 tag 重跑
- **CI 按改动决定跑什么**：只改 `.md`（SKILL.md 除外）不跑 CI；改了别的跑结构检查；改到工具目录、公共包或仓库工具时检查受影响的工具；只有版本号变了的工具（即 Release PR）才交叉编译并上真机 smoke。`go run ./cmd/repo plan --base main` 可以本地预览。
- **skill 依赖新版 CLI 时**，把 `metadata.requires` 改成新版本号，先合并 CLI 的 Release PR，再合并 skill 的。
- 打 tag、推送、合并 Release PR、手动触发 publish，都只在用户明确要求时执行。

## CLI 合同

每个 CLI 都要满足下面几点，能用 clikit 实现的部分一律用 clikit：

- 支持 `<tool> version` 和 `<tool> --version`。版本、commit、日期在构建时注入，直接 `go run` 或 `zig build` 得到的版本是 `dev`。CI 会运行编译出的二进制，核对 version 输出和 `tool.yaml` 一致。
- 每个命令都支持 `--help`：输出到 stdout，退出码 0。
- 业务命令支持 `--format text|json`，默认 text。JSON 模式下 stdout 只输出一个对象：
  - 成功：`{"ok":true,"data":{...}}`
  - 失败：`{"ok":false,"error":{"code","message","retryable"}}`
  - 提示和进度写到 stderr。字段用 snake_case，时间用 RFC 3339，空列表输出 `[]`。
- 退出码：0 成功，1 执行失败，2 参数错误，3 需要用户介入（登录、授权、人工确认），130 被取消。
- 写操作默认只预览，加 `--apply` 才真正提交。
- 只用纯 Go（`CGO_ENABLED=0`）或纯 Zig，`tool.yaml` 里列出的平台都要能在 Linux 上交叉编译出来。
- 测试不联网，也不调用真实的写接口。

## SKILL.md 写法

SKILL.md 是给 Agent 的操作手册，只写怎么用，不写内部设计和实现逻辑。

- **frontmatter**：
  - `name`：等于目录名
  - `description`：写清做什么、什么时候用，并写进用户的真实说法、链接域名和同义词。它是触发 skill 的唯一依据。
  - `metadata.version`：由发版流程维护
  - `metadata.requires`：配对 CLI 的最低版本，写成 `<tool>>=X.Y.Z`
- **正文顺序**，按需取舍，短 skill 只保留用得到的段落：
  1. 环境准备：命令不存在，或版本低于 `requires` 时，运行安装器后重试一次
  2. 常用命令和核心参数，长尾参数让 Agent 自己查 `--help`
  3. 典型工作流
  4. 规则：`--help` 里看不出来的坑、写操作的确认要求、退出码 3 时停止重试
- **references/**：只有部分任务才用到的长内容放进去，SKILL.md 里用带条件的指针引用，例如「涉及 X 时读 [references/x.md](references/x.md)」。正文控制在 500 行以内。
- 不抄 `--help` 的全量参数，不写调用链和实现原理。这些内容放在 `tools/<name>/README.md` 或源码里。
