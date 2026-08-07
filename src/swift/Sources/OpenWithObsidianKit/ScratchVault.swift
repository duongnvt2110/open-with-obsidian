import Foundation

public struct SymlinkResult {
    public let hash: String
    public let basename: String

    public init(hash: String, basename: String) {
        self.hash = hash
        self.basename = basename
    }
}

public enum ScratchVault {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenWithObsidian/ScratchVault")
    }

    /// Copy the bundled scratch-vault template into `vaultRoot` if and only if
    /// the vault doesn't already exist. Existing user data is preserved.
    public static func bootstrap(at vaultRoot: URL, copyingTemplate template: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: vaultRoot.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        let lockURL = vaultRoot.appendingPathComponent(".openwith.lock")
        try SafeFile.withExclusiveLock(at: lockURL) {
            if fm.fileExists(atPath: vaultRoot.appendingPathComponent(".obsidian").path) {
                return
            }
            if !fm.fileExists(atPath: vaultRoot.path) {
                try fm.copyItem(at: template, to: vaultRoot)
            } else {
                let entries = try fm.contentsOfDirectory(at: template, includingPropertiesForKeys: nil)
                for entry in entries {
                    let dest = vaultRoot.appendingPathComponent(entry.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try fm.copyItem(at: entry, to: dest)
                    }
                }
            }
        }
    }

    /// Create the per-file symlink and sidecar inside the scratch vault.
    public static func symlink(sourcePath: String, vaultRoot: URL) throws -> SymlinkResult {
        let lockURL = vaultRoot.appendingPathComponent(".openwith.lock")
        return try SafeFile.withExclusiveLock(at: lockURL) {
            let fm = FileManager.default
            let sourceURL = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
            let canonicalSource = sourceURL.path
            let hash = PathHash.shortHex(canonicalSource)
            let basename = sourceURL.lastPathComponent

            let entryDir = vaultRoot.appendingPathComponent(hash)
            let linkURL = entryDir.appendingPathComponent(basename)

            try fm.createDirectory(at: entryDir, withIntermediateDirectories: true)

            if let existing = try? fm.destinationOfSymbolicLink(atPath: linkURL.path),
               existing == canonicalSource {
                // already correct, no-op
            } else {
                try? fm.removeItem(at: linkURL)
                try fm.createSymbolicLink(atPath: linkURL.path,
                                          withDestinationPath: canonicalSource)
            }

            let sidecarDir = vaultRoot.appendingPathComponent(".openwith")
            try fm.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
            let sidecar: [String: Any] = [
                "source": canonicalSource,
                "openedAt": Int(Date().timeIntervalSince1970),
            ]
            let data = try JSONSerialization.data(withJSONObject: sidecar, options: [])
            try SafeFile.atomicWrite(data, to: sidecarDir.appendingPathComponent("\(hash).json"))

            return SymlinkResult(hash: hash, basename: basename)
        }
    }

    /// Locate the bundled scratch-vault template next to the running executable.
    /// Looks under `<.app>/Contents/Resources/scratch-vault-template`.
    public static func bundledTemplate() -> URL? {
        // Bundle.main works when invoked from .app/Contents/MacOS; in unit
        // tests we expect callers to inject their own path.
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "scratch-vault-template", withExtension: nil) {
            return url
        }
        let resourceURL = bundle.bundleURL
            .appendingPathComponent("Contents/Resources/scratch-vault-template")
        if FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }
        return nil
    }
}
