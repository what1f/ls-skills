#!/bin/sh
# Install a CLI from ls-skills GitHub Releases.
#
#   curl -fsSL https://raw.githubusercontent.com/what1f/ls-skills/main/install.sh | sh -s -- <tool> [version]
#
# Env: LS_INSTALL_DIR (default ~/.local/bin), GITHUB_TOKEN (optional, avoids API rate limits).
set -eu

REPO="what1f/ls-skills"
tool="${1:-}"
version="${2:-}"
dir="${LS_INSTALL_DIR:-$HOME/.local/bin}"

die() { echo "install: $*" >&2; exit 1; }

case "$tool" in
  "" ) echo "usage: install.sh <tool> [version]" >&2; exit 2 ;;
  *[!a-z0-9-]* ) die "invalid tool name: $tool" ;;
esac

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) die "unsupported OS $(uname -s); on Windows use install.ps1" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac
asset="$tool-$os-$arch"

fetch() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$@"
  else
    curl -fsSL "$@"
  fi
}

if [ -n "$version" ]; then
  tags="$tool-v${version#v}"
else
  # Newest first; stable releases of this tool only.
  tags=$(fetch "https://api.github.com/repos/$REPO/releases?per_page=100" |
    grep -oE "\"tag_name\": *\"$tool-v[0-9]+\.[0-9]+\.[0-9]+\"" |
    sed -E 's/.*"([^"]+)"$/\1/' | head -n 5) || true
  [ -n "$tags" ] || die "no release found for $tool"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

found=""
for tag in $tags; do
  base="https://github.com/$REPO/releases/download/$tag"
  # A release can exist briefly before its binaries are uploaded; fall back to the previous one.
  if fetch -o "$tmp/$asset" "$base/$asset" 2>/dev/null && fetch -o "$tmp/checksums.txt" "$base/checksums.txt"; then
    found="$tag"
    break
  fi
done
[ -n "$found" ] || die "no $asset binary found (tried: $(echo $tags))"

expected=$(awk -v f="$asset" '$2 == f { print $1 }' "$tmp/checksums.txt")
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$asset" | awk '{print $1}')
else
  actual=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')
fi
[ -n "$expected" ] && [ "$expected" = "$actual" ] || die "checksum mismatch for $asset"

mkdir -p "$dir"
chmod +x "$tmp/$asset"
mv "$tmp/$asset" "$dir/$tool"
echo "installed $tool ${found#"$tool-v"} to $dir/$tool"

case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "note: $dir is not on PATH; add it to your shell profile" >&2 ;;
esac
