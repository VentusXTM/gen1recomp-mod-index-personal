#!/usr/bin/env bash
#
# validate-mod.sh — validate a Gen1Recomp mod from its GitHub repo.
#
# Resolves the latest release of a mod repo, downloads the .zip asset,
# extracts it, and validates the manifest with the REAL engine validation
# code via scripts/validate-mod.lua.
#
# Usage:
#   validate-mod.sh <github-url|owner/repo> [--engine <semver>]
#
# Examples:
#   ./scripts/validate-mod.sh 1iminal/gen1recomp-no-exp-challenge
#   ./scripts/validate-mod.sh https://github.com/owner/repo --engine 0.9.0
#
# Environment:
#   LUA_BIN                  Lua interpreter (default: lua / lua5.4 / luajit on PATH)
#   GEN1RECOMP_ENGINE_REPO   engine repo used by validate-mod.lua
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: validate-mod.sh <github-url|owner/repo> [--engine <semver>]

Resolve the latest release of a Gen1Recomp mod repo, download the .zip asset,
extract it, and validate the manifest with the REAL engine validation code
(scripts/validate-mod.lua + the engine's src/mods/Manifest.lua, Semver.lua and
src/core/Version.lua).

Options:
  --engine <semver>   Override the engine version for the game_version range
                      check (the engine working tree reports 0.0.0-dev).

Environment:
  LUA_BIN                  Lua interpreter to use (default: lua/lua5.4/luajit)
  GEN1RECOMP_ENGINE_REPO   Engine repo path for validate-mod.lua

Examples:
  ./scripts/validate-mod.sh 1iminal/gen1recomp-no-exp-challenge
  ./scripts/validate-mod.sh https://github.com/owner/repo --engine 0.9.0
EOF
}

repo=""
engine=""
while [ $# -gt 0 ]; do
  case "$1" in
    --engine)
      engine="${2:-}"
      [ -n "$engine" ] || { echo "error: --engine needs a value" >&2; exit 1; }
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      repo="$1"
      shift
      ;;
  esac
done
[ -n "$repo" ] || { usage >&2; exit 1; }

# --- parse owner/repo from "owner/repo" or a github.com URL
if [[ "$repo" =~ ^https?://github\.com/([^/]+)/([^/]+)/?$ ]]; then
  owner="${BASH_REMATCH[1]}"
  rname="${BASH_REMATCH[2]}"
elif [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  owner="${repo%/*}"
  rname="${repo#*/}"
else
  echo "error: expected a GitHub URL or owner/repo, got: $repo" >&2
  exit 1
fi
rname="${rname%.git}"

# --- toolchain
for tool in gh jq unzip curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done
LUA_BIN="${LUA_BIN:-$(command -v lua || command -v lua5.4 || command -v lua5.3 || command -v lua5.1 || command -v luajit || true)}"
if [ -z "$LUA_BIN" ]; then
  echo "error: no lua interpreter found on PATH (set LUA_BIN)" >&2
  exit 1
fi

# --- resolve the latest release
echo "resolving latest release of $owner/$rname ..."
release="$(gh api "repos/$owner/$rname/releases/latest" 2>/dev/null)" || {
  echo "error: no latest release for $owner/$rname (repo has no releases)" >&2
  exit 1
}
tag="$(jq -r '.tag_name // empty' <<<"$release")"

zip_names=()
zip_urls=()
while IFS=$'\t' read -r zname zurl; do
  [ -n "$zname" ] || continue
  zip_names+=("$zname")
  zip_urls+=("$zurl")
done < <(jq -r '.assets[] | select(.name | test("\\.zip$"; "i")) | [.name, .browser_download_url] | @tsv' <<<"$release")
if [ "${#zip_names[@]}" -eq 0 ]; then
  echo "error: latest release $tag of $owner/$rname has no .zip asset" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- download the first zip asset, then prefer "<id>-<version>.zip" if a
#     better-named asset is visible once the manifest id is known
ZIP="$TMP/release.zip"
ZIP_NAME="${zip_names[0]}"
curl -fsSL -o "$ZIP" "${zip_urls[0]}"

manifest_entry="$(unzip -Z1 "$ZIP" | grep -m1 'manifest\.json$' || true)"
if [ -n "$manifest_entry" ]; then
  read -r mid mversion < <(unzip -p "$ZIP" "$manifest_entry" | jq -r '[.id, .version] | @tsv' 2>/dev/null || true)
  if [ -n "${mid:-}" ] && [ -n "${mversion:-}" ]; then
    wanted="${mid}-${mversion}.zip"
    for i in "${!zip_names[@]}"; do
      if [ "${zip_names[$i]}" = "$wanted" ] && [ "${zip_names[$i]}" != "$ZIP_NAME" ]; then
        echo "preferring asset $wanted over $ZIP_NAME"
        curl -fsSL -o "$ZIP" "${zip_urls[$i]}"
        ZIP_NAME="${zip_names[$i]}"
        break
      fi
    done
  fi
fi

echo "release: $tag, zip: $ZIP_NAME"

# --- extract and locate the manifest
DIR="$TMP/mod"
mkdir -p "$DIR"
unzip -o -q "$ZIP" -d "$DIR"

manifest_path="$(find "$DIR" -name manifest.json | head -1 || true)"
if [ -z "$manifest_path" ]; then
  echo "error: no manifest.json inside the zip" >&2
  exit 1
fi

# --- run the REAL engine validation
echo "validating against the real engine code ..."
if [ -n "$engine" ]; then
  "$LUA_BIN" "$SCRIPT_DIR/validate-mod.lua" --zip-dir "$DIR" --manifest "$manifest_path" --engine "$engine"
else
  "$LUA_BIN" "$SCRIPT_DIR/validate-mod.lua" --zip-dir "$DIR" --manifest "$manifest_path"
fi
