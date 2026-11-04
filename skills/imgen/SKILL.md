---
name: imgen
description: 用 imgen CLI 生成和编辑位图：照片、插画、海报、产品图、UI mockup、logo、icon、sprite、贴纸、纹理，透明背景素材，抠图（去绿幕、去纯色背景），缩小图片。支持 OpenAI gpt-image、Gemini（Nano Banana）和 Codex 登录。当用户说「生成图片」「画一张」「出图」「做个图标」「改图」「P 图」「换背景」「抠图」「透明背景」「generate an image」「make a picture」「edit this photo」「remove background」时使用。要的是 SVG、HTML/CSS 或延续项目里现有的矢量图标时不用。
metadata:
  version: "0.1.0" # x-release-please-version
  requires: "imgen>=0.1.0"
---

# imgen

用 AI 模型生成或编辑图片并写成文件，也能在本地抠掉纯色背景、缩小 PNG。

## 环境准备

命令不存在，或 `imgen version` 低于 frontmatter 中 `metadata.requires` 的版本时，安装后重试一次：

```sh
curl -fsSL https://raw.githubusercontent.com/what1f/ls-skills/main/install.sh | sh -s -- imgen
```

Windows PowerShell：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/what1f/ls-skills/main/install.ps1))) imgen
```

第一次用时运行 `imgen providers --format json`，看哪些 provider 已配好凭证（`configured`）、默认用哪个（`selected`）、各模型支持什么（改图、mask、原生透明、尺寸方式、最多几张输入图）。用户没指定时用默认的，不要自己换 provider。

## 命令

用 `imgen <command> --help` 查看完整参数。

```sh
# 生成一张
imgen generate --prompt "..." --out assets/hero.png --format json
# 同一素材出多个候选：每个 variant 一张，并行请求
imgen generate --prompt "..." --variant "flat vector" --variant "3D clay" --out-dir out --format json
# 改图：输入图按顺序在 prompt 里叫 Image 1、Image 2…
imgen generate --prompt "Image 1: product photo. Replace only the background with pure white." --image in.jpg --out out/white.png --format json
# 透明背景
imgen generate --prompt "..." --background transparent --out icon.png --format json
# 画幅
imgen generate --prompt "..." --aspect 16:9 --out banner.png --format json
# 先看会发出什么请求，不花钱
imgen generate ... --dry-run --format json
# 多个不同素材
imgen batch --input jobs.jsonl --out-dir out --format json
# 本地抠掉纯色背景
imgen cutout --image green.png --out cut.png --format json
# 本地缩小
imgen resize --image big.png --out small.png --max-dim 512 --format json
```

核心参数：

- `--model [provider/]name` 选模型，如 `gemini/gemini-3-pro-image`、`openai/gpt-image-2`
- `--quality low|medium|high|auto`：草稿用 `low`，定稿和带小字的图用 `medium` 或 `high`
- `--aspect W:H` 和 `--size WxH` 二选一。模型不支持精确尺寸时会就近取，并在 `warnings` 里说明
- `--n N` 同一 prompt 采样几次；variant 数 × n 不超过 10

## 工作流

1. **判断意图**：新生成，还是改现有图片。用户没明确要改时按新生成处理。只是给图当风格或构图参考，也算新生成，图通过 `--image` 传入。
2. **标明每张输入图的角色**：在 prompt 里写 `Image 1: edit target`、`Image 2: style reference`。顺序和 `--image` 的顺序一致。
3. **写 prompt**：用户写得具体就只整理结构，写得笼统才补构图、用途这类细节，不加用户没暗示的人物、物件、文案。结构和各类素材的要点见 [references/prompting.md](references/prompting.md)，需要现成模板时看 [references/sample-prompts.md](references/sample-prompts.md)。
4. **选输出位置**：给项目用的素材直接写到项目目录里的目标路径；只是预览的放到临时目录。已有文件不要覆盖，除非用户要求，此时加 `--force`。
5. **生成后查看图片**：检查主体、风格、构图、文字是否准确、约束是否满足。不满意时一次只改一处 prompt 再生成，改图时每轮都重复「保持不变」的约束。
6. **汇报**：最终文件路径、用的 prompt、provider 和模型，以及 `warnings` 里值得用户知道的内容。

variant 和 batch 的区别：同一个素材要几个候选，用 `--variant` 或 `--n`；一组不同的素材（如一套图标、多张配图），用 batch。

## batch

`jobs.jsonl` 每行一个任务，只有 `prompt` 必填：

```jsonl
{"prompt":"App icon: a paper plane, flat vector","out":"icon-send.png"}
{"prompt":"App icon: a magnifying glass, flat vector","out":"icon-search.png"}
{"prompt":"Hero illustration of a city at dawn","aspect":"16:9","quality":"high"}
```

- 可用字段：`prompt`、`variants`、`n`、`images`、`mask`、`provider`、`model`、`aspect`、`size`、`quality`、`background`、`chroma_key`、`output_format`、`compression`、`out`
- `out` 是 `--out-dir` 下的文件名；命令行上的 generate 参数作为每行的默认值
- 任何一行有问题，整个 batch 在发请求前就报错，`message` 以 `line N:` 开头
- 可重试的错误（限流、超时、5xx）默认最多试 3 次（`--max-attempts`）；加 `--fail-fast` 后，第一个失败出现时不再启动新任务

## 透明背景

`--background transparent` 时，`data.transparent` 说明用了哪种方式：

- `native`：模型原生输出透明 PNG
- `chroma-key`：模型不支持透明，imgen 让它画在纯色背景上，再在本地抠掉。prompt 只描述主体，不要自己写背景要求。主体是绿色时加 `--chroma-key '#ff00ff'`

结果里每张图的 `transparent_ratio` 是透明像素占比。接近 0，或者看图发现边缘有色边、背景残留时：

1. 换 `--chroma-key` 颜色，或调整 prompt 让主体轮廓更干净，然后重新生成；或者
2. 改用 `--background opaque`，在 prompt 里自己写「perfectly flat solid #00FF00 background」，再用 `imgen cutout` 调参数：`--key '#RRGGBB'` 指定背景色，`--contract 1` 收掉色边，`--feather 1` 让边缘柔和，`--hard --tolerance N` 处理边缘锐利的像素画

`cutout` 和 `resize` 只接受 PNG。输入是 JPEG 时先转换，macOS 上用 `sips -s format png in.jpg --out in.png`。

## 规则

- 一律加 `--format json`，从 `data.images[].path` 读最终路径：返回格式和扩展名不符时 imgen 会改扩展名。
- 顶层 `ok` 为 false 但有 `data` 时是部分失败，成功的图已经写好了，只重新生成失败的那几张。
- `content_policy`：不要原样重试，告诉用户被拒，可以在不改变用户意图的前提下调整措辞后再试。
- `exists`：换路径，或者确认用户同意覆盖后加 `--force`。
- 退出码 2 是参数错误或模型不支持某项能力，按 `message` 修正后重试。
- 退出码 3 是缺凭证或凭证无效：停止重试，把 `error.message` 转告用户，由用户设置 API key 或运行 `codex login`。
- 不要读取、打印或在命令行参数里传递 API key；凭证只通过环境变量、配置文件里的 `api_key_command` 或 Codex 登录提供。
- 每次请求都要花钱，也要时间（单张常见 10–60 秒）。不确定参数是否生效时先用 `--dry-run`；不要为了「多给几个选择」擅自加大 `--n`。
