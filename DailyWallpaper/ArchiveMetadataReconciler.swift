import Foundation

enum ArchiveMetadataReconciliationError: LocalizedError {
    case directoryUnavailable
    case enumerationFailed(String, restoredCount: Int)

    var restoredCount: Int {
        switch self {
        case .directoryUnavailable: 0
        case let .enumerationFailed(_, restoredCount): restoredCount
        }
    }

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable: "无法读取媒体库目录"
        case let .enumerationFailed(message, _): "媒体库目录扫描失败：\(message)"
        }
    }
}

/// 数据库升级后只执行一次的轻量恢复器：串行读取旁车 JSON，不把图片或全部记录一次性载入内存。
actor ArchiveMetadataReconciler {
    static let currentVersion = 3

    private let fileManager: FileManager
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func reconcile(root: ResolvedLibraryRoot, index: MediaLibraryIndex) async throws -> Int {
        let canonicalRoot = root.url.resolvingSymlinksInPath().standardizedFileURL
        let collector = ArchiveEnumerationErrorCollector()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                collector.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                return true
            }
        ) else {
            throw ArchiveMetadataReconciliationError.directoryUnavailable
        }

        var restoredCount = 0
        while let fileURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard fileURL.pathExtension.caseInsensitiveCompare("json") == .orderedSame else { continue }
            // 自定义媒体库中可能有用户自己的 JSON，只处理应用生成的日期目录 + SHA 旁车结构。
            guard isArchiveSidecarCandidate(fileURL, under: canonicalRoot) else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else {
                collector.append("无法读取 \(fileURL.lastPathComponent) 的文件属性")
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                collector.append("\(fileURL.lastPathComponent) 不是可恢复的普通文件")
                continue
            }

            let decoded: Result<ArchiveMetadata, Error> = autoreleasepool {
                Result {
                    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                    return try decoder.decode(ArchiveMetadata.self, from: data)
                }
            }
            let decodedMetadata: ArchiveMetadata
            switch decoded {
            case let .success(value):
                decodedMetadata = value
            case let .failure(error):
                collector.append("无法解析 \(fileURL.lastPathComponent)：\(error.localizedDescription)")
                continue
            }

            // SQLite 和设置都是可恢复状态；图片目录中的旁车 JSON 才是媒体库的长期事实来源。
            // 重新安装或重新添加目录会改变旧版随机 rootID，此时安全地挂接到当前已授权目录。
            let metadata = decodedMetadata.rootID == root.root.id
                ? decodedMetadata
                : decodedMetadata.replacingRootID(with: root.root.id)
            guard
                let metadataURL = safeURL(relativePath: metadata.relativeMetadataPath, under: canonicalRoot),
                metadataURL == fileURL.resolvingSymlinksInPath().standardizedFileURL
            else {
                collector.append("\(fileURL.lastPathComponent) 的元数据路径不匹配")
                continue
            }
            guard
                let imageURL = safeURL(relativePath: metadata.relativeImagePath, under: canonicalRoot),
                let imageValues = try? imageURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                imageValues.isRegularFile == true,
                imageValues.isSymbolicLink != true
            else {
                collector.append("\(fileURL.lastPathComponent) 对应的图片不可用")
                continue
            }
            let normalizedHash = metadata.contentSHA256.lowercased()
            guard
                normalizedHash.count == 64,
                normalizedHash.allSatisfy(\.isHexDigit),
                imageURL.deletingPathExtension().lastPathComponent.lowercased() == normalizedHash,
                fileURL.deletingPathExtension().lastPathComponent.lowercased() == normalizedHash
            else {
                collector.append("\(fileURL.lastPathComponent) 的归档哈希身份不匹配")
                continue
            }
            do {
                guard try ImageFileUtilities.sha256(url: imageURL) == normalizedHash else {
                    collector.append("\(fileURL.lastPathComponent) 对应的图片内容已变化")
                    continue
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                collector.append("无法校验 \(imageURL.lastPathComponent)：\(error.localizedDescription)")
                continue
            }

            _ = try await index.upsert(metadata)
            restoredCount += 1
            if restoredCount.isMultiple(of: 32) {
                // 大图库升级时主动让出执行权，避免一次性恢复影响前台交互。
                await Task.yield()
            }
        }

        if let message = collector.firstMessage {
            throw ArchiveMetadataReconciliationError.enumerationFailed(
                message,
                restoredCount: restoredCount
            )
        }
        return restoredCount
    }

    private func isArchiveSidecarCandidate(_ fileURL: URL, under root: URL) -> Bool {
        let standardizedFile = fileURL.standardizedFileURL
        let rootComponents = root.pathComponents
        let fileComponents = standardizedFile.pathComponents
        guard
            fileComponents.count == rootComponents.count + 6,
            fileComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        else { return false }

        let relative = Array(fileComponents.dropFirst(rootComponents.count))
        let year = relative[0]
        let month = relative[1]
        let day = relative[2]
        let resolution = relative[4].split(separator: "x", omittingEmptySubsequences: false)
        let hash = URL(fileURLWithPath: relative[5]).deletingPathExtension().lastPathComponent
        return year.count == 4 && year.allSatisfy(\.isNumber)
            && month.count == 2 && month.allSatisfy(\.isNumber)
            && day.count == 2 && day.allSatisfy(\.isNumber)
            && resolution.count == 2
            && resolution.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            && hash.count == 64
            && hash.allSatisfy(\.isHexDigit)
    }

    private func safeURL(relativePath: String, under root: URL) -> URL? {
        let candidate = root
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootComponents = root.pathComponents
        let childComponents = candidate.pathComponents
        guard
            childComponents.count > rootComponents.count,
            childComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        else { return nil }
        return candidate
    }
}

private final class ArchiveEnumerationErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?

    var firstMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return message
    }

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        if message == nil { message = value }
    }
}
