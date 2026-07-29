import XCTest
@testable import DailyWallpaper

final class CurrentWallpaperStatusTests: XCTestCase {
    func testMatcherNormalizesFilePathComponents() {
        let lhs = URL(fileURLWithPath: "/tmp/daily-wallpaper/folder/../image.jpg")
        let rhs = URL(fileURLWithPath: "/tmp/daily-wallpaper/image.jpg")

        XCTAssertTrue(CurrentWallpaperURLMatcher.matches(lhs, rhs))
    }

    func testMatcherKeepsDifferentRootsDistinct() {
        let lhs = URL(fileURLWithPath: "/tmp/library-a/image.jpg")
        let rhs = URL(fileURLWithPath: "/tmp/library-b/image.jpg")

        XCTAssertFalse(CurrentWallpaperURLMatcher.matches(lhs, rhs))
    }

    func testMatcherRejectsNonFileURL() {
        let local = URL(fileURLWithPath: "/tmp/image.jpg")
        let remote = URL(string: "https://example.com/image.jpg")

        XCTAssertFalse(CurrentWallpaperURLMatcher.matches(local, remote))
    }

    func testFingerprintChangesWhenFileIsOverwrittenInPlace() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-wallpaper-fingerprint-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("first".utf8).write(to: url)
        let first = try XCTUnwrap(CurrentWallpaperFileFingerprint.read(from: url))
        try Data("replacement-with-a-different-size".utf8).write(to: url, options: .atomic)
        let second = try XCTUnwrap(CurrentWallpaperFileFingerprint.read(from: url))

        XCTAssertNotEqual(first, second)
    }
}
