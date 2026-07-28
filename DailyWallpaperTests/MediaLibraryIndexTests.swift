import Foundation
import XCTest
@testable import DailyWallpaper

final class MediaLibraryIndexTests: XCTestCase {
    private var directory: URL!
    private var index: MediaLibraryIndex!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        index = try MediaLibraryIndex(databaseURL: directory.appendingPathComponent("library.sqlite"))
    }

    override func tearDown() async throws {
        await index.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testUpsertDoesNotCreateDuplicateInSameRoot() async throws {
        let rootID = UUID()
        let metadata = makeMetadata(hash: "same", rootID: rootID, day: "2026-07-27", recordedAt: Date())
        _ = try await index.upsert(metadata)
        _ = try await index.upsert(metadata)
        let count = try await index.count()
        XCTAssertEqual(count, 1)
    }

    func testKeysetPaginationIsStableForEqualDates() async throws {
        let rootID = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for value in 0 ..< 205 {
            _ = try await index.upsert(makeMetadata(hash: "hash-\(value)", rootID: rootID, day: "2026-07-27", recordedAt: date))
        }

        var cursor: MediaLibraryCursor?
        var ids = Set<Int64>()
        repeat {
            let page = try await index.page(query: MediaLibraryQuery(pageSize: 80), after: cursor)
            page.items.forEach { ids.insert($0.id) }
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(ids.count, 205)
    }

    func testDeleteRecordsOnlyRemovesSelectedRoot() async throws {
        let firstRoot = UUID()
        let secondRoot = UUID()
        _ = try await index.upsert(makeMetadata(hash: "first", rootID: firstRoot, day: "2026-07-27", recordedAt: Date()))
        _ = try await index.upsert(makeMetadata(hash: "second", rootID: secondRoot, day: "2026-07-27", recordedAt: Date()))

        try await index.deleteRecords(rootID: firstRoot)

        let count = try await index.count()
        let firstLocations = try await index.locations(contentSHA256: "first")
        let secondLocations = try await index.locations(contentSHA256: "second")
        XCTAssertEqual(count, 1)
        XCTAssertTrue(firstLocations.isEmpty)
        XCTAssertEqual(secondLocations.first?.rootID, secondRoot)
    }

    private func makeMetadata(hash: String, rootID: UUID, day: String, recordedAt: Date) -> ArchiveMetadata {
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
            contentDate: day,
            recordedAt: recordedAt,
            market: "Imported",
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            mimeType: "image/jpeg",
            fileSize: 123,
            originalFilename: nil,
            dateSource: "test"
        )
    }
}
