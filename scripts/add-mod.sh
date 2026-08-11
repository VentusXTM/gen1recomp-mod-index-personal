#!/usr/bin/env bash
#
# add-mod.sh — validate a Gen1Recomp mod from its GitHub repo, then create
# its listing in the index.
#
#   ./scripts/add-mod.sh <github-url|owner/repo> [--engine <semver>] [--base <url>]
#
# 1. Runs validate-mod.sh (real engine validation).  Any failure aborts here
#    and nothing is created.
# 2. Parses the "VALID ..." line and the JSON facts block that
#    validate-mod.lua emits.
# 3. Derives the author from the GitHub repo owner (the engine manifest has
#    no author field).
# 4. Maps the manifest `category` to the index schema categories enum, using
#    the engine's own category vocabulary (CONTRIBUTING-mods.md, "Category"):
#    TWEAK|GAMEPLAY->GAMEPLAY, BALANCE->BALANCE, CONTENT->CONTENT,
#    QUEST->CONTENT, MECHANIC->GAMEPLAY, GRAPHICS->ART, LANGUAGE->TRANSLATION,
#    AUDIO->AUDIO, UI->UI, TOOL->TOOL, TOTAL_CONVERSION->TOTAL_CONVERSION,
#    OTHER->OTHER.  Anything else maps to OTHER with a warning.
# 5. Writes mods/<author>@<id>/meta.json (official schema) and description.md.
# 6. Rebuilds site/data/index.json via build-index.mjs (--base passthrough).
#
# Idempotency: if mods/<author>@<id>/ already exists, prints an error and
# exits 1 without overwriting.
#
# Environment:
#   LUA_BIN                  Lua interpreter (default: lua / lua5.4 / luajit on PATH)
#   GEN1RECOMP_ENGINE_REPO   engine repo used by validate-mod.lua

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: add-mod.sh <github-url|owner/repo> [--engine <semver>] [--base <url>]

Validate a Gen1Recomp mod with the real engine code, then create its listing:

  1. validate-mod.sh  (aborts here on failure — nothing is created)
  2. mods/<author>@<id>/meta.json + description.md
  3. rebuild site/data/index.json

Options:
  --engine <semver>   Forwarded to validate-mod.sh (engine version for the
                      game_version range check).
  --base <url>        Forwarded to build-index.mjs (index base URL).

Examples:
  ./scripts/add-mod.sh 1iminal/gen1recomp-no-exp-challenge
  ./scripts/add-mod.sh https://github.com/owner/repo --engine 0.9.0 \
      --base https://YOU.github.io/REPO/
EOF
}

# --- argument parsing
repo=""
engine=""
base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --engine)
      engine="${2:-}"
      [ -n "$engine" ] || { echo "error: --engine needs a value" >&2; exit 1; }
      shift 2
      ;;
    --base)
      base="${2:-}"
      [ -n "$base" ] || { echo "error: --base needs a value" >&2; exit 1; }
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

# --- owner/repo from "owner/repo" or a github.com URL
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

# --- toolchain (LUA_BIN resolution matches validate-mod.sh)
command -v node >/dev/null 2>&1 || { echo "error: node is required" >&2; exit 1; }
LUA_BIN="${LUA_BIN:-$(command -v lua || command -v lua5.4 || command -v lua5.3 || command -v lua5.1 || command -v luajit || true)}"
if [ -z "$LUA_BIN" ]; then
  echo "error: no lua interpreter found on PATH (set LUA_BIN)" >&2
  exit 1
fi
export LUA_BIN

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. validate (abort here on failure — nothing is created)
echo "==> validating $owner/$rname against the real engine code ..."
val_args=("$SCRIPT_DIR/validate-mod.sh" "$owner/$rname")
if [ -n "$engine" ]; then
  val_args+=(--engine "$engine")
fi
val_status=0
val_out="$("${val_args[@]}" 2>&1)" || val_status=$?
if [ "$val_status" -ne 0 ]; then
  printf '%s\n' "$val_out" >&2
  echo "error: validation failed for $owner/$rname — nothing was created" >&2
  exit 1
fi

# --- 2. parse the VALID line + the JSON facts block
facts="$(printf '%s\n' "$val_out" | awk '/^\{$/{found=1} found{print}')"
if [ -z "$facts" ]; then
  printf '%s\n' "$val_out" >&2
  echo "error: no JSON facts block in the validation output" >&2
  exit 1
fi
printf '%s\n' "$facts" > "$TMP/facts.json"

