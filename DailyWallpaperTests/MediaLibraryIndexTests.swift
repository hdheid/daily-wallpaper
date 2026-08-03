import Foundation
import SQLite3
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

    func testRootPresenceAndDistinctRootIDsReflectIndexedRecords() async throws {
        let firstRoot = UUID()
        let secondRoot = UUID()
        _ = try await index.upsert(
            makeMetadata(hash: "first", rootID: firstRoot, day: "2026-07-27", recordedAt: Date())
        )
        _ = try await index.upsert(
            makeMetadata(hash: "second", rootID: secondRoot, day: "2026-07-27", recordedAt: Date())
        )

        let containsFirst = try await index.containsItems(rootID: firstRoot)
        let containsUnknown = try await index.containsItems(rootID: UUID())
        let rootIDs = try await index.rootIDs()
        XCTAssertTrue(containsFirst)
        XCTAssertFalse(containsUnknown)
        XCTAssertEqual(rootIDs, Set([firstRoot, secondRoot]))
    }

    func testDeleteRecordOnlyRemovesSelectedImage() async throws {
        let rootID = UUID()
        let first = try await index.upsert(
            makeMetadata(hash: "first", rootID: rootID, day: "2026-07-27", recordedAt: Date())
        )
        _ = try await index.upsert(
            makeMetadata(hash: "second", rootID: rootID, day: "2026-07-27", recordedAt: Date())
        )

        let didDelete = try await index.deleteRecord(matching: first)
        let didDeleteAgain = try await index.deleteRecord(matching: first)
        let count = try await index.count()
        let firstLocations = try await index.locations(contentSHA256: "first")
        let secondLocations = try await index.locations(contentSHA256: "second")
        XCTAssertTrue(didDelete)
        XCTAssertFalse(didDeleteAgain)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(firstLocations.isEmpty)
        XCTAssertEqual(secondLocations.count, 1)
    }

    func testSameHashDifferentMarketPathsCoexistAndDeleteIndependently() async throws {
        let rootID = UUID()
        let chineseItem = try await index.upsert(
            makeMetadata(
                hash: "same",
                rootID: rootID,
                day: "2026-07-27",
                recordedAt: Date(),
                sourceType: .bing,
                market: "zh-CN",
                directory: "zh-CN"
            )
        )
        let englishItem = try await index.upsert(
            makeMetadata(
                hash: "same",
                rootID: rootID,
                day: "2026-07-27",
                recordedAt: Date(),
                sourceType: .bing,
                market: "en-US",
                directory: "en-US"
            )
        )
        let countBeforeDelete = try await index.count()
        let didDeleteChineseItem = try await index.deleteRecord(matching: chineseItem)
        let remainingCount = try await index.count()
        let englishPage = try await index.page(query: MediaLibraryQuery(market: "en-US"))

        XCTAssertNotEqual(chineseItem.id, englishItem.id)
        XCTAssertEqual(countBeforeDelete, 2)
        XCTAssertTrue(didDeleteChineseItem)
        XCTAssertEqual(remainingCount, 1)
        XCTAssertEqual(englishPage.items.map(\.id), [englishItem.id])
    }

    func testTodayQueryFiltersByContentDayAndMarket() async throws {
        let rootID = UUID()
        _ = try await index.upsert(makeMetadata(
            hash: "today-cn",
            rootID: rootID,
            day: "2026-07-29",
            recordedAt: Date(),
            sourceType: .bing,
            market: "zh-CN",
            directory: "today-cn"
        ))
        _ = try await index.upsert(makeMetadata(
            hash: "today-us",
            rootID: rootID,
            day: "2026-07-29",
            recordedAt: Date(),
            sourceType: .bing,
            market: "en-US",
            directory: "today-us"
        ))
        _ = try await index.upsert(makeMetadata(
            hash: "yesterday-cn",
            rootID: rootID,
            day: "2026-07-28",
            recordedAt: Date(),
            sourceType: .bing,
            market: "zh-CN",
            directory: "yesterday-cn"
        ))

        let page = try await index.page(query: MediaLibraryQuery(
            sourceType: .bing,
            market: "zh-CN",
            contentDay: "2026-07-29"
        ))
        XCTAssertEqual(page.items.map(\.contentSHA256), ["today-cn"])
    }

    func testLegacyDatabaseMigratesWithoutLosingExistingRows() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let databaseURL = base.appendingPathComponent("legacy.sqlite")
        let rootID = UUID()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let legacySQL = """
            CREATE TABLE images (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content_sha256 TEXT NOT NULL, provider_hash TEXT, root_id TEXT NOT NULL,
                relative_image_path TEXT NOT NULL, relative_metadata_path TEXT NOT NULL,
                source_type TEXT NOT NULL, content_date REAL NOT NULL, recorded_at REAL NOT NULL,
                market TEXT NOT NULL, pixel_width INTEGER NOT NULL, pixel_height INTEGER NOT NULL,
                title TEXT NOT NULL, copyright_text TEXT NOT NULL, source_url TEXT,
                mime_type TEXT NOT NULL, file_size INTEGER NOT NULL,
                UNIQUE(content_sha256, root_id)
            );
            INSERT INTO images VALUES (
                7, 'same', NULL, '\(rootID.uuidString)', 'zh-CN/same.jpg', 'zh-CN/same.json',
                'bing', 1785283200, 1785283200, 'zh-CN', 1920, 1080,
                '中文标题', '中文介绍', NULL, 'image/jpeg', 123
            );
            """
        XCTAssertEqual(sqlite3_exec(database, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(database)

        let migratedIndex = try MediaLibraryIndex(databaseURL: databaseURL)
        _ = try await migratedIndex.upsert(makeMetadata(
            hash: "same",
            rootID: rootID,
            day: "2026-07-29",
            recordedAt: Date(),
            sourceType: .bing,
            market: "en-US",
            directory: "en-US"
        ))
        let migratedCount = try await migratedIndex.count()
        let chinesePage = try await migratedIndex.page(query: MediaLibraryQuery(market: "zh-CN"))
        await migratedIndex.close()

        XCTAssertEqual(migratedCount, 2)
        XCTAssertEqual(chinesePage.items.first?.id, 7)
        XCTAssertEqual(chinesePage.items.first?.title, "中文标题")
    }

    func testMigrationConflictRollsBackAndPreservesLegacyTable() throws {
        let databaseURL = try makeStandaloneDatabaseURL(named: "conflict.sqlite")
        let rootID = UUID()
        let legacySQL = """
            \(legacyTableSQL)
            PRAGMA user_version = 1;
            INSERT INTO images VALUES (
                1, 'first', NULL, '\(rootID.uuidString)', 'first.jpg', 'same.json',
                'bing', 1785283200, 1785283200, 'zh-CN', 1920, 1080,
                '第一条', '第一条介绍', NULL, 'image/jpeg', 123
            );
            INSERT INTO images VALUES (
                2, 'second', NULL, '\(rootID.uuidString)', 'second.jpg', 'same.json',
                'bing', 1785283200, 1785283200, 'en-US', 1920, 1080,
                'Second', 'Second description', NULL, 'image/jpeg', 456
            );
            """
        try executeRawSQL(legacySQL, at: databaseURL)

        XCTAssertThrowsError(try MediaLibraryIndex(databaseURL: databaseURL))

        // 重新用原始 SQLite 连接取证：事务失败后旧表、旧版本和两条数据必须原样保留。
        XCTAssertEqual(try rawInt("SELECT COUNT(*) FROM images;", at: databaseURL), 2)
        XCTAssertEqual(try rawInt("PRAGMA user_version;", at: databaseURL), 1)
        XCTAssertEqual(
            try rawInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'images_v2';",
                at: databaseURL
            ),
            0
        )
    }

    func testFakeV2SchemaIsRepairedBeforeUpsert() async throws {
        let databaseURL = try makeStandaloneDatabaseURL(named: "fake-v2.sqlite")
        let rootID = UUID()
        let fakeV2SQL = """
            \(legacyTableSQL)
            PRAGMA user_version = 2;
            INSERT INTO images VALUES (
                7, 'same', NULL, '\(rootID.uuidString)', 'zh-CN/same.jpg', 'zh-CN/same.json',
                'bing', 1785283200, 1785283200, 'zh-CN', 1920, 1080,
                '中文标题', '中文介绍', NULL, 'image/jpeg', 123
            );
            """
        try executeRawSQL(fakeV2SQL, at: databaseURL)

        let repairedIndex = try MediaLibraryIndex(databaseURL: databaseURL)
        _ = try await repairedIndex.upsert(makeMetadata(
            hash: "same",
            rootID: rootID,
            day: "2026-07-29",
            recordedAt: Date(),
            sourceType: .bing,
            market: "en-US",
            directory: "en-US"
        ))
        let count = try await repairedIndex.count()
        await repairedIndex.close()

        XCTAssertEqual(count, 2)
        XCTAssertEqual(try rawInt("PRAGMA user_version;", at: databaseURL), 2)
    }

    func testFutureSchemaVersionIsRejectedWithoutChangingDatabase() throws {
        let databaseURL = try makeStandaloneDatabaseURL(named: "future.sqlite")
        let rootID = UUID()
        let futureSQL = """
            \(legacyTableSQL)
            PRAGMA user_version = 3;
            INSERT INTO images VALUES (
                9, 'future', NULL, '\(rootID.uuidString)', 'future.jpg', 'future.json',
                'bing', 1785283200, 1785283200, 'zh-CN', 1920, 1080,
                '未来数据', '不能被旧应用修改', NULL, 'image/jpeg', 789
            );
            """
        try executeRawSQL(futureSQL, at: databaseURL)

        XCTAssertThrowsError(try MediaLibraryIndex(databaseURL: databaseURL)) { error in
            guard case let MediaLibraryIndexError.unsupportedSchemaVersion(found, supported) = error else {
                return XCTFail("应返回不支持的数据库版本错误，实际为：\(error)")
            }
            XCTAssertEqual(found, 3)
            XCTAssertEqual(supported, 2)
        }
        XCTAssertEqual(try rawInt("PRAGMA user_version;", at: databaseURL), 3)
        XCTAssertEqual(try rawInt("SELECT COUNT(*) FROM images;", at: databaseURL), 1)
    }

    private var legacyTableSQL: String {
        """
        CREATE TABLE images (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content_sha256 TEXT NOT NULL, provider_hash TEXT, root_id TEXT NOT NULL,
            relative_image_path TEXT NOT NULL, relative_metadata_path TEXT NOT NULL,
            source_type TEXT NOT NULL, content_date REAL NOT NULL, recorded_at REAL NOT NULL,
            market TEXT NOT NULL, pixel_width INTEGER NOT NULL, pixel_height INTEGER NOT NULL,
            title TEXT NOT NULL, copyright_text TEXT NOT NULL, source_url TEXT,
            mime_type TEXT NOT NULL, file_size INTEGER NOT NULL,
            UNIQUE(content_sha256, root_id)
        );
        """
    }

    private func makeStandaloneDatabaseURL(named name: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base.appendingPathComponent(name)
    }

    private func executeRawSQL(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "MediaLibraryIndexTests", code: 1)
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "MediaLibraryIndexTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
            )
        }
    }

    private func rawInt(_ sql: String, at databaseURL: URL) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "MediaLibraryIndexTests", code: 3)
        }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw NSError(domain: "MediaLibraryIndexTests", code: 4)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "MediaLibraryIndexTests", code: 5)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func makeMetadata(
        hash: String,
        rootID: UUID,
        day: String,
        recordedAt: Date,
        sourceType: WallpaperSourceType = .imported,
        market: String = "Imported",
        directory: String? = nil
    ) -> ArchiveMetadata {
        let prefix = directory.map { "\($0)/" } ?? ""
        return ArchiveMetadata(
            contentSHA256: hash,
            providerHash: nil,
            sourceType: sourceType,
            rootID: rootID,
            relativeImagePath: "\(prefix)\(hash).jpg",
            relativeMetadataPath: "\(prefix)\(hash).json",
            title: hash,
            copyrightText: "",
            sourceURL: nil,
            contentDate: day,
            recordedAt: recordedAt,
            market: market,
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            mimeType: "image/jpeg",
            fileSize: 123,
            originalFilename: nil,
            dateSource: "test"
        )
    }
}
