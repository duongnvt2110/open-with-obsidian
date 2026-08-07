import XCTest
@testable import OpenWithObsidianKit

final class PathHashTests: XCTestCase {
    func testKnownValue() {
        XCTAssertEqual(PathHash.shortHex("/x"), "b3d1db318671")
    }

    func testStable() {
        XCTAssertEqual(PathHash.shortHex("/a/b/c"), PathHash.shortHex("/a/b/c"))
    }

    func testDiffers() {
        XCTAssertNotEqual(PathHash.shortHex("/a/b/c"), PathHash.shortHex("/a/b/d"))
    }

    func testLength12HexChars() {
        let h = PathHash.shortHex("/Users/zndrr/Desktop/notes.md")
        XCTAssertEqual(h.count, 12)
        XCTAssertTrue(h.allSatisfy { $0.isHexDigit })
    }
}
