import XCTest
@testable import OpenWithObsidianKit

final class ObsidianURLTests: XCTestCase {
    func testSimple() {
        let url = ObsidianURL.open(vault: "MyVault", file: "notes.md")
        XCTAssertEqual(url.absoluteString,
                       "obsidian://open?vault=MyVault&file=notes.md")
    }

    func testSpaceInFile() {
        let url = ObsidianURL.open(vault: "MyVault", file: "my notes.md")
        XCTAssertEqual(url.absoluteString,
                       "obsidian://open?vault=MyVault&file=my%20notes.md")
    }

    func testSpaceInVault() {
        let url = ObsidianURL.open(vault: "My Vault", file: "x.md")
        XCTAssertEqual(url.absoluteString,
                       "obsidian://open?vault=My%20Vault&file=x.md")
    }

    func testUnicode() {
        let url = ObsidianURL.open(vault: "V", file: "メモ.md")
        XCTAssertTrue(url.absoluteString.hasPrefix("obsidian://open?vault=V&file="))
        XCTAssertNotNil(URL(string: url.absoluteString))
    }

    func testNestedFile() {
        let url = ObsidianURL.open(vault: "V", file: "a1b2c3d4e5f6/notes.md")
        XCTAssertEqual(url.absoluteString,
                       "obsidian://open?vault=V&file=a1b2c3d4e5f6%2Fnotes.md")
    }
}
