import Foundation
import OSLog

enum BingImageServiceError: LocalizedError, Equatable {
    case invalidRequest
    case invalidResponse
    case unexpectedStatus(Int)
    case unexpectedContentType(String?)
    case emptyArchive
    case noWallpaperAllowed
    case invalidImageURL
    case responseTooLarge
    case serviceInvalidated

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "无法创建必应请求"
        case .invalidResponse: "必应返回了无法识别的响应"
        case let .unexpectedStatus(code): "必应请求失败（HTTP \(code)）"
        case let .unexpectedContentType(type): "必应返回了非图片内容（\(type ?? "未知类型")）"
        case .emptyArchive: "必应没有返回图片列表"
        case .noWallpaperAllowed: "最近图片均未获准用作壁纸"
        case .invalidImageURL: "必应返回了无效的图片地址"
        case .responseTooLarge: "必应返回的图片超过安全大小限制"
        case .serviceInvalidated: "必应网络服务已关闭"
        }
    }
}

final class BingImageService: BingImageProviding, @unchecked Sendable {
    private static let baseURL = URL(string: "https://www.bing.com")!
    private static let maximumArchiveBytes: Int64 = 1 * 1_024 * 1_024
    private static let maximumImageBytes: Int64 = 100 * 1_024 * 1_024
    private let sessionLock = NSLock()
    private let sessionConfiguration: URLSessionConfiguration?
    private let ownsSession: Bool
    private var activeSession: URLSession?
    private var isPermanentlyInvalidated = false
    private let redirectDelegate: BingRedirectDelegate?
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.liuhao.DailyWallpaper", category: "Bing")

