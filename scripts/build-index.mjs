#!/usr/bin/env node
//
// build-index.mjs — merge the official mirror with personal mods.
//
//   node scripts/build-index.mjs [--base <url>]
//
// Reads .cache/official.json (written by sync-official.mjs) and scans
// mods/*/meta.json (one folder per personal mod, named <Author>@<id>, each
// meta.json following the official schema).  Personal entries win on id
// collision with the mirror.  Relative thumbnail/description_url values are
// rewritten to absolute URLs against the personal index base.  Writes
// site/data/index.json with a regenerated count and generated_at.
//
// --base defaults to the placeholder https://USER.github.io/gen1recomp-mod-index-personal/
// and must be replaced with the real GitHub Pages URL when the repo is
// published (see README).

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";

const DEFAULT_BASE = "https://USER.github.io/gen1recomp-mod-index-personal/";
const MAX_CATEGORIES = 4;

const args = process.argv.slice(2);
let base = DEFAULT_BASE;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--base") {
    base = args[i + 1];
    if (base == null) {
      console.error("build-index: --base needs a value");
      process.exit(1);
    }
    i++;
  } else {
    console.error(`build-index: unknown argument: ${args[i]}`);
    process.exit(1);
  }
}
if (!base.endsWith("/")) base += "/";

function absoluteUrl(p) {
  if (typeof p === "string" && p.length > 0 && !p.startsWith("http")) {
    return new URL(p, base).toString();
  }
  return p;
}

function fail(folder, msg) {
  console.error(`build-index: invalid personal entry ${folder}: ${msg}`);
  process.exit(1);
}

function validatePersonal(folder, meta) {
  if (typeof meta.id !== "string" || meta.id.length === 0) fail(folder, "id is required");
  if (typeof meta.title !== "string" || meta.title.length === 0) fail(folder, "title is required");
  if (typeof meta.author !== "string" || meta.author.length === 0) fail(folder, "author is required");
  if (typeof meta.version !== "string" || meta.version.length === 0) fail(folder, "version is required");
  if (!Array.isArray(meta.categories)) fail(folder, "categories must be an array");
  if (meta.categories.length < 1 || meta.categories.length > MAX_CATEGORIES) {
    fail(folder, `categories must have 1-${MAX_CATEGORIES} entries`);
  }
  for (const c of meta.categories) {
    if (typeof c !== "string" || c.length === 0) {
      fail(folder, "categories entries must be non-empty strings");
    }
  }
  if (typeof meta.repo !== "string" || meta.repo.length === 0) fail(folder, "repo is required");
}

// official mirror
let official;
try {
  official = JSON.parse(readFileSync(".cache/official.json", "utf8"));
} catch {
  console.error(
    "build-index: cannot read .cache/official.json — run scripts/sync-official.mjs first"
  );
  process.exit(1);
}
if (!Array.isArray(official.mods)) {
  console.error("build-index: .cache/official.json has no mods array");
  process.exit(1);
}

// personal entries: one mods/<Author>@<id>/ folder each
const personal = [];
if (existsSync("mods")) {
  for (const folder of readdirSync("mods")) {
    const dir = path.join("mods", folder);
    const metaPath = path.join(dir, "meta.json");
    if (!existsSync(metaPath)) continue;
    let meta;
    try {
      meta = JSON.parse(readFileSync(metaPath, "utf8"));
    } catch (e) {
      fail(folder, `meta.json is not valid JSON (${e.message})`);
    }
    validatePersonal(folder, meta);
    const entry = { ...meta, folder, source: "personal" };
    if (existsSync(path.join(dir, "description.md"))) {
      entry.description_url = absoluteUrl(`data/mods/${folder}/description.md`);
    }
    if (existsSync(path.join(dir, "thumbnail.png"))) {
      entry.thumbnail = absoluteUrl(`data/mods/${folder}/thumbnail.png`);
    }
    personal.push(entry);
  }
}

// merge: personal wins on id collision with the mirror
const byId = new Map();
for (const m of official.mods) byId.set(m.id, m);
for (const e of personal) {
  if (byId.has(e.id)) {
    const other = byId.get(e.id);
    console.warn(
      `build-index: warning: personal ${e.folder} overrides official ${other.folder} (id ${e.id})`
    );
  }
  byId.set(e.id, e);
}
const mods = [...byId.values()].sort((a, b) =>
  String(a.folder).localeCompare(String(b.folder))
);

const out = {
  schema_version: 1,
  generated_at: new Date().toISOString(),
  count: mods.length,
  categories: Array.isArray(official.categories) ? official.categories : [],
  mods,
};

mkdirSync("site/data", { recursive: true });
writeFileSync("site/data/index.json", JSON.stringify(out, null, 2) + "\n");
console.log(
  `build-index: ${mods.length} mods (${personal.length} personal) -> site/data/index.json`
);