id="$(jq -r '.id // empty' "$TMP/facts.json")"
name="$(jq -r '.name // empty' "$TMP/facts.json")"
version="$(jq -r '.version // empty' "$TMP/facts.json")"
description="$(jq -r '.description // empty' "$TMP/facts.json")"
api="$(jq -r '.api // empty' "$TMP/facts.json")"
profile="$(jq -r '.profile // empty' "$TMP/facts.json")"
game_version="$(jq -r '.game_version // empty' "$TMP/facts.json")"
manifest_cat="$(jq -r '.category // "OTHER"' "$TMP/facts.json")"
permissions="$(jq -c '.permissions // []' "$TMP/facts.json")"

if [ -z "$id" ] || [ -z "$name" ] || [ -z "$version" ]; then
  echo "error: validation output is missing id/name/version — cannot create listing" >&2
  exit 1
fi

# --- 3. author comes from the GitHub repo owner, never from the manifest
author="$owner"
github_slug="$owner/$rname"
repo_url="https://github.com/$owner/$rname"

# --- 4. map the manifest category to the index categories enum
case "$manifest_cat" in
  TWEAK|GAMEPLAY)  mapped="GAMEPLAY" ;;
  BALANCE)         mapped="BALANCE" ;;
  CONTENT)         mapped="CONTENT" ;;
  QUEST)           mapped="CONTENT" ;;
  MECHANIC)        mapped="GAMEPLAY" ;;
  GRAPHICS)        mapped="ART" ;;
  LANGUAGE)        mapped="TRANSLATION" ;;
  AUDIO)           mapped="AUDIO" ;;
  UI)              mapped="UI" ;;
  TOOL)            mapped="TOOL" ;;
  TOTAL_CONVERSION) mapped="TOTAL_CONVERSION" ;;
  OTHER)           mapped="OTHER" ;;
  *)
    mapped="OTHER"
    echo "warning: unknown manifest category \"$manifest_cat\" — mapped to OTHER" >&2
    ;;
esac
categories_json="[\"$mapped\"]"

# --- idempotency: never overwrite an existing folder
folder="$REPO_ROOT/mods/$author@$id"
if [ -e "$folder" ]; then
  echo "error: $folder already exists — refusing to overwrite" >&2
  exit 1
fi

# --- schema-compat checks (schema/mod.schema.json)
if ! grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+].*)?$' <<<"$version"; then
  echo "error: manifest version \"$version\" is not strict semver (schema requires X.Y.Z) — nothing was created" >&2
  exit 1
fi
if [ "${#name}" -gt 80 ]; then
  echo "error: manifest name is ${#name} chars (schema title max 80) — nothing was created" >&2
  exit 1
fi
if [ "${#author}" -gt 64 ]; then
  echo "error: author \"$author\" is ${#author} chars (schema max 64) — nothing was created" >&2
  exit 1
fi

# --- 5. create the listing
summary="$(jq -rn --arg s "$description" '$s[0:200]')"

mkdir -p "$folder"
jq -n \
  --arg id "$id" \
  --arg title "$name" \
  --arg author "$author" \
  --arg summary "$summary" \
  --arg version "$version" \
  --argjson categories "$categories_json" \
  --arg repo "$repo_url" \
  --arg github "$github_slug" \
  --arg api "$api" \
  --arg profile "$profile" \
  --arg game_version "$game_version" \
  --argjson permissions "$permissions" \
  '{
    id: $id,
    title: $title,
    author: $author,
    summary: $summary,
    version: $version,
    categories: $categories,
    repo: $repo,
    github: $github,
    api: ($api | tonumber),
    profile: $profile,
    permissions: $permissions,
    automatic_version_check: true
  }
  + (if $game_version != "" then { game_version: $game_version } else {} end)' \
  > "$folder/meta.json"

{
  printf '# %s\n\n' "$name"
  printf '%s\n' "$description"
} > "$folder/description.md"

# --- 6. rebuild the index
echo "==> rebuilding the index ..."
if [ -n "$base" ]; then
  node "$SCRIPT_DIR/build-index.mjs" --base "$base"
else
  node "$SCRIPT_DIR/build-index.mjs"
fi

# --- 7. summary
echo
echo "created $folder (meta.json + description.md)"
echo "  id: $id   version: $version   category: $mapped"
echo "index rebuilt: $REPO_ROOT/site/data/index.json"
echo "next: commit $folder and site/data/index.json, then push to publish"
