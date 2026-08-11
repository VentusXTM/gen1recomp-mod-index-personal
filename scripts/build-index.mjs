#!/usr/bin/env node
//
// build-index.mjs — merge the official mirror with personal mods.
//
//   node scripts/build-index.mjs [--base <url>] [--releases]
//
// Reads .cache/official.json (written by sync-official.mjs) and scans
// mods/*/meta.json (one folder per personal mod, named <Author>@<id>, each
// meta.json following the official schema).  Only mirror ids listed in
// allowlist.json enter the feed; every other mirrored mod stays in
// stash/mods.json, outside docs/, so gen1recomp never indexes it.  Personal
// entries win on id collision with the mirror.  Relative
// thumbnail/description_url values are rewritten to absolute URLs against
// the personal index base.  Writes docs/data/index.json with a regenerated
// count and generated_at.
//
// --base defaults to this repo's GitHub Pages URL (published from /docs);
// override with --base <url> when the repo moves.
//
// --releases resolves the latest GitHub release for every personal entry
// that has a `github` slug and automatic_version_check enabled, filling the
// same `latest` + `update_check` fields the official index nightly fills, so
// cards in the launcher resolve an installable zip.  Without it, personal
// entries with an unknown release stay uninstallable ("nothing installable
// listed") because installUrl requires update_check == "ok".

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { dirname } from "node:path";

const DEFAULT_BASE = "https://ventusxtm.github.io/gen1recomp-mod-index-personal/";
const MAX_CATEGORIES = 4;

const args = process.argv.slice(2);
let base = DEFAULT_BASE;
let resolveReleases = false;
let outPath = "docs/data/index.json";
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--releases") {
    resolveReleases = true;
    continue;
  }
  if (args[i] === "--out") {
    outPath = args[i + 1];
    if (outPath == null) {
      console.error("build-index: --out needs a value");
      process.exit(1);
    }
    i++;
    continue;
  }
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

// resolveLatest(slug) -> { latest, update_check } | { update_check }
//
// Mirrors the official index's update-check shape.  A 404 or empty release
// list means the author never published an installable release; any other
// failure is reported as a string update_check the launcher shows verbatim.
async function resolveLatest(slug) {
  try {
    const res = await fetch(
      `https://api.github.com/repos/${slug}/releases/latest`,
      { headers: { Accept: "application/vnd.github+json", "User-Agent": "gen1recomp-mod-index-personal" } }
    );
    if (res.status === 404) {
      return { update_check: "no installable release" };
    }
    if (!res.ok) {
      return { update_check: `error HTTP ${res.status}` };
    }
    const release = await res.json();
    const zip = (release.assets || []).find((a) => String(a.name).endsWith(".zip"));
    if (!zip) {
      return { update_check: "no installable release" };
    }
    return {
      latest: {
        version: release.tag_name,
        tag: release.tag_name,
        name: release.name || release.tag_name,
        prerelease: !!release.prerelease,
        published_at: release.published_at || null,
        zip: {
          name: zip.name,
          url: zip.browser_download_url,
          size: zip.size ?? null,
        },
      },
      update_check: "ok",
    };
  } catch (e) {
    return { update_check: `error ${e.message}` };
  }
}

// official mirror — only allowlisted ids enter the served feed; the rest
// stay stashed in stash/mods.json (outside docs/), ready to be re-enabled
// one by one by adding their id to allowlist.json.
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

let allowlist = { mirror_ids: [] };
try {
  allowlist = JSON.parse(readFileSync("allowlist.json", "utf8"));
} catch {
  console.error("build-index: cannot read allowlist.json");
  process.exit(1);
}
const allowed = new Set(
  Array.isArray(allowlist.mirror_ids) ? allowlist.mirror_ids : []
);
const officialMods = official.mods.filter((m) => allowed.has(m.id));

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
for (const m of officialMods) byId.set(m.id, m);
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

async function main() {
  if (resolveReleases) {
    for (const e of personal) {
      if (!e.automatic_version_check || typeof e.github !== "string") continue;
      const slug = e.github.replace(/^https?:\/\/github\.com\//, "").replace(/\/$/, "");
      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(slug)) {
        console.warn(`build-index: skipping release check for ${e.folder}: bad github slug "${e.github}"`);
        continue;
      }
      const r = await resolveLatest(slug);
      if (r.latest) {
        e.latest = r.latest;
        e.update_check = r.update_check;
        console.log(
          `build-index: ${e.folder}: release ${r.latest.version} (${r.latest.zip.name}, ${r.latest.zip.size ?? "?"} bytes)`
        );
      } else {
        e.update_check = r.update_check;
        console.log(`build-index: ${e.folder}: ${r.update_check}`);
      }
    }
  }

  const out = {
    schema_version: 1,
    generated_at: new Date().toISOString(),
    count: mods.length,
    categories: Array.isArray(official.categories) ? official.categories : [],
    mods,
  };

  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
  console.log(
    `build-index: ${mods.length} mods (${personal.length} personal, ${officialMods.length} allowlisted mirror) -> ${outPath}`
  );
}

main().catch((e) => {
  console.error(`build-index: ${e.message}`);
  process.exit(1);
});
