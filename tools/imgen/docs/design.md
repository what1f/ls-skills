# imgen 设计

用 Zig 实现的图片生成 CLI，通过环境变量选择 provider。下文命令的入参和出参是对 Agent 的合同；provider 细节是 CLI 的内部实现，不写进 skill。

## 目标与边界

- 一个命令覆盖生成和编辑：输入图片是可选的。到底是「编辑」还是「参考」，由 prompt 的写法决定，skill 负责教 Agent 怎么写。
- 每次请求 provider 都只要一张图。多张图（变体、重复采样、批量）一律由 CLI 并发发起多次请求实现，三家 provider 的行为因此保持一致。
- 只支持 PNG 的本地图像处理（抠图、缩放）。模型输出可以强制为 PNG；JPEG 和 WebP 的解码成本高，不做。
- 不在 CLI 里拼装 prompt：结构化模板写在 skill 里，由 Agent 拼好后传入。唯一的例外是透明背景的绿幕后缀，见下文。

## 命令

所有命令都遵守仓库的 CLI 合同：`--help`、`--format text|json`、退出码 0/1/2/3/130。

### `imgen generate`

| 参数 | 说明 |
| --- | --- |
| `--prompt TEXT` / `--prompt-file PATH` | 二选一，必填；`-` 表示从 stdin 读取 |
| `--variant TEXT`（可重复） | 第 i 张图的 prompt 等于公共 prompt、换行、第 i 个 variant |
| `--n N` | 每个 prompt 采样几次，默认 1；总张数等于 variant 个数（至少按 1 算）乘以 n，上限 10 |
| `--image PATH`（可重复，最多 16 张，有顺序） | 输入图，在 prompt 里按序号说明每张的用途 |
| `--mask PATH` | 必须同时有 `--image`；PNG 格式、带 alpha 通道、尺寸和第一张图相同；只在 provider 声明支持时可用 |
| `--provider NAME`、`--model NAME` | 见「Provider 选择」 |
| `--aspect W:H` / `--size WxH` | 二选一；不传时由 provider 自己决定 |
| `--quality low\|medium\|high\|auto` | 不支持这个参数的 provider 会忽略它，并在 `warnings` 里提示 |
| `--background auto\|opaque\|transparent` | 透明背景见「透明背景」 |
| `--output-format png\|jpeg\|webp`、`--compression 0-100` | 透明背景时强制为 png |
| `--out FILE` / `--out-dir DIR` | 二选一，必填；`FILE` 的图片扩展名会换成实际输出格式，多张图时自动加 `-1`、`-2` 后缀；`DIR` 下按 `image-N` 命名，跳过已存在的名字 |
| `--force` | 覆盖已存在的文件；不加时 `--out` 指向的文件已存在，在发请求前就报 `exists` |
| `--concurrency N` | 默认 4 |
| `--timeout SECONDS` | 单次请求的超时时间，默认 300 |
| `--dry-run` | 不发请求，只输出解析后的计划 |

出参（`--format json`）：

```json
{"ok":true,"data":{
  "provider":"openai","model":"gpt-image-2","elapsed_ms":41200,
  "transparent":"chroma-key",
  "warnings":[],
  "images":[
    {"ok":true,"path":"out/logo-1.png","variant":"flat vector","format":"png","width":1024,"height":1024,"bytes":391220},
    {"ok":false,"variant":"3D clay","error":{"code":"content_policy","message":"…","retryable":false}}
  ]
}}
```

- `transparent` 只在请求了透明背景时出现，值为 `native` 或 `chroma-key`。
- 只要有一张图失败：顶层 `ok` 为 false，加上 `"error":{"code":"partial_failure",…}`，`data` 照常返回，退出码 1。
- `path` 是最终写入的路径。如果实际返回的格式和扩展名对不上，CLI 会改正扩展名，并在 `warnings` 里说明。
- `--dry-run` 时 `data` 包含 `dry_run: true`、`provider`、`model`、每张图最终发出的 prompt、各参数、计划写入的路径，不含图片数据和凭证。

### `imgen batch`

| 参数 | 说明 |
| --- | --- |
| `--input jobs.jsonl` | 必填。每行一个 JSON 对象，字段和 generate 相同，用 snake_case 命名（`prompt`、`variants`、`n`、`images`、`mask`、`model`、`aspect`、`size`、`quality`、`background`、`output_format`、`compression`、`out`）。`out` 是在 `--out-dir` 下的文件名，不写时用 `001-<prompt 前若干字转成的短名>`。空行和以 `#` 开头的行会被忽略 |
| `--out-dir DIR` | 必填 |
| 其余 generate 的参数 | 作为所有任务的默认值，每行可以覆盖 |
| `--concurrency N`、`--max-attempts N`（默认 3）、`--fail-fast` | 遇到可重试的错误时按指数退避重试，优先采用服务端的 `Retry-After` |

