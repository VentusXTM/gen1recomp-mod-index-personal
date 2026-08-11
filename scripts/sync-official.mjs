#!/usr/bin/env node
//
// sync-official.mjs — mirror the official gen1recomp-mod-index feed.
//
//   node scripts/sync-official.mjs
//
// Fetches the official community index, rewrites every entry's relative
// thumbnail and description_url into absolute URLs against the official
// GitHub Pages site, tags each entry with "source": "official-mirror", and
// records mirror_of / mirrored_at at the top level.  Everything else is
// preserved verbatim.
//
// Writes .cache/official.json (build input) and stash/mods.json (the full
// mirror kept OUTSIDE docs/, so gen1recomp never indexes it).  Only the ids
// in allowlist.json are served in the public feed; the rest stay stashed and
// can be made discoverable one by one.

import { mkdirSync, writeFileSync } from "node:fs";

const FEED =
  "https://raw.githubusercontent.com/bryanthaboi/gen1recomp-mod-index/main/site/data/index.json";
const BASE = "https://bryanthaboi.github.io/gen1recomp-mod-index/";

function absoluteUrl(p) {
  if (typeof p === "string" && p.length > 0 && !p.startsWith("http")) {
    return new URL(p, BASE).toString();
  }
  return p;
}

const res = await fetch(FEED);
if (!res.ok) {
  console.error(`sync-official: fetch failed: ${res.status} ${res.statusText}`);
  process.exit(1);
}
const data = await res.json();
if (!data || !Array.isArray(data.mods)) {
  console.error("sync-official: feed has no mods array");
  process.exit(1);
}

const mods = data.mods.map((m) => ({
  ...m,
  ...(m.thumbnail != null ? { thumbnail: absoluteUrl(m.thumbnail) } : {}),
  ...(m.description_url != null ? { description_url: absoluteUrl(m.description_url) } : {}),
  source: "official-mirror",
}));

const out = {
  ...data,
  mods,
  mirror_of: FEED,
  mirrored_at: new Date().toISOString(),
};

mkdirSync(".cache", { recursive: true });
writeFileSync(".cache/official.json", JSON.stringify(out, null, 2) + "\n");

// Full mirror stash, outside docs/ so it is never served/indexable.
mkdirSync("stash", { recursive: true });
writeFileSync("stash/mods.json", JSON.stringify(out, null, 2) + "\n");

console.log(`sync-official: mirrored ${mods.length} mods -> .cache/official.json + stash/mods.json`);
