import Foundation

enum LibraryRootKind: String, Codable, Sendable {
    case defaultPictures
    case securityScoped
}

struct LibraryRoot: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var kind: LibraryRootKind
    var bookmarkData: Data?
    var isActiveWriteRoot: Bool

    /// 默认图片目录使用稳定 ID，避免重新安装后同一目录被误认为新的媒体库。
    static let defaultRootID = UUID(uuidString: "DA11CA11-0000-4000-8000-000000000001")!

    static func defaultRoot(id: UUID = defaultRootID) -> LibraryRoot {
        LibraryRoot(
            id: id,
            displayName: AppConstants.defaultArchiveFolderName,
            kind: .defaultPictures,
            bookmarkData: nil,
            isActiveWriteRoot: true
        )
    }
}

struct ResolvedLibraryRoot: Hashable, Sendable {
    let root: LibraryRoot
    let url: URL
}

enum WallpaperSourceType: String, Codable, CaseIterable, Sendable {
    case bing
    case imported

    var localizedName: String {
        switch self {
        case .bing: "Bing"
        case .imported: "外部导入"
        }
    }
}

struct ImageInspection: Codable, Hashable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let frameCount: Int
    let uniformTypeIdentifier: String
    let mimeType: String
    let preferredFileExtension: String
    let exifDate: Date?
}

struct ArchiveMetadata: Codable, Hashable, Sendable {
    var schemaVersion: Int = 1
    let contentSHA256: String
    let providerHash: String?
    let sourceType: WallpaperSourceType
    let rootID: UUID
    let relativeImagePath: String
    let relativeMetadataPath: String
    let title: String
    let copyrightText: String
    let sourceURL: URL?
    let contentDate: String
    let recordedAt: Date
    let market: String
    let pixelWidth: Int
    let pixelHeight: Int
    let mimeType: String
    let fileSize: Int64
    let originalFilename: String?
    let dateSource: String
}

extension ArchiveMetadata {
    /// 重新挂接已存在的归档目录时，仅替换目录身份，其余旁车信息保持不变。
    func replacingRootID(with rootID: UUID) -> ArchiveMetadata {
        ArchiveMetadata(
            schemaVersion: schemaVersion,
            contentSHA256: contentSHA256,
            providerHash: providerHash,
            sourceType: sourceType,
            rootID: rootID,
            relativeImagePath: relativeImagePath,
            relativeMetadataPath: relativeMetadataPath,
            title: title,
            copyrightText: copyrightText,
            sourceURL: sourceURL,
            contentDate: contentDate,
            recordedAt: recordedAt,
            market: market,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            mimeType: mimeType,
            fileSize: fileSize,
            originalFilename: originalFilename,
            dateSource: dateSource
        )
    }
}

struct StoredWallpaper: Hashable, Sendable {
    let metadata: ArchiveMetadata
    let imageURL: URL
    let metadataURL: URL
}

struct DownloadArchiveRequest: Sendable {
    let temporaryFileURL: URL
    let sourceURL: URL
    let mimeType: String
    let candidate: BingImageCandidate
    let requestedMarket: String
    let recordedAt: Date
}

struct ImportArchiveRequest: Sendable {
    let sourceFileURL: URL
    let importLabel: String
    let importedAt: Date
    let originalFilename: String
}

enum MediaSortOrder: String, CaseIterable, Sendable {
    case newestContent
    case oldestContent
    case recentlyAdded
}

struct MediaLibraryQuery: Sendable {
    var sourceType: WallpaperSourceType?
    var market: String?
    var contentDay: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var searchText: String?
    var sortOrder: MediaSortOrder = .newestContent
    var pageSize: Int = AppConstants.mediaLibraryPageSize

    init(
        sourceType: WallpaperSourceType? = nil,
        market: String? = nil,
        contentDay: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        searchText: String? = nil,
        sortOrder: MediaSortOrder = .newestContent,
        pageSize: Int = AppConstants.mediaLibraryPageSize
    ) {
        self.sourceType = sourceType
        self.market = market
        self.contentDay = contentDay
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.searchText = searchText
        self.sortOrder = sortOrder
        self.pageSize = pageSize
    }
}

struct MediaLibraryCursor: Hashable, Sendable {
    let sortDate: Date
    let id: Int64
}

struct MediaLibraryItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let contentSHA256: String
    let providerHash: String?
    let rootID: UUID
    let relativeImagePath: String
    let relativeMetadataPath: String
    let sourceType: WallpaperSourceType
    let contentDate: Date
    let recordedAt: Date
    let market: String
    let pixelWidth: Int
    let pixelHeight: Int
    let title: String
    let copyrightText: String
    let sourceURL: URL?
    let mimeType: String
    let fileSize: Int64

    var aspectRatio: CGFloat {
        guard pixelHeight > 0 else { return 1 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }
}

struct MediaLibraryPage: Sendable {
    let items: [MediaLibraryItem]
    let nextCursor: MediaLibraryCursor?
    let reachedEnd: Bool
}

struct PixelSize: Hashable, Sendable {
    let width: Int
    let height: Int

    var label: String { "\(width)x\(height)" }
}

struct MediaLibraryFacets: Sendable {
    let markets: [String]
    let resolutions: [PixelSize]
}