出参：

```json
{"ok":true,"data":{"succeeded":2,"failed":0,"jobs":[{"line":1,"ok":true,"images":[…]},…]}}
```

部分失败的处理和 generate 相同。进度（开始、完成、重试）写到 stderr。

### `imgen cutout`

本地绿幕抠图，不联网。算法移植自 Codex 内置 imagegen 的 `remove_chroma_key.py`。

| 参数 | 说明 |
| --- | --- |
| `--image PATH --out PATH` | 输入和输出都只支持 PNG；输入不是 PNG 时报 `unsupported`，message 里提示先转换格式（如 macOS 上 `sips -s format png`） |
| `--key auto\|#RRGGBB` | 默认 `auto`：从图片边缘采样，取中位数作为背景色 |
| `--tolerance N` | 硬抠图时的颜色容差，默认 12 |
| `--soft` / `--hard` | 默认 `--soft`：按颜色距离平滑过渡，生成半透明边缘 |
| `--despill` | 默认开启，用 `--no-despill` 关闭：去掉边缘上残留的背景色 |
| `--contract N`、`--feather N` | 先把边缘向内收 N 像素，再模糊 alpha 通道 |
| `--force` | 覆盖已存在的输出文件 |

出参：

```json
{"ok":true,"data":{"path":"…","key_color":"#00ff00","width":1024,"height":1024,"transparent_ratio":0.61,"partial_ratio":0.02,"warnings":[]}}
```

透明像素占比为 0 时，用 `warnings` 提示，说明背景色可能没取对。

### `imgen resize`

| 参数 | 说明 |
| --- | --- |
| `--image PATH --out PATH` | 只支持 PNG |
| `--max-dim N` / `--width N` / `--height N` | 三选一，保持宽高比，只缩小不放大 |
| `--force` | |

出参：`{"path","width","height","bytes"}`。缩放用面积平均（box filter），缩小时效果好，实现也简单。

### `imgen providers`

出参：

```json
{"ok":true,"data":{"selected":"openai","providers":[
  {"name":"openai","configured":true,"credential":"OPENAI_API_KEY","base_url":"https://api.openai.com/v1","default_model":"gpt-image-2",
   "models":[{"name":"gpt-image-2","edit":true,"mask":true,"native_transparent":false,"sizes":"flexible","max_images":16}]},
  {"name":"gemini","configured":false,"credential":"GEMINI_API_KEY", …},
  {"name":"codex","configured":true,"credential":"~/.codex/auth.json", …}
]}}
```

`selected` 是不带任何参数时会选中的 provider；一个都没有配置时为 null。

### `imgen version`

使用 clikit 的标准实现。

## Provider 选择

