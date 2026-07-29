import Foundation

enum WallpaperStoreError: LocalizedError {
    case archivePathOutsideRoot
    case incompleteCommit

    var errorDescription: String? {
        switch self {
        case .archivePathOutsideRoot: "归档路径超出媒体库目录"
        case .incompleteCommit: "图片与元数据未能完整提交"
        }
    }
}

actor WallpaperStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func inspectImage(at url: URL, requireSingleFrame: Bool = true) throws -> ImageInspection {
        try ImageFileUtilities.inspect(url: url, requireSingleFrame: requireSingleFrame)
    }

    func sha256(of url: URL) throws -> String {
        try ImageFileUtilities.sha256(url: url)
    }

    func isValidArchivedImage(_ url: URL, expectedSHA256: String) -> Bool {
        do {
            _ = try ImageFileUtilities.inspect(url: url)
            return try ImageFileUtilities.sha256(url: url) == expectedSHA256
        } catch {
            return false
        }
    }

    func archiveDownloaded(
        _ request: DownloadArchiveRequest,
        in resolvedRoot: ResolvedLibraryRoot
    ) throws -> StoredWallpaper {
        defer { try? fileManager.removeItem(at: request.temporaryFileURL) }

        return try archiveDownloadedSource(
            imageSourceURL: request.temporaryFileURL,
            remoteSourceURL: request.sourceURL,
            candidate: request.candidate,
            requestedMarket: request.requestedMarket,
            recordedAt: request.recordedAt,
            resolvedRoot: resolvedRoot
        )
    }

    /// 多个国家返回同一张图片时复用已经归档的字节，只为当前国家生成独立目录和本地化 JSON。
    func archiveDownloaded(
        candidate: BingImageCandidate,
        reusing source: StoredWallpaper,
        requestedMarket: String,
        recordedAt: Date,
        in resolvedRoot: ResolvedLibraryRoot
    ) throws -> StoredWallpaper {
        try archiveDownloadedSource(
            imageSourceURL: source.imageURL,
            remoteSourceURL: source.metadata.sourceURL,
            candidate: candidate,
            requestedMarket: requestedMarket,
            recordedAt: recordedAt,
            resolvedRoot: resolvedRoot
        )
    }

    private func archiveDownloadedSource(
        imageSourceURL: URL,
        remoteSourceURL: URL?,
        candidate: BingImageCandidate,
        requestedMarket: String,
        recordedAt: Date,
        resolvedRoot: ResolvedLibraryRoot
    ) throws -> StoredWallpaper {

        let inspection = try ImageFileUtilities.inspect(url: imageSourceURL)
        let hash = try ImageFileUtilities.sha256(url: imageSourceURL)
        let (contentDate, dateSource) = bingContentDate(
            endDate: candidate.endDate,
            startDate: candidate.startDate,
            fallback: recordedAt
        )

        return try commit(
            sourceURL: imageSourceURL,
            resolvedRoot: resolvedRoot,
            contentSHA256: hash,
            inspection: inspection,
            sourceType: .bing,
            providerHash: candidate.providerHash,
            title: candidate.title,
            copyrightText: candidate.copyrightText,
            remoteSourceURL: remoteSourceURL,
            contentDate: contentDate,
            recordedAt: recordedAt,
            market: requestedMarket,
            originalFilename: nil,
            dateSource: dateSource,
            copySource: true
        )
    }

    func archiveImported(
        _ request: ImportArchiveRequest,
        in resolvedRoot: ResolvedLibraryRoot
    ) throws -> StoredWallpaper {
        // 来源文件可能被同步或编辑程序改写；先复制快照，后续身份信息只读取这一份稳定内容。
        let stagingDirectory = try ensureDirectoryTree([".staging"], under: resolvedRoot.url)
        let snapshotURL = stagingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("source")
        try fileManager.copyItem(at: request.sourceFileURL, to: snapshotURL)
        defer { try? fileManager.removeItem(at: snapshotURL) }

        let inspection = try ImageFileUtilities.inspect(url: snapshotURL)
        let hash = try ImageFileUtilities.sha256(url: snapshotURL)
        let resourceDate = try? snapshotURL.resourceValues(forKeys: [.creationDateKey]).creationDate
        let selectedDate = inspection.exifDate ?? resourceDate ?? request.importedAt
        let dateSource = inspection.exifDate != nil ? "exifDateTimeOriginal" : (resourceDate != nil ? "fileCreationDate" : "importDate")

        return try commit(
            sourceURL: snapshotURL,
            resolvedRoot: resolvedRoot,
            contentSHA256: hash,
            inspection: inspection,
            sourceType: .imported,
            providerHash: nil,
            title: request.originalFilename,
            copyrightText: "",
            remoteSourceURL: nil,
            contentDate: Self.dayString(selectedDate),
            recordedAt: request.importedAt,
            market: request.importLabel,
            originalFilename: request.originalFilename,
            dateSource: dateSource,
            copySource: false
        )
    }

    private func commit(
        sourceURL: URL,
        resolvedRoot: ResolvedLibraryRoot,
        contentSHA256: String,
        inspection: ImageInspection,
        sourceType: WallpaperSourceType,
        providerHash: String?,
        title: String,
        copyrightText: String,
        remoteSourceURL: URL?,
        contentDate: String,
        recordedAt: Date,
        market: String,
        originalFilename: String?,
        dateSource: String,
        copySource: Bool
    ) throws -> StoredWallpaper {
        let components = contentDate.split(separator: "-").map(String.init)
        let safeDateComponents = components.count == 3 ? components : Self.dayString(recordedAt).split(separator: "-").map(String.init)
        let safeMarket = ImageFileUtilities.sanitizedPathComponent(market, fallback: "Imported")
        let resolution = "\(inspection.pixelWidth)x\(inspection.pixelHeight)"
        let canonicalRoot = try ensureDirectoryTree([], under: resolvedRoot.url)
        let directory = try ensureDirectoryTree(
            [safeDateComponents[0], safeDateComponents[1], safeDateComponents[2], safeMarket, resolution],
            under: canonicalRoot
        )

        let imageURL = directory
            .appendingPathComponent(contentSHA256)
            .appendingPathExtension(inspection.preferredFileExtension)
        let metadataURL = directory
            .appendingPathComponent(contentSHA256)
            .appendingPathExtension("json")
        let relativeImagePath = try relativePath(of: imageURL, under: canonicalRoot)
        let relativeMetadataPath = try relativePath(of: metadataURL, under: canonicalRoot)

        let stagingDirectory = try ensureDirectoryTree([".staging"], under: canonicalRoot)
        let transactionID = UUID().uuidString
        let stagedImage = stagingDirectory.appendingPathComponent(transactionID + ".image")
        defer {
            try? fileManager.removeItem(at: stagedImage)
        }

        let imageExists = fileManager.fileExists(atPath: imageURL.path)
        let existingImageIsValid = imageExists && isValidExistingImage(
            imageURL,
            expectedSHA256: contentSHA256,
            expectedInspection: inspection
        )
        if imageExists, !existingImageIsValid {
            let values = try imageURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw WallpaperStoreError.incompleteCommit }
        }

        if !existingImageIsValid {
            if copySource {
                try fileManager.copyItem(at: sourceURL, to: stagedImage)
            } else {
                try fileManager.moveItem(at: sourceURL, to: stagedImage)
            }
        }

        let committedFileSource = existingImageIsValid ? imageURL : stagedImage
        let sourceFileSize = (try? committedFileSource.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let metadata = ArchiveMetadata(
            contentSHA256: contentSHA256,
            providerHash: providerHash,
            sourceType: sourceType,
            rootID: resolvedRoot.root.id,
            relativeImagePath: relativeImagePath,
            relativeMetadataPath: relativeMetadataPath,
            title: title,
            copyrightText: copyrightText,
            sourceURL: remoteSourceURL,
            contentDate: contentDate,
            recordedAt: recordedAt,
            market: safeMarket,
            pixelWidth: inspection.pixelWidth,
            pixelHeight: inspection.pixelHeight,
            mimeType: inspection.mimeType,
            fileSize: sourceFileSize,
            originalFilename: originalFilename,
            dateSource: dateSource
        )
        let metadataData = try encoder.encode(metadata)

        var changedImage = false
        do {
            if !existingImageIsValid, imageExists {
                _ = try fileManager.replaceItemAt(imageURL, withItemAt: stagedImage)
                changedImage = true
            } else if !existingImageIsValid {
                try fileManager.moveItem(at: stagedImage, to: imageURL)
                changedImage = true
            }
            // Data.atomic 在目标目录内写临时文件并替换，旧 JSON 在成功前始终保留。
            try metadataData.write(to: metadataURL, options: .atomic)
        } catch {
            // 元数据提交失败时撤销本次新图片，避免留下无法重建索引的半条目。
            if changedImage { try? fileManager.removeItem(at: imageURL) }
            throw WallpaperStoreError.incompleteCommit
        }

        return StoredWallpaper(metadata: metadata, imageURL: imageURL, metadataURL: metadataURL)
    }

    private func relativePath(of child: URL, under root: URL) throws -> String {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalChild = child.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = canonicalRoot.pathComponents
        let childComponents = canonicalChild.pathComponents
        guard
            childComponents.count > rootComponents.count,
            childComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        else { throw WallpaperStoreError.archivePathOutsideRoot }
        return childComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func ensureDirectoryTree(_ components: [String], under root: URL) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var current = root.resolvingSymlinksInPath().standardizedFileURL
        let rootValues = try current.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else { throw WallpaperStoreError.archivePathOutsideRoot }

        for component in components {
            let next = current.appendingPathComponent(component, isDirectory: true)
            if fileManager.fileExists(atPath: next.path) {
                let values = try next.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw WallpaperStoreError.archivePathOutsideRoot
                }
            } else {
                try fileManager.createDirectory(at: next, withIntermediateDirectories: false)
            }
            current = next
        }
        return current
    }

    private func isValidExistingImage(
        _ url: URL,
        expectedSHA256: String,
        expectedInspection: ImageInspection
    ) -> Bool {
        do {
            let inspection = try ImageFileUtilities.inspect(url: url)
            guard
                inspection.pixelWidth == expectedInspection.pixelWidth,
                inspection.pixelHeight == expectedInspection.pixelHeight,
                inspection.preferredFileExtension == expectedInspection.preferredFileExtension
            else { return false }
            return try ImageFileUtilities.sha256(url: url) == expectedSHA256
        } catch {
            return false
        }
    }

    private func bingContentDate(endDate: String?, startDate: String?, fallback: Date) -> (String, String) {
        // 必应中国区的 startdate 可能仍是 UTC 日期；enddate 才对应市场当地展示日期。
        if let normalizedEndDate = normalizedBingDate(endDate) {
            return (normalizedEndDate, "bingEndDate")
        }
        if let normalizedStartDate = normalizedBingDate(startDate) {
            return (normalizedStartDate, "bingStartDate")
        }
        return (Self.dayString(fallback), "downloadDate")
    }

    private func normalizedBingDate(_ rawValue: String?) -> String? {
        guard
            let rawValue,
            rawValue.count == 8,
            rawValue.allSatisfy(\.isNumber)
        else {
            return nil
        }
        let year = rawValue.prefix(4)
        let month = rawValue.dropFirst(4).prefix(2)
        let day = rawValue.suffix(2)
        let formatted = "\(year)-\(month)-\(day)"

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard parser.date(from: formatted) != nil else { return nil }
        return formatted
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