    init(session: URLSession? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        decoder = JSONDecoder()

        if let session {
            activeSession = session
            sessionConfiguration = nil
            ownsSession = false
            redirectDelegate = nil
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.httpMaximumConnectionsPerHost = 1
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 32 * 1_024 * 1_024)
            configuration.requestCachePolicy = .useProtocolCachePolicy
            let redirectDelegate = BingRedirectDelegate()
            self.redirectDelegate = redirectDelegate
            sessionConfiguration = configuration
            ownsSession = true
            activeSession = nil
        }
    }

    func fetchCandidate(market: String) async throws -> BingImageCandidate {
        guard let url = Self.archiveURL(market: market) else {
            throw BingImageServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            try Task.checkCancellation()
            (data, response) = try await urlSession().data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // URLSession 取消通常以 URLError.cancelled 返回，统一成结构化任务取消。
            throw CancellationError()
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BingImageServiceError.invalidResponse
        }
        guard let finalURL = httpResponse.url, Self.isTrustedBingURL(finalURL) else {
            throw BingImageServiceError.invalidImageURL
        }
        guard
            httpResponse.expectedContentLength <= Self.maximumArchiveBytes,
            data.count <= Self.maximumArchiveBytes
        else { throw BingImageServiceError.responseTooLarge }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw BingImageServiceError.unexpectedStatus(httpResponse.statusCode)
        }

        let archive = try decoder.decode(BingArchiveResponse.self, from: data)
        guard let images = archive.images, !images.isEmpty else {
            throw BingImageServiceError.emptyArchive
        }
        guard let candidate = images.first(where: \.wallpaperAllowed) else {
            throw BingImageServiceError.noWallpaperAllowed
        }
        return candidate
    }

    func download(candidate: BingImageCandidate, variant: ImageVariant) async throws -> DownloadedRemoteImage {
        let urls = try Self.downloadURLs(for: candidate, variant: variant)
        var lastError: Error?

        // UHD 地址没有正式契约，因此 UHD 失败时必须自动回退到响应原始地址。
        for url in urls {
            try Task.checkCancellation()
            do {
                return try await downloadSingleURL(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
                logger.warning("图片候选下载失败，将尝试下一个地址：\(url.absoluteString, privacy: .public)")
            }
        }
        throw lastError ?? BingImageServiceError.invalidImageURL
    }

    func invalidate() {
        // 退出时进入终态：清空当前会话后，后续请求也不得重新创建网络连接。
        let session = takeActiveSession(permanentlyInvalidating: true)
        session?.invalidateAndCancel()
    }

    func releaseIdleResources() {
        guard ownsSession else { return }
        let session = takeActiveSession(permanentlyInvalidating: false)
        session?.finishTasksAndInvalidate()
    }

    static func archiveURL(market: String) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("HPImageArchive.aspx"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "format", value: "js"),
            URLQueryItem(name: "idx", value: "0"),
            URLQueryItem(name: "n", value: "8"),
            URLQueryItem(name: "mkt", value: WallpaperProfile(
                market: market,
                resolutionPreference: .automatic,
                scaling: .fill,
                automaticApplyEnabled: true
            ).normalizedMarket)
        ]
        return components?.url
    }

    static func downloadURLs(for candidate: BingImageCandidate, variant: ImageVariant) throws -> [URL] {
        guard let original = trustedBingURL(path: candidate.urlPath) else {
            throw BingImageServiceError.invalidImageURL
        }
        guard variant == .uhd else { return [original] }

        let uhdPath = candidate.urlBase + "_UHD.jpg"
        guard let uhd = trustedBingURL(path: uhdPath), uhd != original else {
            return [original]
        }
        return [uhd, original]
    }

    private static func trustedBingURL(path: String) -> URL? {
        let url = URL(string: path, relativeTo: baseURL)?.absoluteURL
        guard let url, isTrustedBingURL(url) else { return nil }
        return url
    }

    static func isTrustedBingURL(_ url: URL) -> Bool {
        guard
            url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(),
            host == "bing.com" || host.hasSuffix(".bing.com")
        else { return false }
        return true
    }

    private func downloadSingleURL(_ url: URL) async throws -> DownloadedRemoteImage {
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        let (systemTemporaryURL, response) = try await urlSession().download(for: request)
        defer { try? fileManager.removeItem(at: systemTemporaryURL) }
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BingImageServiceError.invalidResponse
        }
        guard let finalURL = httpResponse.url, Self.isTrustedBingURL(finalURL) else {
            throw BingImageServiceError.invalidImageURL
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw BingImageServiceError.unexpectedStatus(httpResponse.statusCode)
        }

        let mimeType = httpResponse.mimeType?.lowercased()
        guard let mimeType, mimeType.hasPrefix("image/") else {
            throw BingImageServiceError.unexpectedContentType(httpResponse.mimeType)
        }
        if httpResponse.expectedContentLength > Self.maximumImageBytes {
            throw BingImageServiceError.responseTooLarge
        }
        let actualSize = Int64(
            (try? systemTemporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        guard actualSize <= Self.maximumImageBytes else {
            throw BingImageServiceError.responseTooLarge
        }

        // URLSession 的下载位置生命周期很短，返回调用方前先移动到应用自有临时目录。
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DailyWallpaper-Network", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let stableTemporaryURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("download")
        try? fileManager.removeItem(at: stableTemporaryURL)
        try fileManager.moveItem(at: systemTemporaryURL, to: stableTemporaryURL)

        return DownloadedRemoteImage(
            temporaryFileURL: stableTemporaryURL,
            sourceURL: finalURL,
            mimeType: mimeType,
            statusCode: httpResponse.statusCode
        )
    }

    private func urlSession() throws -> URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard !isPermanentlyInvalidated else {
            throw BingImageServiceError.serviceInvalidated
        }
        if let activeSession { return activeSession }
        guard let sessionConfiguration else {
            throw BingImageServiceError.serviceInvalidated
        }
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        activeSession = session
        return session
    }

    private func takeActiveSession(permanentlyInvalidating: Bool) -> URLSession? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if permanentlyInvalidating {
            isPermanentlyInvalidated = true
        }
        let session = activeSession
        activeSession = nil
        return session
    }
}

private final class BingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // 重定向必须留在 HTTPS Bing 域名内，避免在下载完成后才发现来源越界。
        completionHandler(request.url.map(BingImageService.isTrustedBingURL) == true ? request : nil)
    }
}
