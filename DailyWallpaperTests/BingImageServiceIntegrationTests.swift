import Foundation
import XCTest
@testable import DailyWallpaper

final class BingImageServiceIntegrationTests: XCTestCase {
    func testFetchChoosesFirstAllowedImage() async throws {
        let session = makeSession { request in
            let json = #"{"images":[{"url":"/blocked.jpg","urlbase":"/blocked","wp":false},{"url":"/allowed.jpg","urlbase":"/allowed","title":"allowed","wp":true}]}"#
            return (200, "application/json", Data(json.utf8))
        }
        let candidate = try await BingImageService(session: session).fetchCandidate(market: "zh-CN")
        XCTAssertEqual(candidate.urlPath, "/allowed.jpg")
    }

    func testNullImagesIsRejectedDespiteHTTP200() async throws {
        let session = makeSession { _ in (200, "application/json", Data(#"{"images":null}"#.utf8)) }
        do {
            _ = try await BingImageService(session: session).fetchCandidate(market: "zh-CN")
            XCTFail("应拒绝空图片列表")
        } catch let error as BingImageServiceError {
            XCTAssertEqual(error, .emptyArchive)
        }
    }

    func testUHDFailureFallsBackToOriginalURL() async throws {
        let session = makeSession { request in
            if request.url?.absoluteString.contains("_UHD.jpg") == true {
                return (404, "image/jpeg", Data())
            }
            return (200, "image/jpeg", Data("image-body".utf8))
        }
        let candidate = BingImageCandidate(
            startDate: "20260726",
            urlPath: "/original.jpg",
            urlBase: "/wallpaper",
            copyrightText: "",
            title: "",
            wallpaperAllowed: true,
            providerHash: nil
        )
        let downloaded = try await BingImageService(session: session).download(candidate: candidate, variant: .uhd)
        defer { try? FileManager.default.removeItem(at: downloaded.temporaryFileURL) }
        XCTAssertTrue(downloaded.sourceURL.absoluteString.hasSuffix("/original.jpg"))
        XCTAssertEqual(try Data(contentsOf: downloaded.temporaryFileURL), Data("image-body".utf8))
    }

    func testHTMLResponseIsRejected() async throws {
        let session = makeSession { _ in (200, "text/html", Data("<html></html>".utf8)) }
        let candidate = BingImageCandidate(
            startDate: nil,
            urlPath: "/not-image.jpg",
            urlBase: "/not-image",
            copyrightText: "",
            title: "",
            wallpaperAllowed: true,
            providerHash: nil
        )
        do {
            _ = try await BingImageService(session: session).download(candidate: candidate, variant: .original)
            XCTFail("应拒绝 HTML 正文")
        } catch let error as BingImageServiceError {
            XCTAssertEqual(error, .unexpectedContentType("text/html"))
        }
    }

    func testReleaseIdleResourcesDoesNotInvalidateInjectedSession() async throws {
        let session = makeSession { _ in
            let json = #"{"images":[{"url":"/allowed.jpg","urlbase":"/allowed","wp":true}]}"#
            return (200, "application/json", Data(json.utf8))
        }
        let service = BingImageService(session: session)

        // 单元测试和未来调用方注入的会话不归服务所有，批次收尾不能替调用方释放。
        service.releaseIdleResources()
        let candidate = try await service.fetchCandidate(market: "zh-CN")
        XCTAssertEqual(candidate.urlPath, "/allowed.jpg")
    }

    func testInvalidateIsTerminalAndDoesNotStartAnotherRequest() async throws {
        let requestCount = LockedRequestCounter()
        let session = makeSession { _ in
            requestCount.increment()
            let json = #"{"images":[{"url":"/allowed.jpg","urlbase":"/allowed","wp":true}]}"#
            return (200, "application/json", Data(json.utf8))
        }
        let service = BingImageService(session: session)

        service.invalidate()
        do {
            _ = try await service.fetchCandidate(market: "zh-CN")
            XCTFail("终态失效后不应重新创建会话")
        } catch let error as BingImageServiceError {
            XCTAssertEqual(error, .serviceInvalidated)
        }
        XCTAssertEqual(requestCount.value, 0)
    }

    func testFetchConvertsCancelledURLErrorToCancellationError() async throws {
        let session = makeSession { _ in throw URLError(.cancelled) }
        let service = BingImageService(session: session)

        do {
            _ = try await service.fetchCandidate(market: "zh-CN")
            XCTFail("URLSession 取消应作为任务取消继续向上传播")
        } catch is CancellationError {
            // 符合预期。
        }
    }

    private func makeSession(
        handler: @escaping @Sendable (URLRequest) throws -> (Int, String, Data)
    ) -> URLSession {
        let identifier = UUID().uuidString
        MockURLProtocol.register(identifier: identifier, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Daily-Wallpaper-Test": identifier]
        return URLSession(configuration: configuration)
    }
}

private final class LockedRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, String, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(identifier: String, handler: @escaping Handler) {
        lock.lock()
        handlers[identifier] = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard
            let identifier = request.value(forHTTPHeaderField: "X-Daily-Wallpaper-Test"),
            let url = request.url
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let handler = Self.handlers[identifier]
        Self.lock.unlock()

        do {
            guard let handler else { throw URLError(.resourceUnavailable) }
            let (status, mimeType, data) = try handler(request)
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": mimeType]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
