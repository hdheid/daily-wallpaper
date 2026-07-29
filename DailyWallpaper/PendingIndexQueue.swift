import Foundation

enum PendingIndexQueueError: LocalizedError {
    case unreadable(URL, String)
    case invalidFormat(URL, String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(url, message):
            "无法读取待索引队列，原文件已保留：\(url.path)（\(message)）"
        case let .invalidFormat(url, message):
            "待索引队列格式损坏，原文件已保留：\(url.path)（\(message)）"
        }
    }
}

actor PendingIndexQueue {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private var entries: [String: ArchiveMetadata]

    init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if fileManager.fileExists(atPath: fileURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                // 已存在的队列可能仍是失败归档的唯一恢复入口，不能把读取错误当成空队列。
                throw PendingIndexQueueError.unreadable(fileURL, error.localizedDescription)
            }

            let values: [String: ArchiveMetadata]
            do {
                values = try decoder.decode([String: ArchiveMetadata].self, from: data)
            } catch {
                // 保留损坏文件供用户恢复或排查；后续增删操作也不会覆盖其中尚可抢救的记录。
                throw PendingIndexQueueError.invalidFormat(fileURL, error.localizedDescription)
            }

            // 旧版本按 SHA 建键，会让同图不同国家互相覆盖；加载时统一迁移为旁车 JSON 路径身份。
            entries = values.values.reduce(into: [:]) { result, metadata in
                result[Self.key(rootID: metadata.rootID, relativeMetadataPath: metadata.relativeMetadataPath)] = metadata
            }
        } else {
            entries = [:]
        }
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    static func defaultQueueURL(fileManager: FileManager = .default) throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw MediaLibraryIndexError.openFailed("无法找到 Application Support")
        }
        return base
            .appendingPathComponent(AppConstants.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("pending-index.json")
    }

    func add(_ metadata: ArchiveMetadata) throws {
        var updated = entries
        updated[key(for: metadata)] = metadata
        try persist(updated)
        entries = updated
    }

    func remove(_ metadata: ArchiveMetadata) throws {
        var updated = entries
        updated.removeValue(forKey: key(for: metadata))
        try persist(updated)
        entries = updated
    }

    func remove(rootID: UUID) throws {
        let updated = entries.filter { $0.value.rootID != rootID }
        try persist(updated)
        entries = updated
    }

    func remove(rootID: UUID, relativeMetadataPath: String) throws {
        var updated = entries
        updated.removeValue(forKey: Self.key(rootID: rootID, relativeMetadataPath: relativeMetadataPath))
        try persist(updated)
        entries = updated
    }

    func all() -> [ArchiveMetadata] {
        Array(entries.values)
    }

    private func key(for metadata: ArchiveMetadata) -> String {
        Self.key(rootID: metadata.rootID, relativeMetadataPath: metadata.relativeMetadataPath)
    }

    private static func key(rootID: UUID, relativeMetadataPath: String) -> String {
        "\(rootID.uuidString)|\(relativeMetadataPath)"
    }

    private func persist(_ values: [String: ArchiveMetadata]) throws {
        if values.isEmpty {
            do {
                try fileManager.removeItem(at: fileURL)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // 首次运行还没有队列文件时，空队列已经是期望状态。
            }
            return
        }
        // 队列只有索引失败项，使用原子写避免退出时留下半个 JSON。
        try encoder.encode(values).write(to: fileURL, options: .atomic)
    }
}
