import Foundation
import XCTest
@testable import DailyWallpaper

final class WallpaperStoreTests: XCTestCase {
    func testStreamingSHA256MatchesKnownValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("value.txt")
        try Data("abc".utf8).write(to: file)

        XCTAssertEqual(
            try ImageFileUtilities.sha256(url: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSanitizedPathComponentRejectsSeparators() {
        XCTAssertEqual(ImageFileUtilities.sanitizedPathComponent("../../zh/CN", fallback: "Imported"), "zhCN")
        XCTAssertEqual(ImageFileUtilities.sanitizedPathComponent("***", fallback: "Imported"), "Imported")
    }

    func testDownloadedImageIsArchivedByDateMarketAndActualResolution() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = base.appendingPathComponent("archive", isDirectory: true)
        let sourceURL = base.appendingPathComponent("download.tmp")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try png.write(to: sourceURL)
        let root = LibraryRoot(id: UUID(), displayName: "test", kind: .defaultPictures, bookmarkData: nil, isActiveWriteRoot: true)
        let candidate = BingImageCandidate(
            startDate: "20260726",
            urlPath: "/sample.png",
            urlBase: "/sample",
            copyrightText: "copyright",
            title: "title",
            wallpaperAllowed: true,
            providerHash: "provider"
        )

        let stored = try await WallpaperStore().archiveDownloaded(
            DownloadArchiveRequest(
                temporaryFileURL: sourceURL,
                sourceURL: URL(string: "https://www.bing.com/sample.png")!,
                mimeType: "image/png",
                candidate: candidate,
                requestedMarket: "zh-CN",
                recordedAt: Date()
            ),
            in: ResolvedLibraryRoot(root: root, url: rootURL)
        )

        XCTAssertTrue(stored.imageURL.path.contains("/2026/07/26/zh-CN/1x1/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.imageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.metadataURL.path))
        XCTAssertEqual(stored.metadata.pixelWidth, 1)
        XCTAssertEqual(stored.metadata.pixelHeight, 1)
        XCTAssertEqual(stored.metadata.dateSource, "bingStartDate")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testCorruptedExistingArchiveIsReplacedByValidatedDownload() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = base.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let root = LibraryRoot(id: UUID(), displayName: "test", kind: .defaultPictures, bookmarkData: nil, isActiveWriteRoot: true)
        let resolvedRoot = ResolvedLibraryRoot(root: root, url: rootURL)
        let store = WallpaperStore()
        let firstSource = base.appendingPathComponent("first.png")
        try samplePNG.write(to: firstSource)
        let first = try await store.archiveDownloaded(
            downloadRequest(fileURL: firstSource),
            in: resolvedRoot
        )

        try Data("broken".utf8).write(to: first.imageURL, options: .atomic)
        let secondSource = base.appendingPathComponent("second.png")
        try samplePNG.write(to: secondSource)
        let repaired = try await store.archiveDownloaded(
            downloadRequest(fileURL: secondSource),
            in: resolvedRoot
        )

        XCTAssertEqual(try ImageFileUtilities.sha256(url: repaired.imageURL), repaired.metadata.contentSHA256)
        XCTAssertEqual(try ImageFileUtilities.inspect(url: repaired.imageURL).pixelWidth, 1)
    }

    func testArchiveRejectsSymbolicLinkDirectoryEscape() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rootURL = base.appendingPathComponent("archive", isDirectory: true)
        let outsideURL = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: rootURL.appendingPathComponent("2026"),
            withDestinationURL: outsideURL
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("source.png")
        try samplePNG.write(to: source)
        let root = LibraryRoot(id: UUID(), displayName: "test", kind: .defaultPictures, bookmarkData: nil, isActiveWriteRoot: true)
        do {
            _ = try await WallpaperStore().archiveDownloaded(
                downloadRequest(fileURL: source),
                in: ResolvedLibraryRoot(root: root, url: rootURL)
            )
            XCTFail("归档不应跟随根目录内的符号链接")
        } catch WallpaperStoreError.archivePathOutsideRoot {
            XCTAssertFalse(FileManager.default.fileExists(atPath: outsideURL.appendingPathComponent("07").path))
        }
    }

    private var samplePNG: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    private func downloadRequest(fileURL: URL) -> DownloadArchiveRequest {
        DownloadArchiveRequest(
            temporaryFileURL: fileURL,
            sourceURL: URL(string: "https://www.bing.com/sample.png")!,
            mimeType: "image/png",
            candidate: BingImageCandidate(
                startDate: "20260726",
                urlPath: "/sample.png",
                urlBase: "/sample",
                copyrightText: "copyright",
                title: "title",
                wallpaperAllowed: true,
                providerHash: "provider"
            ),
            requestedMarket: "zh-CN",
            recordedAt: Date()
        )
    }
}
