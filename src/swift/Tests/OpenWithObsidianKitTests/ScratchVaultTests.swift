import XCTest
@testable import OpenWithObsidianKit

final class ScratchVaultTests: XCTestCase {
    var tempBase: URL!
    var templateDir: URL!

    override func setUpWithError() throws {
        tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-test-\(UUID().uuidString)")
        templateDir = tempBase.appendingPathComponent("template")
        try FileManager.default.createDirectory(
            at: templateDir.appendingPathComponent(".obsidian"),
            withIntermediateDirectories: true
        )
        try "marker".write(
            to: templateDir.appendingPathComponent(".obsidian/marker.txt"),
            atomically: true, encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempBase)
    }

    func testBootstrapCreatesScratchVaultFromTemplate() throws {
        let vaultDir = tempBase.appendingPathComponent("ScratchVault")
        try ScratchVault.bootstrap(at: vaultDir, copyingTemplate: templateDir)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vaultDir.appendingPathComponent(".obsidian/marker.txt").path
        ))
    }

    func testBootstrapIsIdempotent() throws {
        let vaultDir = tempBase.appendingPathComponent("ScratchVault")
        try ScratchVault.bootstrap(at: vaultDir, copyingTemplate: templateDir)
        let marker = vaultDir.appendingPathComponent(".obsidian/marker.txt")
        try "modified".write(to: marker, atomically: true, encoding: .utf8)
        try ScratchVault.bootstrap(at: vaultDir, copyingTemplate: templateDir)
        let s = try String(contentsOf: marker)
        XCTAssertEqual(s, "modified")
    }

    func testSymlinkCreatesHashDirAndSymlinkAndSidecar() throws {
        let vaultDir = tempBase.appendingPathComponent("ScratchVault")
        try ScratchVault.bootstrap(at: vaultDir, copyingTemplate: templateDir)
        let sourceFile = tempBase.appendingPathComponent("real.md")
        try "hello".write(to: sourceFile, atomically: true, encoding: .utf8)

        let result = try ScratchVault.symlink(sourcePath: sourceFile.path, vaultRoot: vaultDir)
        XCTAssertEqual(result.basename, "real.md")
        XCTAssertEqual(result.hash.count, 12)

        let linkPath = vaultDir.appendingPathComponent("\(result.hash)/real.md").path
        let attrs = try FileManager.default.attributesOfItem(atPath: linkPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)

        let sidecarPath = vaultDir.appendingPathComponent(".openwith/\(result.hash).json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarPath))
        let data = try Data(contentsOf: URL(fileURLWithPath: sidecarPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["source"] as? String,
                       sourceFile.resolvingSymlinksInPath().path)
    }

    func testSymlinkIsIdempotentForSameSource() throws {
        let vaultDir = tempBase.appendingPathComponent("ScratchVault")
        try ScratchVault.bootstrap(at: vaultDir, copyingTemplate: templateDir)
        let sourceFile = tempBase.appendingPathComponent("real.md")
        try "hello".write(to: sourceFile, atomically: true, encoding: .utf8)
        let r1 = try ScratchVault.symlink(sourcePath: sourceFile.path, vaultRoot: vaultDir)
        let r2 = try ScratchVault.symlink(sourcePath: sourceFile.path, vaultRoot: vaultDir)
        XCTAssertEqual(r1.hash, r2.hash)
    }
}
