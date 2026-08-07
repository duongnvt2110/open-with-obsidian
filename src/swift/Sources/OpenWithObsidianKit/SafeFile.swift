import Foundation
import Darwin

enum SafeFile {
    static func withExclusiveLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Unable to open lock file: \(url.path)",
            ])
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let code = errno
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "Unable to lock file: \(url.path)",
            ])
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try body()
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }
}
