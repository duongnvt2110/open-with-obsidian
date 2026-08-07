import Foundation
import Security

public struct VaultEntry: Equatable {
    public let id: String
    public let path: String
    public let isOpen: Bool

    public init(id: String, path: String, isOpen: Bool) {
        self.id = id
        self.path = path
        self.isOpen = isOpen
    }
}

public enum VaultRegistry {
    public static var defaultRegistryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    public static func load(from url: URL = defaultRegistryURL) throws -> [VaultEntry] {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let vaults = json["vaults"] as? [String: [String: Any]] else { return [] }
        return vaults.compactMap { id, info in
            guard let path = info["path"] as? String,
                  let canonicalPath = try? validatedVaultPath(path) else {
                return nil
            }
            return VaultEntry(
                id: id,
                path: canonicalPath,
                isOpen: (info["open"] as? Bool) ?? false
            )
        }.sorted { $0.id < $1.id }
    }

    /// Add an entry to the registry, writing back to disk. Idempotent on path.
    public static func add(path: String, to url: URL = defaultRegistryURL) throws {
        let canonicalPath = try validatedVaultPath(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let lockURL = url.appendingPathExtension("lock")
        try SafeFile.withExclusiveLock(at: lockURL) {
            var json: [String: Any] = [:]
            if let data = try? Data(contentsOf: url),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = parsed
            }
            var vaults = (json["vaults"] as? [String: [String: Any]]) ?? [:]
            if vaults.contains(where: { ($0.value["path"] as? String).flatMap({ try? validatedVaultPath($0) }) == canonicalPath }) {
                return
            }
            let id = try randomVaultId()
            vaults[id] = [
                "path": canonicalPath,
                "ts": Int(Date().timeIntervalSince1970 * 1000),
            ]
            json["vaults"] = vaults
            let out = try JSONSerialization.data(withJSONObject: json, options: [])
            try SafeFile.atomicWrite(out, to: url)
        }
    }

    private static func validatedVaultPath(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(domain: "OpenWithObsidianKit", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid Obsidian vault path: \(path)",
            ])
        }
        return url.resolvingSymlinksInPath().path
    }

    private static func randomVaultId() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Unable to generate a vault identifier",
            ])
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
