import XCTest
@testable import BackupCore

final class UtilitiesParsingTests: XCTestCase {
    func testGlobMatcher() {
        XCTAssertTrue(GlobMatcher("**/*.swift").matches("Sources/BackupCore/Models.swift"))
        XCTAssertFalse(GlobMatcher("**/*.md").matches("Sources/BackupCore/Models.swift"))
        XCTAssertTrue(GlobMatcher("src/**/foo.txt").matches("src/a/b/c/foo.txt"))
        XCTAssertFalse(GlobMatcher("src/*/foo.txt").matches("src/a/b/foo.txt"))
    }

    func testAnyMatch() {
        XCTAssertTrue(anyMatch(["**/*.swift"], path: "a/b/c.swift"))
        XCTAssertFalse(anyMatch(["**/*.md"], path: "a/b/c.swift"))
    }

    func testParseBckpIgnore() throws {
        let text = """
        # comment
        exclude: **/.git/**
        include: src/**
        !src/vendor/**
        **/node_modules/**
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-ignore-")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let parsed = parseBckpIgnore(at: url)
        XCTAssertEqual(parsed.includes, ["src/**"])
        XCTAssertTrue(parsed.excludes.contains("**/.git/**"))
        XCTAssertTrue(parsed.excludes.contains("**/node_modules/**"))
        XCTAssertEqual(parsed.reincludes, ["src/vendor/**"])
    }
}
