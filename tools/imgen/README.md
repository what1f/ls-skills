# imgen

Generate and edit images from the command line. Variants and repeated samples run as parallel requests; every result is written to a file and reported as JSON with `--format json`.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/what1f/ls-skills/main/install.sh | sh -s -- imgen
```

## Providers

| Provider | Credential | Status |
| --- | --- | --- |
| `codex` | Codex ChatGPT login (`codex login`), read from `$CODEX_HOME/auth.json` (default `~/.codex`) | Available. Uses a non-public endpoint, so treat it as experimental |
| `openai` | `OPENAI_API_KEY`, optional `OPENAI_BASE_URL` | Available |
| `gemini` | `GEMINI_API_KEY` or `GOOGLE_API_KEY`, optional `GEMINI_BASE_URL` | Planned |

imgen only reads the Codex token. It never refreshes or writes it; Codex manages that.

### Config file

Add OpenAI-compatible providers, change built-in ones, or set the default model in `~/.config/imgen/config.json` (`$XDG_CONFIG_HOME/imgen/config.json`, `%APPDATA%\imgen\config.json` on Windows, or `$IMGEN_CONFIG`):

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

| Field | Meaning |
| --- | --- |
| `default` | `provider/model`, `provider` or `model` used when nothing else is given |
| `protocol` | `openai` (default) or `gemini` |
| `base_url` | Required for new providers |
| `api_key_env` / `api_key_command` | Where the key comes from: an environment variable, or a command that prints it. Keys never go in this file. Neither means no `Authorization` header |
| `edit_format` | `multipart` (default, OpenAI style) or `json` (images as data URLs, Codex style) |
| `default_model` | Defaults to the first entry in `models` |
| `capabilities` | Defaults for models not listed in `models` |
| `models` | Model name → capability overrides: `edit`, `mask`, `native_transparent`, `sizes` (`flexible`, `fixed` or `prompt`), `output_format`, `quality`, `max_images` |

A provider with the same name as a built-in one overrides only the fields it sets. Pick a provider with `--provider` or `IMGEN_PROVIDER`, or write it as a prefix: `--model relay/flux-dev`. Model names may contain `/` themselves. Requests go through `HTTPS_PROXY` / `ALL_PROXY` when set.

## Usage

```sh
imgen generate --prompt "A fox app icon, flat vector" --variant "orange" --variant "teal" --out-dir out
imgen generate --prompt "Image 1 is a product photo. Replace the background with white." --image in.png --out out/white.png
imgen generate --prompt "A red apple sticker" --background transparent --out apple.png
imgen generate ... --dry-run --format json   # print the plan without sending requests
```

Run `imgen <command> --help` for all flags. The design notes are in [docs/design.md](docs/design.md).
