import Foundation
import XCTest
@testable import DailyWallpaper

final class ImageImportServiceTests: XCTestCase {
    func testDuplicateContentIsImportedOnlyOnce() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let destination = base.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // 1x1 静态 PNG，两个不同文件名使用完全相同的内容。
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try png.write(to: source.appendingPathComponent("a.png"))
        try png.write(to: source.appendingPathComponent("b.png"))

        let root = LibraryRoot(id: UUID(), displayName: "test", kind: .defaultPictures, bookmarkData: nil, isActiveWriteRoot: true)
        let resolved = ResolvedLibraryRoot(root: root, url: destination)
        let index = try MediaLibraryIndex(databaseURL: base.appendingPathComponent("library.sqlite"))
        let pendingQueue = try PendingIndexQueue(fileURL: base.appendingPathComponent("pending-index.json"))
        let service = ImageImportService(store: WallpaperStore(), index: index, pendingIndexQueue: pendingQueue)
        let summary = await service.importURLs(
            [source],
            label: "Imported",
            destinationRoot: resolved,
            availableRootURLs: [root.id: destination],
            progressHandler: { _ in }
        )

        XCTAssertEqual(summary.progress.imported, 1)
        XCTAssertEqual(summary.progress.duplicates, 1)
        await index.close()
    }
}
