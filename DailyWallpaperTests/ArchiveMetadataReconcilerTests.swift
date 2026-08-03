import Foundation
import XCTest
@testable import DailyWallpaper

final class ArchiveMetadataReconcilerTests: XCTestCase {
    func testReconcilerRestoresLocalizedSidecarsHiddenByLegacyIndex() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = base.appendingPathComponent("archive", isDirectory: true)
        let sourceURL = base.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try png.write(to: sourceURL)

        let root = LibraryRoot(
            id: UUID(),
            displayName: "test",
            kind: .defaultPictures,
            bookmarkData: nil,
            isActiveWriteRoot: true
        )
        let resolvedRoot = ResolvedLibraryRoot(root: root, url: rootURL)
        let store = WallpaperStore()
        let chinese = try await store.archiveDownloaded(
            request(fileURL: sourceURL, market: "zh-CN", title: "中文标题"),
            in: resolvedRoot
        )
        let english = try await store.archiveDownloaded(
            candidate: candidate(title: "English title"),
            reusing: chinese,
            requestedMarket: "en-US",
            recordedAt: Date(),
            in: resolvedRoot
        )

        let index = try MediaLibraryIndex(databaseURL: base.appendingPathComponent("library.sqlite"))
        _ = try await index.upsert(chinese.metadata)
        _ = try await ArchiveMetadataReconciler().reconcile(root: resolvedRoot, index: index)
        let count = try await index.count()
        let englishPage = try await index.page(query: MediaLibraryQuery(market: "en-US"))
        await index.close()

        XCTAssertEqual(count, 2)
        XCTAssertEqual(englishPage.items.first?.id != nil, true)
        XCTAssertEqual(englishPage.items.first?.title, english.metadata.title)
    }

    func testReconcilerReportsBrokenArchiveSidecarInsteadOfMarkingScanComplete() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let brokenURL = fixture.stored.metadataURL
            .deletingLastPathComponent()
            .appendingPathComponent(String(repeating: "a", count: 64))
            .appendingPathExtension("json")
        try Data("not-json".utf8).write(to: brokenURL)

        let index = try MediaLibraryIndex(databaseURL: fixture.base.appendingPathComponent("library.sqlite"))
        do {
            _ = try await ArchiveMetadataReconciler().reconcile(root: fixture.root, index: index)
            XCTFail("损坏的应用旁车不应被静默跳过")
        } catch let error as ArchiveMetadataReconciliationError {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertEqual(error.restoredCount, 1)
        }
        let restoredCount = try await index.count()
        XCTAssertEqual(restoredCount, 1)
        await index.close()
    }

    func testReconcilerIgnoresUnrelatedJSONInCustomLibrary() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try Data("not-json".utf8).write(to: fixture.root.url.appendingPathComponent("notes.json"))

        let index = try MediaLibraryIndex(databaseURL: fixture.base.appendingPathComponent("library.sqlite"))
        let restored = try await ArchiveMetadataReconciler().reconcile(root: fixture.root, index: index)
        XCTAssertEqual(restored, 1)
        await index.close()
    }

    func testReconcilerReattachesSidecarFromPreviousRootID() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let replacementRoot = LibraryRoot(
            id: UUID(),
            displayName: "restored",
            kind: .defaultPictures,
            bookmarkData: nil,
            isActiveWriteRoot: true
        )
        let resolvedReplacement = ResolvedLibraryRoot(root: replacementRoot, url: fixture.root.url)
        let index = try MediaLibraryIndex(databaseURL: fixture.base.appendingPathComponent("library.sqlite"))

        let restored = try await ArchiveMetadataReconciler().reconcile(
            root: resolvedReplacement,
            index: index
        )
        let page = try await index.page(query: MediaLibraryQuery())
        await index.close()

        XCTAssertEqual(restored, 1)
        XCTAssertEqual(page.items.first?.rootID, replacementRoot.id)
    }

    func testReconcilerRejectsImageWhoseContentNoLongerMatchesSidecar() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try Data("changed".utf8).write(to: fixture.stored.imageURL)
        let index = try MediaLibraryIndex(databaseURL: fixture.base.appendingPathComponent("library.sqlite"))

        do {
            _ = try await ArchiveMetadataReconciler().reconcile(root: fixture.root, index: index)
            XCTFail("内容已变化的图片不应进入恢复索引")
        } catch let error as ArchiveMetadataReconciliationError {
            XCTAssertNotNil(error.errorDescription)
        }
        let restoredCount = try await index.count()
        XCTAssertEqual(restoredCount, 0)
        await index.close()
    }

    private func makeFixture() async throws -> (
        base: URL,
        root: ResolvedLibraryRoot,
        stored: StoredWallpaper
    ) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = base.appendingPathComponent("archive", isDirectory: true)
        let sourceURL = base.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try png.write(to: sourceURL)
        let root = LibraryRoot(
            id: UUID(),
            displayName: "test",
            kind: .defaultPictures,
            bookmarkData: nil,
            isActiveWriteRoot: true
        )
        let resolvedRoot = ResolvedLibraryRoot(root: root, url: rootURL)
        let stored = try await WallpaperStore().archiveDownloaded(
            request(fileURL: sourceURL, market: "zh-CN", title: "中文标题"),
            in: resolvedRoot
        )
        return (base, resolvedRoot, stored)
    }

    private func request(fileURL: URL, market: String, title: String) -> DownloadArchiveRequest {
        DownloadArchiveRequest(
            temporaryFileURL: fileURL,
            sourceURL: URL(string: "https://www.bing.com/same.png")!,
            mimeType: "image/png",
            candidate: candidate(title: title),
            requestedMarket: market,
            recordedAt: Date()
        )
    }

    private func candidate(title: String) -> BingImageCandidate {
        BingImageCandidate(
            startDate: "20260728",
            endDate: "20260729",
            urlPath: "/same.png",
            urlBase: "/same",
            copyrightText: title + " description",
            title: title,
            wallpaperAllowed: true,
            providerHash: "same-provider"
        )
    }
}
