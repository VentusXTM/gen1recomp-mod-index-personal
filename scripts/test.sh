#!/usr/bin/env bash
#
# test.sh — smoke tests for the personal mod index tooling.
#
#   bash scripts/test.sh
#
# Test 1 needs the network and a working `gh` login; tests 2-4 are offline
# except for the one official-feed fetch test 3 does.  Every test prints PASS
# or FAIL; the script exits non-zero if any test fails.
#
# Environment:
#   LUA_BIN   Lua interpreter (default: lua / lua5.4 / luajit on PATH)
#   GEN1RECOMP_ENGINE_REPO   engine repo path (default: sibling ../gen1recomp)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ENGINE_REPO="${GEN1RECOMP_ENGINE_REPO:-$(cd "$SCRIPT_DIR/../../gen1recomp" 2>/dev/null && pwd)}"
if [ -z "$ENGINE_REPO" ] || [ ! -f "$ENGINE_REPO/src/mods/Manifest.lua" ]; then
  echo "FAIL: engine repo not found (set GEN1RECOMP_ENGINE_REPO)"
  exit 1
fi
export GEN1RECOMP_ENGINE_REPO="$ENGINE_REPO"

LUA_BIN="${LUA_BIN:-$(command -v lua || command -v lua5.4 || command -v lua5.3 || command -v lua5.1 || command -v luajit || true)}"
if [ -z "$LUA_BIN" ]; then
  echo "FAIL: no lua interpreter on PATH (set LUA_BIN)"
  exit 1
fi
export LUA_BIN

pass=0
fail=0
check() { # check <name> <result>
  if [ "$2" = "PASS" ]; then
    pass=$((pass + 1))
    echo "PASS: $1"
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
  fi
}

# --- 1. valid mod end-to-end against the REAL engine validation
out="$("$SCRIPT_DIR/validate-mod.sh" 1iminal/gen1recomp-no-exp-challenge 2>&1)"
if grep -qE '^VALID ' <<<"$out"; then
  check "valid mod e2e (1iminal/gen1recomp-no-exp-challenge)" PASS
else
  printf '%s\n' "$out"
  check "valid mod e2e (1iminal/gen1recomp-no-exp-challenge)" FAIL
fi

# --- 2. invalid/valid cases via validate-mod.lua on fake extracted dirs
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 2a. manifest missing `entry`
mkdir -p "$TMP/broken"
cat > "$TMP/broken/manifest.json" <<'EOF'
{"id":"broken_mod","name":"Broken Mod","version":"1.0.0"}
EOF
out="$("$LUA_BIN" "$SCRIPT_DIR/validate-mod.lua" --zip-dir "$TMP/broken" --manifest "$TMP/broken/manifest.json" 2>&1)"
line="$(grep -E '^(INVALID|REJECTED)' <<<"$out" || true)"
if [ -n "$line" ]; then
  check "invalid mod: missing entry -> $line" PASS
else
  printf '%s\n' "$out"
  check "invalid mod: missing entry" FAIL
fi

# 2b. game_version not satisfied by the engine
mkdir -p "$TMP/gv"
cat > "$TMP/gv/manifest.json" <<'EOF'
{"id":"gv_mod","name":"GV Mod","version":"1.0.0","entry":"main.lua","game_version":">=0.6.0"}
EOF
printf -- '-- placeholder\n' > "$TMP/gv/main.lua"
out="$("$LUA_BIN" "$SCRIPT_DIR/validate-mod.lua" --zip-dir "$TMP/gv" --manifest "$TMP/gv/manifest.json" --engine 0.5.0 2>&1)"
line="$(grep '^INVALID' <<<"$out" || true)"
if [ -n "$line" ]; then
  check "invalid mod: game_version unmet -> $line" PASS
else
  printf '%s\n' "$out"
  check "invalid mod: game_version unmet" FAIL
fi

# 2c. same mod is valid once the engine version satisfies the range
out="$("$LUA_BIN" "$SCRIPT_DIR/validate-mod.lua" --zip-dir "$TMP/gv" --manifest "$TMP/gv/manifest.json" --engine 1.0.0 2>&1)"
if grep -qE '^VALID gv_mod' <<<"$out"; then
  check "valid mod: game_version satisfied via --engine 1.0.0" PASS
else
  printf '%s\n' "$out"
  check "valid mod: game_version satisfied via --engine 1.0.0" FAIL
fi

# --- 3. sync the official mirror
out="$(node "$SCRIPT_DIR/sync-official.mjs" 2>&1)"
count="$(node -e "try{const d=require('./.cache/official.json'); console.log(d.mods.length)}catch(e){console.log('ERR')}" 2>/dev/null)"
if [ "$count" != "ERR" ] && [ "${count:-0}" -ge 80 ] 2>/dev/null; then
  check "sync official mirror ($count mods)" PASS
else
  printf '%s\n' "$out"
  check "sync official mirror" FAIL
fi

# --- 4. build the merged index
out="$(node "$SCRIPT_DIR/build-index.mjs" 2>&1)"
result="$(node -e "
  const d = require('./site/data/index.json');
  const personal = d.mods.filter(m => m.source === 'personal').length;
  console.log('count=' + d.count + ', mods=' + d.mods.length + ', personal=' + personal);
" 2>&1)"
if node -e "
  const d = require('./site/data/index.json');
  process.exit(
    d.count === d.mods.length &&
    d.schema_version === 1 &&
    d.mods.some(m => m.source === 'personal') ? 0 : 1
  );
" 2>/dev/null; then
  check "build merged index ($result)" PASS
else
  printf '%s\n' "$out"
  printf '%s\n' "$result"
  check "build merged index" FAIL
fi

echo
echo "summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
