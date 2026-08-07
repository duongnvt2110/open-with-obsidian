import Foundation

public struct VaultMatch {
    public let entry: VaultEntry
    public let relativePath: String
}

public enum VaultMatcher {
    /// Returns the best-matching vault and the relative file path within it,
    /// or nil if the file isn't inside any vault. "Best" = longest prefix.
    public static func match(filePath: String, vaults: [VaultEntry]) -> VaultMatch? {
        let fileCanon = canonicalize(filePath)
        var best: VaultMatch?
        for vault in vaults {
            let vaultCanon = canonicalize(vault.path)
            let prefix = vaultCanon.hasSuffix("/") ? vaultCanon : vaultCanon + "/"
            guard fileCanon.hasPrefix(prefix) else { continue }
            let relative = String(fileCanon.dropFirst(prefix.count))
            if relative.isEmpty { continue }
            if best == nil || vault.path.count > best!.entry.path.count {
                best = VaultMatch(entry: vault, relativePath: relative)
            }
        }
        return best
    }

    public static func vaultName(for path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func canonicalize(_ p: String) -> String {
        let url = URL(fileURLWithPath: p)
        return url.resolvingSymlinksInPath().path
    }
}
