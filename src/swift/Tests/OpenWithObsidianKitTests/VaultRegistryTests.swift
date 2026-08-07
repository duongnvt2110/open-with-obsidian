import XCTest
@testable import OpenWithObsidianKit

final class VaultRegistryTests: XCTestCase {
    func testAddIsIdempotentAndPreservesRegistryData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-test-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = root.appendingPathComponent("nested/obsidian.json")
        let vault = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let initial: [String: Any] = ["settings": ["keep": true]]
        let initialData = try JSONSerialization.data(withJSONObject: initial)
        try FileManager.default.createDirectory(
            at: registry.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try initialData.write(to: registry)

        try VaultRegistry.add(path: vault.path, to: registry)
        try VaultRegistry.add(path: vault.path, to: registry)

        let data = try Data(contentsOf: registry)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["settings"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual(try VaultRegistry.load(from: registry).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: registry.appendingPathExtension("lock").path
        ))
    }

    func testLoadSkipsInvalidVaultPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-invalid-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = root.appendingPathComponent("obsidian.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "vaults": [
                "valid": ["path": root.path],
                "invalid": ["path": "relative/path"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: registry)

        let entries = try VaultRegistry.load(from: registry)
        XCTAssertEqual(entries.map(\.id), ["valid"])
    }
}
