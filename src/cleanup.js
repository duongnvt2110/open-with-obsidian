const fs = require("node:fs");
const path = require("node:path");

function cleanupEntry(vaultRoot, hash) {
  if (!/^[0-9a-f]{12}$/.test(hash)) return false;
  fs.rmSync(path.join(vaultRoot, hash), { recursive: true, force: true });
  fs.rmSync(path.join(vaultRoot, ".openwith", `${hash}.json`), { force: true });
  return true;
}

module.exports = { cleanupEntry };
