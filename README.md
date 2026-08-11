# gen1recomp-mod-index-personal

A personal index of Gen1Recomp mods. It mirrors the official community index
([bryanthaboi/gen1recomp-mod-index](https://github.com/bryanthaboi/gen1recomp-mod-index))
and adds personal mod listings. Every listed mod is validated with the **real
engine validation code** — `src/mods/Manifest.lua`, `src/mods/Semver.lua` and
`src/core/Version.lua` from the Gen1Recomp engine repo — so a mod reaches the
index only when the launcher would accept it.

## Layout

```
gen1recomp-mod-index-personal/
  README.md
  schema/mod.schema.json          JSON schema for one mod meta.json (copied from the official index)
  examples/YourName@example_mod/  Official example entry, copied verbatim
  mods/                           Personal mods, one mods/<Author>@<id>/ folder each
  site/data/index.json            Generated merged index (build-index output)
  .cache/official.json            Generated mirror of the official feed
  scripts/
    validate-mod.sh               GitHub URL -> latest release zip -> validate-mod.lua
    validate-mod.lua              Core: validates one mod against the REAL engine code
    sync-official.mjs             Fetches and mirrors the official feed
    build-index.mjs               Merges mirror + personal mods into site/data/index.json
    test.sh                       Smoke tests
```

## How validation works

`validate-mod.lua` loads the engine's `src/mods/Manifest.lua` (which pulls in
`Semver.lua`, `Logger.lua` and `Version.lua`) straight from the engine repo,
then runs the same checks the loader runs:

1. The zip-structure rule from `LauncherMods.locateRoot`: `manifest.json` at
   the archive root, or inside exactly one top-level folder.
2. `Manifest.validate`: shape, vocabulary, api level, profile, permissions,
   game_version range grammar, github syntax.
3. The loader's filesystem checks (`Loader:_validate`): the entry file exists,
   and `options_schema` / `assets_transforms` exist when declared.
4. `Semver.satisfies(Version.engine, game_version)`.

The engine working tree reports `0.0.0-dev`, so real releases must pass
`--engine <semver>` to the validator (or you accept that any non-empty
`game_version` range fails).

## Commands

```sh
# Validate a mod from its GitHub repo (resolves the latest release zip)
./scripts/validate-mod.sh 1iminal/gen1recomp-no-exp-challenge
./scripts/validate-mod.sh https://github.com/owner/repo --engine 0.9.0

# Validate a mod, then create its listing (mods/<author>@<id>/ + index rebuild)
./scripts/add-mod.sh 1iminal/gen1recomp-no-exp-challenge
./scripts/add-mod.sh https://github.com/owner/repo --engine 0.9.0 --base https://YOU.github.io/REPO/

# Mirror the official feed (writes .cache/official.json)
node scripts/sync-official.mjs

# Build the merged index (writes site/data/index.json)
node scripts/build-index.mjs
node scripts/build-index.mjs --base https://YOU.github.io/REPO/

# Smoke tests
bash scripts/test.sh
```

### Adding a personal mod

`add-mod.sh` automates the whole flow from a GitHub link: it runs
`validate-mod.sh` first and aborts (creating nothing) if the mod is not
accepted by the real engine validation, then writes
`mods/<author>@<id>/meta.json` + `description.md` (author from the repo
owner, manifest category mapped to the index enum, schema-compliant fields)
and rebuilds the index. It refuses to overwrite an existing folder.

To add a mod manually instead:

1. Create `mods/<Author>@<id>/` (the folder name becomes the entry's `folder`).
2. Add `meta.json` following the official schema (`schema/mod.schema.json`;
   required: `id`, `title`, `author`, `version`, `categories` 1–4, `repo`).
   See `examples/YourName@example_mod/` for the reference entry.
3. Optionally add `description.md` and `thumbnail.png` — they become the
   entry's `description_url` and `thumbnail` in the built index.
4. Run `node scripts/build-index.mjs`. A personal entry whose `id` collides
   with the mirror wins (a warning is printed).

The `examples/YourName@example_mod/` folder is a reference entry — copy its
shape, never keep it as a real listing.

### Base URL placeholder

`build-index.mjs` rewrites relative `thumbnail` / `description_url` paths
against the index base. The default is the placeholder
`https://USER.github.io/gen1recomp-mod-index-personal/` — pass `--base <url>`
(or edit the default in the script) and replace the placeholder when the repo
is published.

## Requirements

- Node 20+ (plain Node — no npm packages), `node` on PATH.
- Lua interpreter (`lua`, `lua5.4`, `lua5.3`, `luajit`) or set `LUA_BIN`.
- `validate-mod.sh` additionally needs `gh`, `jq`, `curl`, `unzip`, and
  `gh` must be authenticated.
- `GEN1RECOMP_ENGINE_REPO` overrides the engine repo path that
  `validate-mod.lua` uses (default: `/mnt/Datos/Opencode/Projects/Gen1RecompAndroid/gen1recomp`).

## Credits

The schema, example entry and feed structure mirror the official
[gen1recomp-mod-index](https://github.com/bryanthaboi/gen1recomp-mod-index).
Validation reuses the real engine code from the
[gen1recomp](https://github.com/bryanthaboi/gen1recomp) repository.
