import Foundation
import XCTest
@testable import DailyWallpaper

final class PendingIndexQueueTests: XCTestCase {
    func testQueuePersistsAndRemovesEntriesByRoot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("pending-index.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstRoot = UUID()
        let secondRoot = UUID()
        let queue = try PendingIndexQueue(fileURL: fileURL)
        try await queue.add(metadata(hash: "a", rootID: firstRoot))
        try await queue.add(metadata(hash: "b", rootID: secondRoot))

        let reloaded = try PendingIndexQueue(fileURL: fileURL)
        let reloadedCount = await reloaded.all().count
        XCTAssertEqual(reloadedCount, 2)
        try await reloaded.remove(rootID: firstRoot)
        let remaining = await reloaded.all()
        XCTAssertEqual(remaining.map(\.rootID), [secondRoot])
    }

    private func metadata(hash: String, rootID: UUID) -> ArchiveMetadata {
        ArchiveMetadata(
            contentSHA256: hash,
            providerHash: nil,
            sourceType: .imported,
            rootID: rootID,
            relativeImagePath: "\(hash).jpg",
            relativeMetadataPath: "\(hash).json",
            title: hash,
            copyrightText: "",
            sourceURL: nil,
            contentDate: "2026-07-27",
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            market: "Imported",
            pixelWidth: 1,
            pixelHeight: 1,
            mimeType: "image/jpeg",
            fileSize: 1,
            originalFilename: nil,
            dateSource: "test"
        )
    }
}
