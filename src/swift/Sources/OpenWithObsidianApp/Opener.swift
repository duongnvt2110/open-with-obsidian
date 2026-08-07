import Cocoa
import os.log
import OpenWithObsidianKit

private let log = OSLog(subsystem: "com.openwithobsidian.app", category: "Opener")

enum Opener {
    static func openFile(at fileURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            os_log("file does not exist: %{public}@", log: log, type: .error, fileURL.path)
            return false
        }

        if let vaults = try? VaultRegistry.load(),
           let match = VaultMatcher.match(filePath: fileURL.path, vaults: vaults) {
            let url = ObsidianURL.open(
                vault: VaultMatcher.vaultName(for: match.entry.path),
                file: match.relativePath
            )
            os_log("opening in existing vault: %{public}@", log: log, type: .info, url.absoluteString)
            return NSWorkspace.shared.open(url)
        }

        let vaultRoot = ScratchVault.defaultRoot
        guard let template = ScratchVault.bundledTemplate() else {
            os_log("bundled scratch-vault-template missing", log: log, type: .error)
            return false
        }
        do {
            try ScratchVault.bootstrap(at: vaultRoot, copyingTemplate: template)
            try VaultRegistry.add(path: vaultRoot.path)
            let res = try ScratchVault.symlink(sourcePath: fileURL.path, vaultRoot: vaultRoot)
            let relative = "\(res.hash)/\(res.basename)"
            let url = ObsidianURL.open(
                vault: VaultMatcher.vaultName(for: vaultRoot.path),
                file: relative
            )
            os_log("opening in scratch vault: %{public}@", log: log, type: .info, url.absoluteString)
            return NSWorkspace.shared.open(url)
        } catch {
            os_log("scratch flow failed: %{public}@", log: log, type: .error, String(describing: error))
            return false
        }
    }
}
