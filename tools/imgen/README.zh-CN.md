# imgen

<p align="center">
  <a href="./README.md">English</a>
</p>

在命令行里生成和编辑图片。变体、重复采样和批量任务都会并行发请求；每张结果都写成文件，加 `--format json` 时以 JSON 汇报。所有模型都能出透明背景：模型不支持原生透明时，imgen 会让它画在纯色背景上，再在本地抠掉。

## 安装

```sh
curl -fsSL https://raw.githubusercontent.com/what1f/ls-skills/main/install.sh | sh -s -- imgen
```

## Provider

| Provider | 凭证 | 状态 |
| --- | --- | --- |
| `codex` | Codex 的 ChatGPT 登录（`codex login`），从 `$CODEX_HOME/auth.json` 读取（默认 `~/.codex`） | 可用。走的是非公开接口，视为实验性 |
| `openai` | `OPENAI_API_KEY`，可选 `OPENAI_BASE_URL` | 可用 |
| `gemini` | `GEMINI_API_KEY` 或 `GOOGLE_API_KEY`，可选 `GEMINI_BASE_URL` | 可用。默认模型 `gemini-nano-banana-2.1`。按 API 文档实现，还没有对真实服务测试过 |

imgen 只读取 Codex 的 token，不会刷新或改写它，这些由 Codex 自己管理。

### 配置文件

在 `~/.config/imgen/config.json` 里可以新增 OpenAI 或 Gemini 兼容的 provider、修改内置 provider，或设置默认模型。也可以放在 `$XDG_CONFIG_HOME/imgen/config.json`、Windows 上的 `%APPDATA%\imgen\config.json`，或用 `$IMGEN_CONFIG` 指定：

```json
{
  "default": "codex/gpt-image-2.5-flare",
  "providers": {
    "relay": {
      "base_url": "https://relay.example.com/v1",
      "api_key_command": "security find-generic-password -s imgen-relay -w",
      "edit_format": "multipart",
      "default_model": "gpt-image-2",
      "models": { "gpt-image-2": {}, "flux-dev": { "edit": false, "sizes": "fixed" } }
    }
  }
}
```

| 字段 | 含义 |
| --- | --- |
| `default` | 什么都没指定时使用的 `provider/model`、`provider` 或 `model` |
| `protocol` | `openai`（默认）或 `gemini` |
| `base_url` | 新增 provider 时必填 |
| `api_key_env` / `api_key_command` | key 的来源：环境变量，或一条输出 key 的命令。key 不写进这个文件。两个都不写时不发送鉴权头 |
| `edit_format` | `multipart`（默认，OpenAI 风格）或 `json`（图片以 data URL 传，Codex 风格） |
| `default_model` | 默认取 `models` 的第一项 |
| `capabilities` | 没在 `models` 里列出的模型使用的默认能力 |
| `models` | 模型名 → 覆盖的能力：`edit`、`mask`、`native_transparent`、`sizes`（`flexible`、`fixed`、`prompt` 或 `ratio`）、`output_format`、`quality`、`max_images` |

和内置 provider 同名时，只覆盖写出来的字段。用 `--provider` 或 `IMGEN_PROVIDER` 选 provider，也可以写成前缀：`--model relay/flux-dev`。模型名本身可以带 `/`。设置了 `HTTPS_PROXY` / `ALL_PROXY` 时请求会走代理。

## 用法

```sh
imgen generate --prompt "A fox app icon, flat vector" --variant "orange" --variant "teal" --out-dir out
imgen generate --prompt "Image 1 is a product photo. Replace the background with white." --image in.png --out out/white.png
imgen generate --prompt "A red apple sticker" --background transparent --out apple.png
imgen generate --model gemini/gemini-3-pro-image --prompt "A city at dawn" --aspect 21:9 --out city.png
imgen generate ... --dry-run --format json   # 只输出计划，不发请求

imgen batch --input jobs.jsonl --out-dir out  # 每行一个 JSON 对象，如 {"prompt":"...","out":"a.png"}

imgen cutout --image green.png --out cut.png  # 在本地去掉纯色背景
imgen resize --image big.png --out small.png --max-dim 512
```

`batch` 遇到限流、超时和 5xx 错误会按退避重试（`--max-attempts`，默认 3 次），并遵守 `Retry-After`。`cutout` 和 `resize` 只读写 PNG。

`imgen <command> --help` 查看全部参数。设计说明见 [docs/design.md](docs/design.md)。
