import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum ThumbnailError: LocalizedError {
    case generationFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .generationFailed: "无法生成缩略图"
        case .cancelled: "缩略图请求已取消"
        }
    }
}

@MainActor
final class ThumbnailService {
    typealias Completion = @MainActor (Result<NSImage, Error>) -> Void

    private struct PendingRequest {
        let token: UUID
        let fileURL: URL
        let cacheKey: String
        let size: CGSize
        let scale: CGFloat
        let completion: Completion
    }

    private let generator: QLThumbnailGenerator
    private let cache = NSCache<NSString, NSImage>()
    private let diskCache: ThumbnailDiskCache
    private var pending: [PendingRequest] = []
    private var running: [UUID: QLThumbnailGenerator.Request] = [:]
    private var diskLookupTasks: [UUID: Task<Void, Never>] = [:]
    private var completions: [UUID: Completion] = [:]
    private var cacheKeys: [UUID: String] = [:]

    init(
        generator: QLThumbnailGenerator = .shared,
        fileManager: FileManager = .default
    ) {
        self.generator = generator
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let cacheDirectory = base
            .appendingPathComponent(AppConstants.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent(AppConstants.thumbnailCacheFolderName, isDirectory: true)
        diskCache = ThumbnailDiskCache(directory: cacheDirectory)
        cache.totalCostLimit = AppConstants.thumbnailMemoryLimit
        let diskCache = self.diskCache
        Task { await diskCache.trimIfNeeded() }
    }

    @discardableResult
    func requestThumbnail(
        fileURL: URL,
        contentSHA256: String,
        size: CGSize,
        scale: CGFloat,
        completion: @escaping Completion
    ) -> UUID {
        let token = UUID()
        let pixelWidth = max(1, min(Int(size.width * scale), 640))
        let pixelHeight = max(1, min(Int(size.height * scale), 640))
        let key = "\(contentSHA256)-\(pixelWidth)x\(pixelHeight)"

        if let image = cache.object(forKey: key as NSString) {
            completion(.success(image))
            return token
        }
        let request = PendingRequest(
            token: token,
            fileURL: fileURL,
            cacheKey: key,
            size: CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale),
            scale: scale,
            completion: completion
        )
        let diskCache = self.diskCache
        diskLookupTasks[token] = Task { [weak self] in
            let data = await diskCache.data(forKey: key)
            guard let self, !Task.isCancelled else { return }
            diskLookupTasks.removeValue(forKey: token)
            if let data, let image = NSImage(data: data) {
                cache.setObject(image, forKey: key as NSString, cost: pixelWidth * pixelHeight * 4)
                completion(.success(image))
            } else {
                pending.append(request)
                drainQueue()
            }
        }
        return token
    }

    func cancel(_ token: UUID) {
        if let task = diskLookupTasks.removeValue(forKey: token) {
            task.cancel()
            return
        }
        if let index = pending.firstIndex(where: { $0.token == token }) {
            pending.remove(at: index)
            return
        }
        if let request = running.removeValue(forKey: token) {
            generator.cancel(request)
            completions.removeValue(forKey: token)?(.failure(ThumbnailError.cancelled))
            cacheKeys.removeValue(forKey: token)
            drainQueue()
        }
    }

    func close() {
        diskLookupTasks.values.forEach { $0.cancel() }
        diskLookupTasks.removeAll()
        pending.removeAll()
        for request in running.values { generator.cancel(request) }
        running.removeAll()
        completions.removeAll()
        cacheKeys.removeAll()
        cache.removeAllObjects()
    }

    private func drainQueue() {
        while running.count < 2, !pending.isEmpty {
            let pendingRequest = pending.removeFirst()
            let request = QLThumbnailGenerator.Request(
                fileAt: pendingRequest.fileURL,
                size: pendingRequest.size,
                scale: pendingRequest.scale,
                representationTypes: .thumbnail
            )
            running[pendingRequest.token] = request
            completions[pendingRequest.token] = pendingRequest.completion
            cacheKeys[pendingRequest.token] = pendingRequest.cacheKey

            generator.generateBestRepresentation(for: request) { [weak self] representation, error in
                let cgImage = representation?.cgImage
                Task { @MainActor [weak self] in
                    self?.finish(token: pendingRequest.token, cgImage: cgImage, error: error)
                }
            }
        }
    }

    private func finish(token: UUID, cgImage: CGImage?, error: Error?) {
        running.removeValue(forKey: token)
        let completion = completions.removeValue(forKey: token)
        let key = cacheKeys.removeValue(forKey: token)

        if let cgImage, let key {
            let image = NSImage(cgImage: cgImage, size: .zero)
            cache.setObject(image, forKey: key as NSString, cost: cgImage.width * cgImage.height * 4)
            let diskCache = self.diskCache
            Task { await diskCache.storePNG(cgImage, forKey: key) }
            completion?(.success(image))
        } else {
            completion?(.failure(error ?? ThumbnailError.generationFailed))
        }
        drainQueue()
    }

}

private actor ThumbnailDiskCache {
    private let directory: URL
    private let fileManager = FileManager()
    private var knownTotalSize: Int64?

    init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: fileURL(forKey: key), options: .mappedIfSafe)
    }

    func storePNG(_ image: CGImage, forKey key: String) {
        guard let data = pngData(for: image) else { return }
        let url = fileURL(forKey: key)
        let previousSize = fileSize(at: url)
        let previousTotal = knownTotalSize ?? calculateTotalSize()
        do {
            try data.write(to: url, options: .atomic)
            let total = previousTotal - previousSize + Int64(data.count)
            knownTotalSize = max(0, total)
            if total > AppConstants.thumbnailDiskLimit {
                trimIfNeeded()
            }
        } catch {
            return
        }
    }

    func trimIfNeeded() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            files.append((url, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        knownTotalSize = total
        guard total > AppConstants.thumbnailDiskLimit else { return }
        for file in files.sorted(by: { $0.date < $1.date }) {
            do {
                try fileManager.removeItem(at: file.url)
                total -= file.size
            } catch {
                continue
            }
            if total <= AppConstants.thumbnailDiskLimit { break }
        }
        knownTotalSize = max(0, total)
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("png")
    }

    private func fileSize(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func calculateTotalSize() -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func pngData(for image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
