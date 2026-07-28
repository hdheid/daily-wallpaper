import Foundation

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
        if let data = try? Data(contentsOf: fileURL),
           let values = try? decoder.decode([String: ArchiveMetadata].self, from: data)
        {
            entries = values
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

    func all() -> [ArchiveMetadata] {
        Array(entries.values)
    }

    private func key(for metadata: ArchiveMetadata) -> String {
        "\(metadata.rootID.uuidString)|\(metadata.contentSHA256)"
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
