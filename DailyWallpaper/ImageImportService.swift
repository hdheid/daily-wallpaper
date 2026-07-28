import Foundation
import UniformTypeIdentifiers

struct ImportProgress: Sendable {
    var scanned = 0
    var imported = 0
    var duplicates = 0
    var skipped = 0
    var failed = 0
}

struct ImportSummary: Sendable {
    let progress: ImportProgress
    let cancelled: Bool
    let errors: [String]
}

actor ImageImportService {
    private let store: WallpaperStore
    private let index: MediaLibraryIndex
    private let pendingIndexQueue: PendingIndexQueue
    private let fileManager: FileManager

    init(
        store: WallpaperStore,
        index: MediaLibraryIndex,
        pendingIndexQueue: PendingIndexQueue,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.index = index
        self.pendingIndexQueue = pendingIndexQueue
        self.fileManager = fileManager
    }

    func importURLs(
        _ selectedURLs: [URL],
        label: String,
        destinationRoot: ResolvedLibraryRoot,
        availableRootURLs: [UUID: URL],
        progressHandler: @Sendable (ImportProgress) -> Void
    ) async -> ImportSummary {
        var progress = ImportProgress()
        var errors: [String] = []
        var cancelled = false
        let safeLabel = ImageFileUtilities.sanitizedPathComponent(label, fallback: "Imported")

        for selectedURL in selectedURLs {
            if Task.isCancelled {
                cancelled = true
                break
            }

            let accessed = selectedURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { selectedURL.stopAccessingSecurityScopedResource() }
            }

            do {
                let values = try selectedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true {
                    try await enumerateDirectory(
                        selectedURL,
                        label: safeLabel,
                        destinationRoot: destinationRoot,
                        availableRootURLs: availableRootURLs,
                        progress: &progress,
                        errors: &errors,
                        progressHandler: progressHandler
                    )
                } else if values.isRegularFile == true {
                    await processFile(
                        selectedURL,
                        label: safeLabel,
                        destinationRoot: destinationRoot,
                        availableRootURLs: availableRootURLs,
                        progress: &progress,
                        errors: &errors,
                        progressHandler: progressHandler
                    )
                } else {
                    progress.scanned += 1
                    progress.skipped += 1
                    progressHandler(progress)
                }
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                progress.failed += 1
                appendError("\(selectedURL.lastPathComponent)：\(error.localizedDescription)", to: &errors)
                progressHandler(progress)
            }
        }

        return ImportSummary(progress: progress, cancelled: cancelled || Task.isCancelled, errors: errors)
    }

    private func enumerateDirectory(
        _ directory: URL,
        label: String,
        destinationRoot: ResolvedLibraryRoot,
        availableRootURLs: [UUID: URL],
        progress: inout ImportProgress,
        errors: inout [String],
        progressHandler: @Sendable (ImportProgress) -> Void
    ) async throws {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .isHiddenKey,
            .typeIdentifierKey
        ]
        let enumerationErrors = DirectoryEnumerationErrorCollector()
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                // 单个目录读取失败不应终止整个批次，后续会继续枚举其他分支。
                enumerationErrors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                return true
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        while let fileURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true || values.isPackage == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }

            await processFile(
                fileURL,
                label: label,
                destinationRoot: destinationRoot,
                availableRootURLs: availableRootURLs,
                progress: &progress,
                errors: &errors,
                progressHandler: progressHandler
            )
        }

        let messages = enumerationErrors.snapshot()
        if !messages.isEmpty {
            progress.failed += messages.count
            messages.forEach { appendError($0, to: &errors) }
            progressHandler(progress)
        }
    }

    private func processFile(
        _ fileURL: URL,
        label: String,
        destinationRoot: ResolvedLibraryRoot,
        availableRootURLs: [UUID: URL],
        progress: inout ImportProgress,
        errors: inout [String],
        progressHandler: @Sendable (ImportProgress) -> Void
    ) async {
        progress.scanned += 1
        defer { progressHandler(progress) }

        guard isPotentiallySupported(fileURL) else {
            progress.skipped += 1
            return
        }

        do {
            _ = try ImageFileUtilities.inspect(url: fileURL)
            let hash = try ImageFileUtilities.sha256(url: fileURL)
            let locations = try await index.locations(contentSHA256: hash)
            var duplicateExists = false
            for location in locations {
                guard
                    let rootURL = availableRootURLs[location.rootID],
                    let archivedURL = safeImageURL(
                        relativePath: location.relativeImagePath,
                        under: rootURL
                    )
                else { continue }
                if await store.isValidArchivedImage(archivedURL, expectedSHA256: hash) {
                    duplicateExists = true
                    break
                }
            }
            if duplicateExists {
                progress.duplicates += 1
                return
            }

            let stored = try await store.archiveImported(
                ImportArchiveRequest(
                    sourceFileURL: fileURL,
                    importLabel: label,
                    importedAt: Date(),
                    originalFilename: fileURL.lastPathComponent
                ),
                in: destinationRoot
            )
            do {
                _ = try await index.upsert(stored.metadata)
                try? await pendingIndexQueue.remove(stored.metadata)
            } catch {
                try? await pendingIndexQueue.add(stored.metadata)
                throw error
            }
            progress.imported += 1
        } catch is CancellationError {
            // 当前文件原子步骤完成后，上层循环会在下一项开始前停止。
        } catch let error as ImageFileError {
            switch error {
            case .unsupportedImage, .animatedOrMultipage, .emptyFile, .invalidDimensions:
                progress.skipped += 1
            }
        } catch {
            progress.failed += 1
            appendError("\(fileURL.lastPathComponent)：\(error.localizedDescription)", to: &errors)
        }
    }

    private func isPotentiallySupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return ImageFileUtilities.isSupportedStaticImage(type)
    }

    private func appendError(_ value: String, to errors: inout [String]) {
        // 错误列表设置上限，避免极端目录把所有失败路径长期留在内存中。
        if errors.count < 100 { errors.append(value) }
    }

    private func safeImageURL(relativePath: String, under root: URL) -> URL? {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = canonicalRoot
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootComponents = canonicalRoot.pathComponents
        let childComponents = candidate.pathComponents
        guard
            childComponents.count > rootComponents.count,
            childComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        else { return nil }
        return candidate
    }
}

private final class DirectoryEnumerationErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if messages.count < 100 { messages.append(message) }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}
