#!/usr/bin/env lua
-- validate-mod.lua
--
-- Validates one extracted Gen1Recomp mod against the REAL engine validation
-- code.  It loads the engine repo's src/mods/Manifest.lua (which pulls in
-- src/mods/Semver.lua, src/core/Logger.lua and src/core/Version.lua) and then
-- runs the same checks the engine loader runs:
--
--   1. the zip-structure rule from LauncherMods.locateRoot
--      (manifest.json at the archive root, or inside exactly one top-level
--      folder) -- reimplemented faithfully here because LauncherMods itself
--      drags in the love runtime;
--   2. Manifest.validate -- shape, vocabulary, api, profile, permissions,
--      game_version range grammar, github syntax;
--   3. the loader's filesystem checks (Loader:_validate): entry file exists,
--      options_schema/assets_transforms exist when declared;
--   4. Semver.satisfies(Version.engine, game_version) for the engine version.
--
-- Usage:
--   lua validate-mod.lua --zip-dir <extracted-zip-dir> \
--                        --manifest <path-to-manifest.json> \
--                        [--engine <semver>] [--engine-repo <path>]
--
-- Exit 0 and print "VALID <id> <name> <version>" plus a JSON facts block on
-- success; exit 1 and print "INVALID <id>: <reason>" (or "REJECTED: <reason>"
-- when no usable manifest id exists) on failure.

local DEFAULT_ENGINE_REPO = "/mnt/Datos/Opencode/Projects/Gen1RecompAndroid/gen1recomp"

-- ------- tiny JSON decoder (objects, arrays, strings, numbers, booleans, null)

local char = utf8 and utf8.char or function(cp)
  return cp < 256 and string.char(cp) or "?"
end

