const fs = require("node:fs");
const path = require("node:path");

function sidecarDir(vaultRoot) {
  return path.join(vaultRoot, ".openwith");
}

function sidecarPath(vaultRoot, hash) {
  return path.join(sidecarDir(vaultRoot), `${hash}.json`);
}

function listSidecarHashes(vaultRoot) {
  const dir = sidecarDir(vaultRoot);
  if (!fs.existsSync(dir)) return [];
  try {
    return fs.readdirSync(dir)
      .filter((name) => name.endsWith(".json"))
      .map((name) => name.slice(0, -5))
      .filter(isValidHash);
  } catch {
    return [];
  }
}

function isValidHash(hash) {
  return /^[0-9a-f]{12}$/.test(hash);
}

function readSidecar(vaultRoot, hash) {
  const file = sidecarPath(vaultRoot, hash);
  if (!fs.existsSync(file)) return null;
  try {
    const value = JSON.parse(fs.readFileSync(file, "utf8"));
    if (typeof value.source !== "string") return null;
    return value;
  } catch {
    return null;
  }
}

function hasBrokenSymlink(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir);
  } catch {
    return false;
  }
  for (const entry of entries) {
    const fullPath = path.join(dir, entry);
    try {
      if (fs.lstatSync(fullPath).isSymbolicLink()) {
        const link = fs.readlinkSync(fullPath);
        const target = path.isAbsolute(link)
          ? link
          : path.resolve(dir, link);
        if (!fs.existsSync(target)) return true;
      }
    } catch {
      // The entry may disappear while Obsidian is indexing it.
    }
  }
  return false;
}

/**
 * Return only entries that are provably stale.
 *
 * A valid, closed entry is intentionally retained. Finder can create the
 * sidecar before Obsidian has consumed the delayed obsidian://open request.
 */
function findOrphans(
  vaultRoot,
  openHashes,
  cleanBrokenSymlinks,
  { closedEntryGraceMs = 0, nowMs = Date.now() } = {},
) {
  const orphans = [];
  for (const hash of listSidecarHashes(vaultRoot)) {
    if (openHashes.has(hash)) continue;

    const dir = path.join(vaultRoot, hash);
    if (!fs.existsSync(dir)) {
      orphans.push(hash);
      continue;
    }

    try {
      if (!fs.statSync(dir).isDirectory()) {
        orphans.push(hash);
        continue;
      }
    } catch {
      continue;
    }

    const metadata = readSidecar(vaultRoot, hash);
    if (metadata === null) {
      orphans.push(hash);
      continue;
    }

    if (
      closedEntryGraceMs > 0 &&
      Number.isInteger(metadata.openedAt) &&
      nowMs - metadata.openedAt * 1000 >= closedEntryGraceMs
    ) {
      orphans.push(hash);
      continue;
    }

    if (cleanBrokenSymlinks) {
      if (hasBrokenSymlink(dir)) {
        orphans.push(hash);
      }
    }
  }
  return orphans;
}

module.exports = {
  findOrphans,
  listSidecarHashes,
  readSidecar,
  sidecarPath,
};
