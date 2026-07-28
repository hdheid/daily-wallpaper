import XCTest
@testable import DailyWallpaper

final class BingImageServiceTests: XCTestCase {
    func testMissingWPDefaultsToFalse() throws {
        let data = #"{"images":[{"startdate":"20260726","url":"/th?id=x.jpg","urlbase":"/th?id=x","copyright":"c","title":"t"}]}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BingArchiveResponse.self, from: data)
        XCTAssertEqual(response.images?.first?.wallpaperAllowed, false)
    }

    func testSelectsOnlyExplicitlyAllowedCandidate() throws {
        let data = #"{"images":[{"url":"/first.jpg","urlbase":"/first","wp":false},{"url":"/second.jpg","urlbase":"/second","wp":true}]}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BingArchiveResponse.self, from: data)
        XCTAssertEqual(response.images?.first(where: \.wallpaperAllowed)?.urlPath, "/second.jpg")
    }

    func testUHDURLFallsBackToOriginal() throws {
        let candidate = BingImageCandidate(
            startDate: "20260726",
            urlPath: "/th?id=sample_1920x1080.jpg&pid=hp",
            urlBase: "/th?id=sample",
            copyrightText: "",
            title: "",
            wallpaperAllowed: true,
            providerHash: nil
        )
        let urls = try BingImageService.downloadURLs(for: candidate, variant: .uhd)
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[0].absoluteString.contains("sample_UHD.jpg"))
        XCTAssertTrue(urls[1].absoluteString.contains("sample_1920x1080.jpg"))
    }

    func testArchiveRequestContainsExpectedParameters() throws {
        let url = try XCTUnwrap(BingImageService.archiveURL(market: "zh-CN"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["format"], "js")
        XCTAssertEqual(values["idx"], "0")
        XCTAssertEqual(values["n"], "8")
        XCTAssertEqual(values["mkt"], "zh-CN")
    }

    func testTrustedDownloadURLRejectsLookalikeHostsAndPlainHTTP() {
        XCTAssertTrue(BingImageService.isTrustedBingURL(URL(string: "https://www.bing.com/image.jpg")!))
        XCTAssertTrue(BingImageService.isTrustedBingURL(URL(string: "https://cn.bing.com/image.jpg")!))
        XCTAssertFalse(BingImageService.isTrustedBingURL(URL(string: "https://bing.com.evil.example/image.jpg")!))
        XCTAssertFalse(BingImageService.isTrustedBingURL(URL(string: "http://www.bing.com/image.jpg")!))
    }
}
