import XCTest
@testable import OpenWithObsidianKit

final class VaultMatcherTests: XCTestCase {
    func vault(_ id: String, _ path: String) -> VaultEntry {
        VaultEntry(id: id, path: path, isOpen: false)
    }

    func testNoMatch() {
        let vaults = [vault("a", "/Users/me/notes")]
        let match = VaultMatcher.match(filePath: "/Users/me/other/x.md", vaults: vaults)
        XCTAssertNil(match)
    }

    func testSimpleMatch() {
        let vaults = [vault("a", "/Users/me/notes")]
        let m = VaultMatcher.match(filePath: "/Users/me/notes/foo.md", vaults: vaults)
        XCTAssertEqual(m?.entry.path, "/Users/me/notes")
        XCTAssertEqual(m?.relativePath, "foo.md")
    }

    func testNestedFile() {
        let vaults = [vault("a", "/Users/me/notes")]
        let m = VaultMatcher.match(filePath: "/Users/me/notes/a/b/c.md", vaults: vaults)
        XCTAssertEqual(m?.relativePath, "a/b/c.md")
    }

    func testLongestMatchWins() {
        let vaults = [
            vault("a", "/Users/me/notes"),
            vault("b", "/Users/me/notes/sub"),
        ]
        let m = VaultMatcher.match(filePath: "/Users/me/notes/sub/x.md", vaults: vaults)
        XCTAssertEqual(m?.entry.path, "/Users/me/notes/sub")
        XCTAssertEqual(m?.relativePath, "x.md")
    }

    func testTrailingSlashDoesntMisMatch() {
        let vaults = [vault("a", "/Users/me/notes")]
        let m = VaultMatcher.match(filePath: "/Users/me/notesXX/x.md", vaults: vaults)
        XCTAssertNil(m)
    }

    func testExactFile() {
        let vaults = [vault("a", "/Users/me/notes")]
        let m = VaultMatcher.match(filePath: "/Users/me/notes", vaults: vaults)
        XCTAssertNil(m, "the vault root isn't a file inside the vault")
    }

    func testVaultNameIsBasename() {
        XCTAssertEqual(VaultMatcher.vaultName(for: "/Users/me/notes"), "notes")
        XCTAssertEqual(VaultMatcher.vaultName(for: "/Users/me/My Vault"), "My Vault")
    }
}