local function decodeJson(text)
  local pos, n = 1, #text
  local function skipws()
    while pos <= n do
      local c = text:sub(pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then
        pos = pos + 1
      else
        break
      end
    end
  end
  local function parse()
    skipws()
    if pos > n then error("unexpected end of JSON input", 0) end
    local c = text:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local obj = {}
      skipws()
      if text:sub(pos, pos) == "}" then pos = pos + 1 return obj end
      while true do
        skipws()
        local key = parse()
        assert(type(key) == "string", "object key must be a string")
        skipws()
        assert(text:sub(pos, pos) == ":", "expected ':'")
        pos = pos + 1
        obj[key] = parse()
        skipws()
        c = text:sub(pos, pos)
        if c == "," then
          pos = pos + 1
        elseif c == "}" then
          pos = pos + 1
          break
        else
          error("expected ',' or '}'", 0)
        end
      end
      return obj
    elseif c == "[" then
      pos = pos + 1
      local arr = {}
      skipws()
      if text:sub(pos, pos) == "]" then pos = pos + 1 return arr end
      while true do
        arr[#arr + 1] = parse()
        skipws()
        c = text:sub(pos, pos)
        if c == "," then
          pos = pos + 1
        elseif c == "]" then
          pos = pos + 1
          break
        else
          error("expected ',' or ']'", 0)
        end
      end
      return arr
    elseif c == '"' then
      pos = pos + 1
      local out = {}
      while pos <= n do
        local ch = text:sub(pos, pos)
        if ch == '"' then pos = pos + 1 break end
        if ch == "\\" then
          pos = pos + 1
          local e = text:sub(pos, pos)
          if e == '"' or e == "\\" or e == "/" then
            out[#out + 1] = e
            pos = pos + 1
          elseif e == "b" then out[#out + 1] = "\b"; pos = pos + 1
          elseif e == "f" then out[#out + 1] = "\f"; pos = pos + 1
          elseif e == "n" then out[#out + 1] = "\n"; pos = pos + 1
          elseif e == "r" then out[#out + 1] = "\r"; pos = pos + 1
          elseif e == "t" then out[#out + 1] = "\t"; pos = pos + 1
          elseif e == "u" then
            local hex = text:sub(pos + 1, pos + 4)
            assert(hex:match("^%x%x%x%x$"), "bad \\u escape")
            local cp = tonumber(hex, 16)
            pos = pos + 5
            if cp >= 0xD800 and cp <= 0xDBFF and text:sub(pos, pos + 1) == "\\u" then
              local hex2 = text:sub(pos + 2, pos + 5)
              local lo = hex2:match("^%x%x%x%x$") and tonumber(hex2, 16) or nil
              if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                pos = pos + 6
              end
            end
            out[#out + 1] = char(cp)
          else
            error("bad escape \\" .. e, 0)
          end
        else
          out[#out + 1] = ch
          pos = pos + 1
        end
      end
      return table.concat(out)
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    else
      -- capture-free number scan: an optional capture that cannot match is a
      -- hard failure in Lua patterns, so each piece is matched on its own
      local num = text:match("^%-?%d+", pos)
      if num then
        local np = pos + #num
        local frac = text:match("^%.%d+", np)
        if frac then
          num = num .. frac
          np = np + #frac
        end
        local exp = text:match("^[eE][%+%-]?%d+", np)
        if exp then num = num .. exp end
      end
      if num and tonumber(num) then
        pos = pos + #num
        return tonumber(num)
      end
      error("invalid JSON token", 0)
    end
  end
  local value = parse()
  skipws()
  assert(pos > n, "trailing JSON data")
  return value
end

-- ------- tiny helpers

local function readFile(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  return data
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function stripBom(text)
  if text:sub(1, 3) == "\239\187\191" then return text:sub(4) end
  return text
end

-- ------- locateRoot: faithful copy of the loader's zip-root rule
-- paths is a shallow listing: top-level file names as-is, plus "<dir>/manifest.json"
-- for each top-level directory that holds one.  Mirrors LauncherMods.locateRoot.
local function locateRoot(paths)
  for _, p in ipairs(paths) do
    if p == "manifest.json" then return "" end
  end
  local topDirs, seen, hasManifest = {}, {}, {}
  for _, p in ipairs(paths) do
    local top, rest = p:match("^([^/]+)/(.+)$")
    if top then
      if not seen[top] then
        seen[top] = true
        topDirs[#topDirs + 1] = top
      end
      if rest == "manifest.json" then hasManifest[top] = true end
    end
  end
  if #topDirs == 1 and hasManifest[topDirs[1]] then return topDirs[1] end
  if #topDirs > 1 then
    return nil, "the .zip must contain a single mod folder"
  end
  return nil, "no manifest.json found in the .zip"
end

-- Build the shallow top-level listing of an extracted zip dir, the same shape
-- the loader feeds to locateRoot: every top-level entry, plus
-- "<dir>/manifest.json" for top-level directories holding a manifest.
local function topLevelPaths(zipDir)
  local dir = zipDir:gsub("/+$", "")
  local paths = {}
  local handle = io.popen(('find %q -maxdepth 2 -mindepth 1 | sort'):format(dir))
  if handle then
    for line in handle:lines() do
      local rel = line:sub(#dir + 2)
      if rel ~= "" then paths[#paths + 1] = rel end
    end
    local ok = handle:close()
    if ok and #paths > 0 then return paths end
  end
  -- degraded fallback: only the root-manifest case is detected
  if exists(dir .. "/manifest.json") then return { "manifest.json" } end
  return {}
end

-- ------- output helpers

local function jstr(s)
  s = tostring(s)
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
  s = s:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  return '"' .. s .. '"'
end

local function emitFacts(m)
  local perms = {}
  for _, p in ipairs(m.permissions) do perms[#perms + 1] = jstr(p) end
  local rows = {
    jstr("id") .. ": " .. jstr(m.id),
    jstr("name") .. ": " .. jstr(m.name),
    jstr("version") .. ": " .. jstr(m.version),
    jstr("api") .. ": " .. tostring(m.api),
    jstr("profile") .. ": " .. jstr(m.profile),
    jstr("category") .. ": " .. jstr(m.category),
    jstr("description") .. ": " .. jstr(m.description),
    jstr("entry") .. ": " .. jstr(m.entry),
    jstr("game_version") .. ": " .. (m.game_version and jstr(m.game_version) or "null"),
    jstr("github") .. ": " .. (m.github and jstr(m.github) or "null"),
    jstr("experimental") .. ": " .. tostring(m.experimental),
    jstr("language") .. ": " .. tostring(m.language),
    jstr("affects_link") .. ": " .. tostring(m.affects_link),
    jstr("permissions") .. ": [" .. table.concat(perms, ", ") .. "]",
  }
  io.write("{\n  " .. table.concat(rows, ",\n  ") .. "\n}\n")
end

-- ------- argument parsing

local usage = [[
Usage: validate-mod.lua --zip-dir <extracted-zip-dir> --manifest <manifest.json>
                        [--engine <semver>] [--engine-repo <path>]

  --zip-dir <dir>       directory the mod zip was extracted into
  --manifest <path>     path to manifest.json inside the extracted zip
  --engine <semver>     override Version.engine for the game_version range check
                        (the engine working tree reports 0.0.0-dev)
  --engine-repo <path>  engine repo whose src/mods/Manifest.lua is used
                        (default: $GEN1RECOMP_ENGINE_REPO or
                        /mnt/Datos/Opencode/Projects/Gen1RecompAndroid/gen1recomp)

Exit 0 + "VALID <id> <name> <version>" and a JSON facts block on success;
exit 1 + "INVALID <id>: <reason>" (or "REJECTED: <reason>") on failure.
]]

local args = { engineRepo = os.getenv("GEN1RECOMP_ENGINE_REPO") or DEFAULT_ENGINE_REPO }
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "--engine-repo" then
    args.engineRepo = arg[i + 1]
    if not args.engineRepo then error("--engine-repo needs a value") end
    i = i + 1
  elseif a == "--engine" then
    args.engine = arg[i + 1]
    if not args.engine then error("--engine needs a value") end
    i = i + 1
  elseif a == "--zip-dir" then
    args.zipDir = arg[i + 1]
    if not args.zipDir then error("--zip-dir needs a value") end
    i = i + 1
  elseif a == "--manifest" then
    args.manifest = arg[i + 1]
    if not args.manifest then error("--manifest needs a value") end
    i = i + 1
  elseif a == "--help" or a == "-h" then
    print(usage)
    os.exit(0)
  else
    print("unknown argument: " .. tostring(a))
    print(usage)
    os.exit(2)
  end
  i = i + 1
end

if not args.zipDir then
  print("missing --zip-dir")
  print(usage)
  os.exit(2)
end
if not args.manifest then
  print("missing --manifest")
  print(usage)
  os.exit(2)
end

-- ------- load the REAL engine validation code

package.path = args.engineRepo .. "/?.lua;" .. package.path

local loaded, Manifest = pcall(require, "src.mods.Manifest")
if not loaded then
  print("REJECTED: cannot load engine manifest validator from " .. args.engineRepo
    .. " (" .. tostring(Manifest) .. ")")
  os.exit(1)
end
local Semver = require("src.mods.Semver")
local Version = require("src.core.Version")

-- ------- read + decode the manifest (REJECTED-level failures)

local rawText, err = readFile(args.manifest)
if not rawText then
  print("REJECTED: manifest.json unreadable: " .. tostring(err))
  os.exit(1)
end
local okDecode, decoded = pcall(decodeJson, stripBom(rawText))
if not okDecode then
  local msg = tostring(decoded):gsub("^[^:]+:%d+: ", "")
  print("REJECTED: malformed manifest JSON: " .. msg)
  os.exit(1)
end
if type(decoded) ~= "table" then
  print("REJECTED: manifest must be a JSON object")
  os.exit(1)
end

-- ------- zip-structure rule first, like the loader's mount path

local root, rootReason = locateRoot(topLevelPaths(args.zipDir))
if not root then
  print("REJECTED: " .. tostring(rootReason))
  os.exit(1)
end

-- ------- engine-version override for the semver range check

local savedEngine
if args.engine then
  savedEngine = Version.engine
  Version.engine = args.engine
end

-- ------- the loader's checks: Manifest.validate + filesystem + engine version

local function validateAndGet()
  local m = Manifest.validate(decoded, args.manifest)

  local prefix = root == "" and args.zipDir or (args.zipDir .. "/" .. root)
  if not exists(prefix .. "/" .. m.entry) then
    error("entry file missing: " .. m.entry, 0)
  end
  if m.options_schema and not exists(prefix .. "/" .. m.options_schema) then
    error("options_schema file missing: " .. m.options_schema, 0)
  end
  if m.assets_transforms and not exists(prefix .. "/" .. m.assets_transforms) then
    error("assets_transforms file missing: " .. m.assets_transforms, 0)
  end
  if m.game_version then
    local okv, errv = Semver.satisfies(Version.engine, m.game_version)
    if not okv then
      local r = ("needs game version %s, engine is %s"):format(m.game_version, Version.engine)
      if errv then r = r .. " (" .. errv .. ")" end
      error(r, 0)
    end
  end
  return m
end

local ok, result = pcall(validateAndGet)
if savedEngine then Version.engine = savedEngine end

if not ok then
  local msg = tostring(result):gsub("^[^:]+:%d+: ", "")
  local id = (type(decoded.id) == "string" and decoded.id:match("^[%w_%-]+$")) and decoded.id or nil
  if id then
    print("INVALID " .. id .. ": " .. msg)
  else
    print("REJECTED: " .. msg)
  end
  os.exit(1)
end

print(("VALID %s %s %s"):format(result.id, result.name, result.version))
emitFacts(result)
os.exit(0)
