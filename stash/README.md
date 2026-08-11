# Stash — full official mirror (not served)

This directory holds the **complete** mirror of the official gen1recomp
mod index (`stash/mods.json`), kept outside `docs/` so GitHub Pages never
serves it and gen1recomp cannot index it. It is written by
`scripts/sync-official.mjs` on every sync.

Only the ids listed in `allowlist.json` are included in the public feed
(`docs/data/index.json`). Everything else lives here.

## Making a stashed mod discoverable again

1. Find the mod id in `stash/mods.json` (or `node -e "const d=require('./stash/mods.json'); d.mods.forEach(m=>console.log(m.id,'|',m.title))"`).
2. Add its id to the `mirror_ids` array in `allowlist.json`.
3. Rebuild and test:
   `node scripts/build-index.mjs --releases && bash scripts/test.sh`
4. Commit `allowlist.json` and `docs/data/index.json`, then push — the
   mod appears in the launcher's next refresh. One at a time, so the list
   stays fast.

Removing an id from `allowlist.json` takes the mod out of the feed again;
the full entry remains in `stash/mods.json`.
