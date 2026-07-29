import Foundation

struct BingArchiveResponse: Decodable, Sendable {
    let images: [BingImageCandidate]?
}

struct BingImageCandidate: Codable, Hashable, Sendable {
    let startDate: String?
    let endDate: String?
    let urlPath: String
    let urlBase: String
    let copyrightText: String
    let title: String
    let wallpaperAllowed: Bool
    let providerHash: String?

    enum CodingKeys: String, CodingKey {
        case startDate = "startdate"
        case endDate = "enddate"
        case urlPath = "url"
        case urlBase = "urlbase"
        case copyrightText = "copyright"
        case title
        case wallpaperAllowed = "wp"
        case providerHash = "hsh"
    }

    init(
        startDate: String?,
        endDate: String? = nil,
        urlPath: String,
        urlBase: String,
        copyrightText: String,
        title: String,
        wallpaperAllowed: Bool,
        providerHash: String?
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.urlPath = urlPath
        self.urlBase = urlBase
        self.copyrightText = copyrightText
        self.title = title
        self.wallpaperAllowed = wallpaperAllowed
        self.providerHash = providerHash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startDate = try container.decodeIfPresent(String.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(String.self, forKey: .endDate)
        urlPath = try container.decode(String.self, forKey: .urlPath)
        urlBase = try container.decode(String.self, forKey: .urlBase)
        copyrightText = try container.decodeIfPresent(String.self, forKey: .copyrightText) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "必应每日图片"
        // 字段缺失必须按 false 处理，不能意外下载服务端未授权的图片。
        wallpaperAllowed = try container.decodeIfPresent(Bool.self, forKey: .wallpaperAllowed) ?? false
        providerHash = try container.decodeIfPresent(String.self, forKey: .providerHash)
    }
}

struct DownloadedRemoteImage: Sendable {
    let temporaryFileURL: URL
    let sourceURL: URL
    let mimeType: String
    let statusCode: Int
}

protocol BingImageProviding: Sendable {
    func fetchCandidate(market: String) async throws -> BingImageCandidate
    func download(candidate: BingImageCandidate, variant: ImageVariant) async throws -> DownloadedRemoteImage
    func releaseIdleResources()
}

extension BingImageProviding {
    func releaseIdleResources() {}
}