provider 分两种来源：内置的 openai、gemini、codex，以及配置文件里声明的。配置文件可以新增 provider，也可以覆盖内置 provider 的部分字段（不能改协议）。字段说明见 [README](../README.md#config-file)。

- 配置文件路径：`$IMGEN_CONFIG`，否则 `$XDG_CONFIG_HOME/imgen/config.json`，否则 `~/.config/imgen/config.json`（Windows 为 `%APPDATA%\imgen\config.json`）。不存在时只有内置 provider。
- 格式错误、出现未知字段时报 `config`（退出码 2），message 带文件路径、行号和列号。Agent 直接编辑这个 JSON，CLI 不提供写配置的命令。
- 配置里只写密钥来源（`api_key_env` 或 `api_key_command`），不写密钥本身。

模型可以写成 `provider/model`；只有前缀是已知 provider 时才拆分，所以模型名本身可以带 `/`。

优先级从高到低，每一层可以给出 provider、模型，或两者都给：

1. `--provider`、`--model`（两者的 provider 不一致时报 `usage`）
2. `IMGEN_PROVIDER`、`IMGEN_MODEL`
3. 配置文件的 `default`
4. 按模型名推断：`gemini-*` 对应 gemini
5. 自动探测：第一个有凭证的内置 provider（顺序 openai、gemini、codex），然后是配置里用 `api_key_env` 的 provider；不会为了探测去执行 `api_key_command`

provider 确定后，模型取第一个「没写 provider 或写的正是这个 provider」的层，都没有时用该 provider 的 `default_model`。

- 选中的 provider 没有凭证时，报 `auth`（退出码 3），message 里写清楚要设置哪个环境变量或运行什么命令。
- 不认识的模型名不拦截，按该 provider 的 `capabilities`（没写时用协议默认值）处理，这样新模型上线不用等 CLI 发版。
- 已知模型的能力用来提前校验：编辑、mask、原生透明背景、尺寸规则、最多几张输入图。请求用到不支持的能力时，在发请求前就报 `unsupported`（退出码 2）。透明背景例外，见下文。

代理读取 `HTTPS_PROXY`、`ALL_PROXY`，通过 `std.http.Client.initDefaultProxies` 实现。

## Provider 实现

| | openai | codex | gemini |
| --- | --- | --- | --- |
| 鉴权 | `Authorization: Bearer $OPENAI_API_KEY` | 每次调用都重新读取 `auth.json` 的 `tokens.access_token`，不负责刷新（刷新由 Codex 管理） | `x-goog-api-key` |
| 地址 | `{base}/images/generations`，带输入图时走 `{base}/images/edits` | `https://chatgpt.com/backend-api/codex`，路径和 openai 相同 | `{base}/v1beta/models/{model}:generateContent` |
| 编辑请求格式 | multipart（一张图用 `image`，多张用 `image[]`，加 `mask`）；配置 `edit_format` 可改 | JSON：`images:[{image_url:<data URL>}]`、`mask:{image_url}`（该后端不接受 multipart） | `contents.parts` 里放 `inline_data` |
| 画幅 | 映射成 `size`（规则见下文） | 后端忽略 `size`，在 prompt 末尾追加 `Aspect ratio W:H.`；传 `--size` 时给出 warning | `generationConfig.imageConfig.aspectRatio` 和 `imageSize` |
| mask | 支持 | 支持 | 不支持 |
| 原生透明背景 | 取决于模型（gpt-image-1.5 支持，gpt-image-2 不支持） | 支持 | 不支持 |
| 输出格式 | `output_format` | 忽略 `output_format`，总是 PNG | 总是 PNG |
| 返回 | `data[].b64_json`；兼容服务返回 `data[].url` 时不带鉴权头下载 | 同 openai | `candidates[].content.parts[].inline_data.data` |

openai、codex 和配置里的 OpenAI 兼容服务共用一套协议代码，区别只在配置：base URL、凭证来源、编辑请求格式、模型能力。codex 用的是非公开接口，README 里标为实验性。

画幅映射到 openai 的 `size`：

- gpt-image-1 和 1.5 只有 3 档尺寸，选比例最接近的那一档：`1024x1024`、`1536x1024`、`1024x1536`。
- gpt-image-2 尺寸灵活：按目标比例算出宽高，长边取 1536，宽高都取 16 的倍数，并满足总像素、长短边比例、最长边这些限制。

## 透明背景

`--background transparent` 时的处理：

1. 模型原生支持透明：传 `background=transparent`，并强制 PNG。输出 `transparent: "native"`。
2. 原生不支持：
   - 在 prompt 末尾追加一段固定说明：「主体放在完全均匀的纯 `#00FF00` 背景上，没有阴影、渐变和反光，主体本身不含这种绿色」
   - 强制返回 PNG
   - 拿到图片后，在本地按 `cutout` 的默认参数抠图（`--key auto --soft --despill`）
   - 输出 `transparent: "chroma-key"`，`warnings` 里附上透明像素占比

   主体本身带绿色时，用 `--chroma-key #FF00FF` 换成品红背景。这个参数只在 chroma-key 模式下生效。

原始的绿幕图不保留。如果抠图效果不理想，Agent 可以加 `--background opaque` 并在 prompt 里自己写绿幕要求重新生成，然后用 `cutout` 调参数。

## 错误码

| code | 场景 | 退出码 | retryable |
| --- | --- | --- | --- |
| `usage` | 参数错误 | 2 | false |
| `config` | 配置文件格式错误 | 2 | false |
| `unsupported` | 当前 provider 或模型不支持这个能力；图片格式不支持 | 2 | false |
| `exists` | 输出文件已存在 | 2 | false |
| `auth` | 缺少凭证，或返回 401/403 | 3 | false |
| `rate_limited` | 返回 429 | 1 | true |
| `timeout` | 请求超时、连接失败 | 1 | true |
| `content_policy` | 被内容审核拒绝 | 1 | false |
| `provider_error` | 返回 5xx（可重试），或其他 4xx（不可重试） | 1 | 视情况 |
| `partial_failure` | 多张图里有一部分失败；全部失败且原因相同时直接报那个原因 | 1 | false |
| `write_failed` | 写输出文件失败 | 1 | false |
| `cancelled` | 被 Ctrl-C 取消 | 130 | false |

`message` 优先使用 provider 返回的原始错误文本，凭证一律不出现在任何输出里。

## 本地图像处理（纯 Zig，不依赖 C 库）

- **PNG 解码**：支持颜色类型 0/2/3/4/6，位深 1/2/4/8/16（统一转成 RGBA8），以及 5 种行过滤。Adam7 隔行扫描的图报 `unsupported`。
- **PNG 编码**：输出 RGBA8，每行在 5 种过滤里选绝对值之和最小的一种，用 `std.compress.flate` 的 zlib 格式压缩。
- **读取图片宽高**：只读文件头，支持 PNG（IHDR）、JPEG（SOF 段）、WebP（VP8、VP8L、VP8X），这样 generate 的输出不需要完整解码。
- **抠图**：移植 `remove_chroma_key.py` 的这些步骤：边缘采样取背景色、颜色距离、平滑过渡的软边、按颜色主导程度计算 alpha、去溢色、用 3×3 最小值滤波收边、用高斯模糊羽化 alpha。
- **缩放**：面积平均。

## 代码结构（`tools/imgen/cli/src/`）

```
main.zig            命令分发
cmd/generate.zig    generate 和 batch 共用的执行器：展开 variant × n、并发、重试、写文件
cmd/batch.zig       解析 JSONL、合并默认值
cmd/cutout.zig  cmd/resize.zig  cmd/providers.zig
provider.zig        provider 注册表：内置 provider、读取 config.json、选择 provider 和模型、取凭证
provider/openai.zig provider/codex.zig provider/gemini.zig   （codex 是 openai 协议的一套配置，codex.zig 只读登录 token）
http.zig            HTTP 客户端（代理、超时、错误映射）、multipart 拼装
image/png.zig  image/sniff.zig  image/chroma.zig  image/resize.zig
output.zig          计算输出路径、检查文件是否已存在、改正扩展名
```

并发用 `std.Io.Group`，并发数由 `--concurrency` 限制。

## 测试

- 单元测试不联网：provider 层用固定的请求和响应样本，校验请求体怎么组装、响应和错误怎么解析。
- PNG：读写来回测试，覆盖各种颜色类型和位深的样例图，再和已知的像素值对比。
- 抠图和缩放：用代码合成的测试图，校验透明像素占比和边缘的 alpha 值。
- `--dry-run` 测试覆盖 provider 选择、画幅映射、输出路径计算。
- 真实接口的冒烟测试只手动运行，不进 CI。

## skill 结构（`skills/imgen/`）

- **SKILL.md**：
  - 环境准备：安装 CLI；凭证缺失时告诉用户该设置哪个环境变量
  - 选 provider 和模型：各家的草稿模型和终稿模型；用 `imgen providers` 查看可用情况
  - 工作流：沿用 imagegen 的流程，包括判断意图、标注每张输入图的角色、先出草稿再出终稿、文件不覆盖、汇报最终路径和 prompt
  - prompt 结构模板
  - 变体：`--variant` 用于同一素材的多个候选，batch 用于多个不同的素材
  - 透明背景和 `cutout` 调参
  - 规则
- **references/prompting.md、sample-prompts.md**：改写自 imagegen，那边是 Apache-2.0 许可，需要保留出处声明。

## 实现前要核实的事

- Gemini 当前的图像模型名、`imageConfig` 支持哪些比例和 `imageSize` 档位、返回图片的格式。
- gpt-image-2 现在是否支持原生透明背景、是否支持 mask。
- Zig 0.17 的 `std.http.Client` 走代理时的表现（`NO_PROXY` 不支持）。

## 已核实（2026-11）

- Codex 后端：模型名不校验（未知模型也能出图），`size` 和 `output_format` 被忽略，总是返回 PNG；画幅写进 prompt 有效（16:9 得到 1672×941）；`background: transparent` 返回 RGBA；JSON 形式的 edits 和 mask 都生效。错误体有 `{"detail":…}` 和 `{"error":{…}}` 两种。
- Zig 0.17：`fetch` 的 `privileged_headers` 不会被发送，鉴权头要用 `headers.authorization`；stdout/stderr 要用 `File.Writer.initStreaming`，默认的 positional 模式在多个进程共用一个重定向文件时会互相覆盖；几 MB 的响应体用 `Writer.Allocating` 整体读入即可。
