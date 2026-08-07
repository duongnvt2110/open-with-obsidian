const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const { findOrphans } = require("../src/reconcile");
const { cleanupEntry } = require("../src/cleanup");

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "scratch-cleanup-"));
  fs.mkdirSync(path.join(root, ".openwith"));
  return root;
}

function sidecar(root, hash, source = "/tmp/note.md") {
  fs.writeFileSync(
    path.join(root, ".openwith", `${hash}.json`),
    JSON.stringify({ source, openedAt: Date.now() }),
  );
}

test("preserves a valid closed entry for delayed Finder opens", () => {
  const root = fixture();
  const realFile = path.join(root, "source.md");
  fs.writeFileSync(realFile, "note");
  fs.mkdirSync(path.join(root, "0123456789ab"));
  fs.symlinkSync(realFile, path.join(root, "0123456789ab", "note.md"));
  sidecar(root, "0123456789ab", realFile);

  assert.deepEqual(findOrphans(root, new Set(), true), []);
  fs.rmSync(root, { recursive: true, force: true });
});

test("removes a valid closed entry after the grace period", () => {
  const root = fixture();
  const hash = "0123456789ab";
  const openedAt = 1_700_000_000;
  fs.mkdirSync(path.join(root, hash));
  sidecar(root, hash);
  fs.writeFileSync(
    path.join(root, ".openwith", `${hash}.json`),
    JSON.stringify({ source: "/tmp/note.md", openedAt }),
  );

  assert.deepEqual(
    findOrphans(root, new Set(), true, {
      closedEntryGraceMs: 5000,
      nowMs: openedAt * 1000 + 5000,
    }),
    [hash],
  );
  fs.rmSync(root, { recursive: true, force: true });
});

test("keeps a recently closed valid entry during the grace period", () => {
  const root = fixture();
  const hash = "0123456789ab";
  const openedAt = 1_700_000_000;
  fs.mkdirSync(path.join(root, hash));
  fs.writeFileSync(
    path.join(root, ".openwith", `${hash}.json`),
    JSON.stringify({ source: "/tmp/note.md", openedAt }),
  );

  assert.deepEqual(
    findOrphans(root, new Set(), true, {
      closedEntryGraceMs: 5000,
      nowMs: openedAt * 1000 + 4999,
    }),
    [],
  );
  fs.rmSync(root, { recursive: true, force: true });
});

test("resolves relative symlink targets from the scratch entry directory", () => {
  const root = fixture();
  const hash = "0123456789ab";
  fs.mkdirSync(path.join(root, hash));
  fs.writeFileSync(path.join(root, hash, "source.md"), "note");
  fs.symlinkSync("source.md", path.join(root, hash, "note.md"));
  sidecar(root, hash, path.join(root, hash, "source.md"));

  assert.deepEqual(findOrphans(root, new Set(), true), []);
  fs.rmSync(root, { recursive: true, force: true });
});

test("removes a missing scratch directory", () => {
  const root = fixture();
  sidecar(root, "0123456789ab");
  assert.deepEqual(findOrphans(root, new Set(), true), ["0123456789ab"]);
  fs.rmSync(root, { recursive: true, force: true });
});

test("removes a broken link only when broken-link cleanup is enabled", () => {
  const root = fixture();
  const hash = "0123456789ab";
  fs.mkdirSync(path.join(root, hash));
  fs.symlinkSync("/does/not/exist", path.join(root, hash, "note.md"));
  sidecar(root, hash, "/does/not/exist");

  assert.deepEqual(findOrphans(root, new Set(), false), []);
  assert.deepEqual(findOrphans(root, new Set(), true), [hash]);
  fs.rmSync(root, { recursive: true, force: true });
});

test("ignores sidecars whose filenames are not valid hashes", () => {
  const root = fixture();
  fs.writeFileSync(path.join(root, ".openwith", ".json"), "not-json");

  assert.deepEqual(findOrphans(root, new Set(), true), []);
  fs.rmSync(root, { recursive: true, force: true });
});

test("detects a broken symlink even when a valid symlink appears first", () => {
  const root = fixture();
  const hash = "0123456789ab";
  const entry = path.join(root, hash);
  fs.mkdirSync(entry);
  const realFile = path.join(entry, "source.md");
  fs.writeFileSync(realFile, "note");
  fs.symlinkSync(realFile, path.join(entry, "a-valid.md"));
  fs.symlinkSync("/does/not/exist", path.join(entry, "z-broken.md"));
  sidecar(root, hash, realFile);

  assert.deepEqual(findOrphans(root, new Set(), true), [hash]);
  fs.rmSync(root, { recursive: true, force: true });
});

test("refuses to delete the vault for an invalid cleanup hash", () => {
  const root = fixture();
  fs.writeFileSync(path.join(root, "keep.txt"), "keep");

  assert.equal(cleanupEntry(root, ""), false);
  assert.equal(fs.existsSync(path.join(root, "keep.txt")), true);
  fs.rmSync(root, { recursive: true, force: true });
});

test("fails closed when the sidecar container is not a directory", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "scratch-cleanup-"));
  fs.writeFileSync(path.join(root, ".openwith"), "not-a-directory");

  assert.deepEqual(findOrphans(root, new Set(), true), []);
  fs.rmSync(root, { recursive: true, force: true });
});

test("reports a non-directory hash entry without traversing it", () => {
  const root = fixture();
  const hash = "0123456789ab";
  fs.writeFileSync(path.join(root, hash), "not-a-directory");
  sidecar(root, hash);

  assert.deepEqual(findOrphans(root, new Set(), true), [hash]);
  fs.rmSync(root, { recursive: true, force: true });
});
