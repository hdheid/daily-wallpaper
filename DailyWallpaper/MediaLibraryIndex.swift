import Foundation
import SQLite3

enum MediaLibraryIndexError: LocalizedError {
    case openFailed(String)
    case sqlite(String)
    case closed
    case invalidRootID

    var errorDescription: String? {
        switch self {
        case let .openFailed(message): "无法打开媒体库索引：\(message)"
        case let .sqlite(message): "媒体库索引错误：\(message)"
        case .closed: "媒体库索引已经关闭"
        case .invalidRootID: "索引中的媒体库目录 ID 无效"
        }
    }
}

struct MediaContentLocation: Hashable, Sendable {
    let rootID: UUID
    let relativeImagePath: String
}

actor MediaLibraryIndex {
    private enum SQLValue {
        case text(String)
        case int64(Int64)
        case double(Double)
        case null
    }

    private var database: OpaquePointer?
    let databaseURL: URL

    init(databaseURL: URL, fileManager: FileManager = .default) throws {
        self.databaseURL = databaseURL
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let connection { sqlite3_close_v2(connection) }
            throw MediaLibraryIndexError.openFailed(message)
        }
        database = connection

        do {
            try Self.execute(connection, sql: "PRAGMA journal_mode = WAL;")
            try Self.execute(connection, sql: "PRAGMA synchronous = NORMAL;")
            try Self.execute(connection, sql: "PRAGMA foreign_keys = ON;")
            try Self.execute(connection, sql: "PRAGMA auto_vacuum = INCREMENTAL;")
            try Self.execute(connection, sql: "PRAGMA journal_size_limit = 8388608;")
            try Self.execute(connection, sql: "PRAGMA wal_autocheckpoint = 1000;")
            try Self.execute(connection, sql: Self.schemaSQL)
        } catch {
            database = nil
            sqlite3_close_v2(connection)
            throw error
        }
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw MediaLibraryIndexError.openFailed("无法找到 Application Support")
        }
        return base
            .appendingPathComponent(AppConstants.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("library.sqlite")
    }

    @discardableResult
    func upsert(_ metadata: ArchiveMetadata) throws -> MediaLibraryItem {
        let db = try requireDatabase()
        try Self.execute(db, sql: "BEGIN IMMEDIATE;")
        do {
            let sql = """
                INSERT INTO images (
                    content_sha256, provider_hash, root_id, relative_image_path,
                    relative_metadata_path, source_type, content_date, recorded_at,
                    market, pixel_width, pixel_height, title, copyright_text,
                    source_url, mime_type, file_size
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(content_sha256, root_id) DO UPDATE SET
                    provider_hash = excluded.provider_hash,
                    relative_image_path = excluded.relative_image_path,
                    relative_metadata_path = excluded.relative_metadata_path,
                    source_type = excluded.source_type,
                    content_date = excluded.content_date,
                    recorded_at = excluded.recorded_at,
                    market = excluded.market,
                    pixel_width = excluded.pixel_width,
                    pixel_height = excluded.pixel_height,
                    title = excluded.title,
                    copyright_text = excluded.copyright_text,
                    source_url = excluded.source_url,
                    mime_type = excluded.mime_type,
                    file_size = excluded.file_size;
                """
            try run(
                sql,
                values: [
                    .text(metadata.contentSHA256),
                    metadata.providerHash.map(SQLValue.text) ?? .null,
                    .text(metadata.rootID.uuidString),
                    .text(metadata.relativeImagePath),
                    .text(metadata.relativeMetadataPath),
                    .text(metadata.sourceType.rawValue),
                    .double(Self.dateFromDayString(metadata.contentDate).timeIntervalSince1970),
                    .double(metadata.recordedAt.timeIntervalSince1970),
                    .text(metadata.market),
                    .int64(Int64(metadata.pixelWidth)),
                    .int64(Int64(metadata.pixelHeight)),
                    .text(metadata.title),
                    .text(metadata.copyrightText),
                    metadata.sourceURL.map { .text($0.absoluteString) } ?? .null,
                    .text(metadata.mimeType),
                    .int64(metadata.fileSize)
                ]
            )
            let item = try item(contentSHA256: metadata.contentSHA256, rootID: metadata.rootID)
            try Self.execute(db, sql: "COMMIT;")
            return item
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    func page(query: MediaLibraryQuery, after cursor: MediaLibraryCursor? = nil) throws -> MediaLibraryPage {
        let db = try requireDatabase()
        var predicates: [String] = []
        var values: [SQLValue] = []

        if let sourceType = query.sourceType {
            predicates.append("source_type = ?")
            values.append(.text(sourceType.rawValue))
        }
        if let market = query.market, !market.isEmpty {
            predicates.append("market = ?")
            values.append(.text(market))
        }
        if let width = query.pixelWidth {
            predicates.append("pixel_width = ?")
            values.append(.int64(Int64(width)))
        }
        if let height = query.pixelHeight {
            predicates.append("pixel_height = ?")
            values.append(.int64(Int64(height)))
        }
        if let text = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            predicates.append("(title LIKE ? ESCAPE '\\' OR copyright_text LIKE ? ESCAPE '\\')")
            let pattern = "%\(Self.escapeLike(text))%"
            values.append(.text(pattern))
            values.append(.text(pattern))
        }

        let sortColumn: String
        let direction: String
        let comparison: String
        switch query.sortOrder {
        case .newestContent:
            sortColumn = "content_date"
            direction = "DESC"
            comparison = "<"
        case .oldestContent:
            sortColumn = "content_date"
            direction = "ASC"
            comparison = ">"
        case .recentlyAdded:
            sortColumn = "recorded_at"
            direction = "DESC"
            comparison = "<"
        }

        if let cursor {
            predicates.append("(\(sortColumn) \(comparison) ? OR (\(sortColumn) = ? AND id \(comparison) ?))")
            values.append(.double(cursor.sortDate.timeIntervalSince1970))
            values.append(.double(cursor.sortDate.timeIntervalSince1970))
            values.append(.int64(cursor.id))
        }

        let whereClause = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
        let safeLimit = min(max(query.pageSize, 1), 500)
        values.append(.int64(Int64(safeLimit + 1)))
        let sql = """
            SELECT id, content_sha256, provider_hash, root_id, relative_image_path,
                   relative_metadata_path, source_type, content_date, recorded_at,
                   market, pixel_width, pixel_height, title, copyright_text,
                   source_url, mime_type, file_size
            FROM images
            \(whereClause)
            ORDER BY \(sortColumn) \(direction), id \(direction)
            LIMIT ?;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, database: db)

        var rows: [MediaLibraryItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(try decodeItem(statement))
        }
        guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else {
            throw sqliteError(db)
        }

        let reachedEnd = rows.count <= safeLimit
        let items = Array(rows.prefix(safeLimit))
        let nextCursor: MediaLibraryCursor?
        if !reachedEnd, let last = items.last {
            let sortDate = query.sortOrder == .recentlyAdded ? last.recordedAt : last.contentDate
            nextCursor = MediaLibraryCursor(sortDate: sortDate, id: last.id)
        } else {
            nextCursor = nil
        }
        return MediaLibraryPage(items: items, nextCursor: nextCursor, reachedEnd: reachedEnd)
    }

    func locations(contentSHA256: String) throws -> [MediaContentLocation] {
        let db = try requireDatabase()
        let sql = "SELECT root_id, relative_image_path FROM images WHERE content_sha256 = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        try bind([.text(contentSHA256)], to: statement, database: db)

        var result: [MediaContentLocation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rootID = UUID(uuidString: text(statement, column: 0)) else { continue }
            result.append(MediaContentLocation(rootID: rootID, relativeImagePath: text(statement, column: 1)))
        }
        return result
    }

    func deleteRecords(rootID: UUID) throws {
        try run("DELETE FROM images WHERE root_id = ?;", values: [.text(rootID.uuidString)])
    }

    func count() throws -> Int {
        let db = try requireDatabase()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM images;", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(db) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func facets() throws -> MediaLibraryFacets {
        let db = try requireDatabase()
        var markets: [String] = []
        var marketStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT market FROM images ORDER BY market COLLATE NOCASE;", -1, &marketStatement, nil) == SQLITE_OK, let marketStatement else {
            throw sqliteError(db)
        }
        while sqlite3_step(marketStatement) == SQLITE_ROW {
            markets.append(text(marketStatement, column: 0))
        }
        sqlite3_finalize(marketStatement)

        var resolutions: [PixelSize] = []
        var resolutionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT pixel_width, pixel_height FROM images ORDER BY pixel_width DESC, pixel_height DESC;", -1, &resolutionStatement, nil) == SQLITE_OK, let resolutionStatement else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(resolutionStatement) }
        while sqlite3_step(resolutionStatement) == SQLITE_ROW {
            resolutions.append(PixelSize(
                width: Int(sqlite3_column_int64(resolutionStatement, 0)),
                height: Int(sqlite3_column_int64(resolutionStatement, 1))
            ))
        }
        return MediaLibraryFacets(markets: markets, resolutions: resolutions)
    }

    func checkpoint() throws {
        let db = try requireDatabase()
        guard sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil) == SQLITE_OK else {
            throw sqliteError(db)
        }
    }

    func close() {
        guard let database else { return }
        sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
        sqlite3_close_v2(database)
        self.database = nil
    }

    private func item(contentSHA256: String, rootID: UUID) throws -> MediaLibraryItem {
        let db = try requireDatabase()
        let sql = """
            SELECT id, content_sha256, provider_hash, root_id, relative_image_path,
                   relative_metadata_path, source_type, content_date, recorded_at,
                   market, pixel_width, pixel_height, title, copyright_text,
                   source_url, mime_type, file_size
            FROM images WHERE content_sha256 = ? AND root_id = ? LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        try bind([.text(contentSHA256), .text(rootID.uuidString)], to: statement, database: db)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(db) }
        return try decodeItem(statement)
    }

    private func run(_ sql: String, values: [SQLValue]) throws {
        let db = try requireDatabase()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, database: db)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer, database: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case let .int64(number): result = sqlite3_bind_int64(statement, index, number)
            case let .double(number): result = sqlite3_bind_double(statement, index, number)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw sqliteError(database) }
        }
    }

    private func decodeItem(_ statement: OpaquePointer) throws -> MediaLibraryItem {
        guard let rootID = UUID(uuidString: text(statement, column: 3)) else {
            throw MediaLibraryIndexError.invalidRootID
        }
        let sourceURLString = optionalText(statement, column: 14)
        return MediaLibraryItem(
            id: sqlite3_column_int64(statement, 0),
            contentSHA256: text(statement, column: 1),
            providerHash: optionalText(statement, column: 2),
            rootID: rootID,
            relativeImagePath: text(statement, column: 4),
            relativeMetadataPath: text(statement, column: 5),
            sourceType: WallpaperSourceType(rawValue: text(statement, column: 6)) ?? .imported,
            contentDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            market: text(statement, column: 9),
            pixelWidth: Int(sqlite3_column_int64(statement, 10)),
            pixelHeight: Int(sqlite3_column_int64(statement, 11)),
            title: text(statement, column: 12),
            copyrightText: text(statement, column: 13),
            sourceURL: sourceURLString.flatMap(URL.init(string:)),
            mimeType: text(statement, column: 15),
            fileSize: sqlite3_column_int64(statement, 16)
        )
    }

    private func requireDatabase() throws -> OpaquePointer {
        guard let database else { throw MediaLibraryIndexError.closed }
        return database
    }

    private func sqliteError(_ database: OpaquePointer) -> MediaLibraryIndexError {
        .sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column: column)
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw MediaLibraryIndexError.sqlite(message)
        }
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func dateFromDayString(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value) ?? Date(timeIntervalSince1970: 0)
    }

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS images (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content_sha256 TEXT NOT NULL,
            provider_hash TEXT,
            root_id TEXT NOT NULL,
            relative_image_path TEXT NOT NULL,
            relative_metadata_path TEXT NOT NULL,
            source_type TEXT NOT NULL,
            content_date REAL NOT NULL,
            recorded_at REAL NOT NULL,
            market TEXT NOT NULL,
            pixel_width INTEGER NOT NULL,
            pixel_height INTEGER NOT NULL,
            title TEXT NOT NULL,
            copyright_text TEXT NOT NULL,
            source_url TEXT,
            mime_type TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            UNIQUE(content_sha256, root_id)
        );
        CREATE INDEX IF NOT EXISTS idx_images_content_date ON images(content_date DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_images_recorded_at ON images(recorded_at DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_images_sha ON images(content_sha256);
        CREATE INDEX IF NOT EXISTS idx_images_source ON images(source_type);
        CREATE INDEX IF NOT EXISTS idx_images_market ON images(market);
        CREATE INDEX IF NOT EXISTS idx_images_resolution ON images(pixel_width, pixel_height);
        """
}
