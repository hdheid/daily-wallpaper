import Foundation

enum DisplayConfigurationMode: String, Codable, CaseIterable, Sendable {
    case shared
    case individual

    var localizedName: String {
        switch self {
        case .shared: "全部显示器相同"
        case .individual: "每个显示器独立"
        }
    }
}

enum WallpaperResolutionPreference: String, Codable, CaseIterable, Sendable {
    case automatic
    case original
    case uhd

    var localizedName: String {
        switch self {
        case .automatic: "自动"
        case .original: "原始"
        case .uhd: "UHD"
        }
    }
}

enum ImageVariant: String, Codable, CaseIterable, Sendable {
    case original
    case uhd
}

enum WallpaperScaling: String, Codable, CaseIterable, Sendable {
    case fill
    case fit

    var localizedName: String {
        switch self {
        case .fill: "填充"
        case .fit: "适应"
        }
    }
}

struct WallpaperProfile: Codable, Hashable, Sendable {
    var market: String
    var resolutionPreference: WallpaperResolutionPreference
    var scaling: WallpaperScaling
    var automaticApplyEnabled: Bool

    static let `default` = WallpaperProfile(
        market: "zh-CN",
        resolutionPreference: .automatic,
        scaling: .fill,
        automaticApplyEnabled: true
    )

    /// 市场代码最终会进入 URL 和目录名，只接受常见的 BCP-47 安全字符。
    var normalizedMarket: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filtered = market.unicodeScalars.filter { allowed.contains($0) }
        let value = String(String.UnicodeScalarView(filtered))
        return value.isEmpty ? "zh-CN" : value
    }
}

struct DisplayDescriptor: Codable, Hashable, Identifiable, Sendable {
    var id: String { uuid }
    let uuid: String
    let localizedName: String
    let isMain: Bool
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let isConnected: Bool
}

struct ResolvedProfileRequest: Hashable, Sendable {
    let profile: WallpaperProfile
    let variant: ImageVariant
    let targetDisplayUUIDs: [String]

    /// 指纹刻意不包含显示器 UUID，相同配置的多个屏幕因此只下载一次。
    var fingerprint: String {
        "v1|\(profile.normalizedMarket.lowercased())|\(variant.rawValue)|latest-wp"
    }
}

enum UpdateTrigger: String, Sendable {
    case startup
    case calendarDayChanged
    case wake
    case sessionActive
    case timeZoneChanged
    case clockChanged
    case screensChanged
    case settingsChanged
    case spaceChanged
    case manualDownload
    case manualDownloadAndApply

    var isManual: Bool {
        self == .manualDownload || self == .manualDownloadAndApply
    }

    var shouldApplyDownloadedImage: Bool {
        self == .manualDownloadAndApply
    }
}

struct CurrentWallpaperRecord: Codable, Hashable, Sendable {
    let displayUUID: String
    let rootID: UUID
    let relativeImagePath: String
    let contentSHA256: String
    let title: String
    let copyrightText: String
    let scaling: WallpaperScaling
    let updatedAt: Date
}

struct CachedWallpaperRecord: Codable, Hashable, Sendable {
    let configurationFingerprint: String
    let rootID: UUID
    let relativeImagePath: String
    let contentSHA256: String
    let title: String
    let copyrightText: String
    let cachedAt: Date
}

enum LocalDay {
    static func key(for date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
