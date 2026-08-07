const { Plugin } = require("obsidian");
const { cleanupEntry } = require("./cleanup");
const { findOrphans } = require("./reconcile");

const STARTUP_RETRIES = 8;
const STARTUP_RETRY_DELAY_MS = 500;
const CLOSED_ENTRY_GRACE_MS = 5000;

class ScratchCleanupPlugin extends Plugin {
  async onload() {
    this.cleanBrokenSymlinks = true;
    this.reconcileTimer = null;

    this.addCommand({
      id: "scratch-cleanup-now",
      name: "Clean stale scratch entries",
      callback: () => this.reconcileNow(),
    });

    for (const event of ["active-leaf-change", "layout-change"]) {
      this.registerEvent(this.app.workspace.on(event, () => {
        this.scheduleReconcile();
      }));
    }

    this.register(() => {
      if (this.reconcileTimer !== null) clearTimeout(this.reconcileTimer);
    });

    this.app.workspace.onLayoutReady(() => this.reconcileOnStartup());
  }

  vaultRoot() {
    return this.app.vault.adapter.getBasePath();
  }

  reconcileNow() {
    const openHashes = new Set();
    this.app.workspace.iterateAllLeaves((leaf) => {
      const file = leaf && leaf.view && leaf.view.file;
      const hash = file && leadingHash(file.path);
      if (hash) openHashes.add(hash);
    });

    for (const hash of findOrphans(
      this.vaultRoot(),
      openHashes,
      this.cleanBrokenSymlinks,
      { closedEntryGraceMs: CLOSED_ENTRY_GRACE_MS },
    )) {
      cleanupEntry(this.vaultRoot(), hash);
    }
  }

  scheduleReconcile() {
    if (this.reconcileTimer !== null) clearTimeout(this.reconcileTimer);
    this.reconcileTimer = setTimeout(() => {
      this.reconcileTimer = null;
      this.reconcileNow();
    }, CLOSED_ENTRY_GRACE_MS);
  }

  async reconcileOnStartup() {
    // Keep valid sidecars while Obsidian discovers the newly-created
    // ScratchVault entry. The retry is harmless because reconcileNow is
    // idempotent and only removes proven orphans.
    for (let attempt = 0; attempt < STARTUP_RETRIES; attempt += 1) {
      this.reconcileNow();
      if (attempt + 1 < STARTUP_RETRIES) {
        await new Promise((resolve) => setTimeout(resolve, STARTUP_RETRY_DELAY_MS));
      }
    }
  }
}

function leadingHash(vaultPath) {
  const match = /^([0-9a-f]{12})\//.exec(vaultPath);
  return match ? match[1] : null;
}

module.exports = ScratchCleanupPlugin;
module.exports.leadingHash = leadingHash;
