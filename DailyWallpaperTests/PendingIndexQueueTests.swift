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

    func testQueueRemovesOnlySelectedImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("pending-index.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let rootID = UUID()
        let queue = try PendingIndexQueue(fileURL: fileURL)
        try await queue.add(metadata(hash: "first", rootID: rootID))
        try await queue.add(metadata(hash: "second", rootID: rootID))

        try await queue.remove(rootID: rootID, relativeMetadataPath: "first.json")

        let remaining = await queue.all()
        XCTAssertEqual(remaining.map(\.contentSHA256), ["second"])
    }

    func testQueueKeepsLocalizedRecordsWithSameImageHash() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("pending-index.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let rootID = UUID()
        let queue = try PendingIndexQueue(fileURL: fileURL)
        try await queue.add(metadata(hash: "same", rootID: rootID, market: "zh-CN"))
        try await queue.add(metadata(hash: "same", rootID: rootID, market: "en-US"))
        try await queue.remove(rootID: rootID, relativeMetadataPath: "zh-CN/same.json")

        let remaining = await queue.all()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.market, "en-US")
    }

    func testCorruptedQueueIsReportedAndPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("pending-index.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corruptedData = Data(#"{"unfinished": "#.utf8)
        try corruptedData.write(to: fileURL)

        XCTAssertThrowsError(try PendingIndexQueue(fileURL: fileURL)) { error in
            guard case PendingIndexQueueError.invalidFormat = error else {
                return XCTFail("应返回明确的队列格式错误，实际为：\(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptedData)
    }

    private func metadata(hash: String, rootID: UUID, market: String = "Imported") -> ArchiveMetadata {
        let prefix = market == "Imported" ? "" : "\(market)/"
        return ArchiveMetadata(
            contentSHA256: hash,
            providerHash: nil,
            sourceType: .imported,
            rootID: rootID,
            relativeImagePath: "\(prefix)\(hash).jpg",
            relativeMetadataPath: "\(prefix)\(hash).json",
            title: hash,
            copyrightText: "",
            sourceURL: nil,
            contentDate: "2026-07-27",
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            market: market,
            pixelWidth: 1,
            pixelHeight: 1,
            mimeType: "image/jpeg",
            fileSize: 1,
            originalFilename: nil,
            dateSource: "test"
        )
    }
}
