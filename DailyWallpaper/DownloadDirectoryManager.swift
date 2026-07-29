import AppKit
import Foundation

enum DownloadDirectoryError: LocalizedError {
    case picturesDirectoryUnavailable
    case noActiveRoot
    case rootNotFound
    case bookmarkUnavailable
    case securityScopeDenied
    case notDirectory
    case notWritable
    case rootInUse
    case unsafeArchivePath
    case archiveItemNotRegularFile

    var errorDescription: String? {
        switch self {
        case .picturesDirectoryUnavailable: "无法找到系统图片目录"
        case .noActiveRoot: "没有可用的下载目录"
        case .rootNotFound: "媒体库目录记录不存在"
        case .bookmarkUnavailable: "自定义目录授权已失效"
        case .securityScopeDenied: "macOS 拒绝访问自定义目录"
        case .notDirectory: "所选路径不是可用目录"
        case .notWritable: "所选目录当前不可写"
        case .rootInUse: "目录正在执行下载或导入，暂时不能移除"
        case .unsafeArchivePath: "归档路径包含符号链接或超出媒体库目录"
        case .archiveItemNotRegularFile: "归档目标不是常规文件"
        }
    }
}

struct LibraryRootStatus: Sendable {
    let root: LibraryRoot
    let url: URL?
    let isAvailable: Bool
}

@MainActor
final class DownloadDirectoryManager {
    private let settings: SettingsStore
    private let fileManager: FileManager
    private var activeSecurityScopedURLs: [UUID: URL] = [:]
    private var writeLeaseCounts: [UUID: Int] = [:]

    init(settings: SettingsStore, fileManager: FileManager = .default) {
        self.settings = settings
        self.fileManager = fileManager
    }

    func ensureActiveRoot() throws -> ResolvedLibraryRoot {
        if settings.libraryRoots.isEmpty {
            let root = LibraryRoot.defaultRoot()
            settings.libraryRoots = [root]
            settings.activeArchiveRootID = root.id
        }

        guard let activeID = settings.activeArchiveRootID else {
            throw DownloadDirectoryError.noActiveRoot
        }
        return try resolve(rootID: activeID, createIfNeeded: true)
    }

    func resolve(rootID: UUID, createIfNeeded: Bool = false) throws -> ResolvedLibraryRoot {
        guard var root = settings.libraryRoots.first(where: { $0.id == rootID }) else {
            throw DownloadDirectoryError.rootNotFound
        }

        let authorizedURL: URL
        var startedSecurityScope = false
        switch root.kind {
        case .defaultPictures:
            guard let pictures = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first else {
                throw DownloadDirectoryError.picturesDirectoryUnavailable
            }
            authorizedURL = pictures.appendingPathComponent(AppConstants.defaultArchiveFolderName, isDirectory: true)
        case .securityScoped:
            guard let data = root.bookmarkData else { throw DownloadDirectoryError.bookmarkUnavailable }
            var stale = false
            authorizedURL = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if activeSecurityScopedURLs[root.id] == nil {
                guard authorizedURL.startAccessingSecurityScopedResource() else {
                    throw DownloadDirectoryError.securityScopeDenied
                }
                activeSecurityScopedURLs[root.id] = authorizedURL
                startedSecurityScope = true
            }
            if stale {
                root.bookmarkData = try makeBookmark(for: authorizedURL)
                replace(root)
            }
        }

        do {
            let url = try validatedDirectoryURL(authorizedURL, createIfNeeded: createIfNeeded)
            return ResolvedLibraryRoot(root: root, url: url)
        } catch {
            if startedSecurityScope {
                activeSecurityScopedURLs.removeValue(forKey: root.id)?.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    func addCustomRoot(url: URL) throws -> ResolvedLibraryRoot {
        let bookmark = try makeBookmark(for: url)
        var stale = false
        let authorizedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard authorizedURL.startAccessingSecurityScopedResource() else {
            throw DownloadDirectoryError.securityScopeDenied
        }
        var keepSecurityScope = false
        defer {
            if !keepSecurityScope { authorizedURL.stopAccessingSecurityScopedResource() }
        }
        let validatedURL = try validatedDirectoryURL(authorizedURL, createIfNeeded: true)
        try verifyWritable(validatedURL)

        // 目录和授权全部验证成功后才提交设置，失败不会破坏原活动目录。
        var roots = settings.libraryRoots.map { existing -> LibraryRoot in
            var value = existing
            value.isActiveWriteRoot = false
            return value
        }
        let root = LibraryRoot(
            id: UUID(),
            displayName: url.lastPathComponent,
            kind: .securityScoped,
            bookmarkData: bookmark,
            isActiveWriteRoot: true
        )
        roots.append(root)
        settings.libraryRoots = roots
        settings.activeArchiveRootID = root.id
        activeSecurityScopedURLs[root.id] = authorizedURL
        keepSecurityScope = true
        return ResolvedLibraryRoot(root: root, url: validatedURL)
    }

    func restoreDefaultRoot() throws -> ResolvedLibraryRoot {
        var roots = settings.libraryRoots
        let defaultRoot: LibraryRoot
        if let index = roots.firstIndex(where: { $0.kind == .defaultPictures }) {
            defaultRoot = roots[index]
        } else {
            defaultRoot = LibraryRoot.defaultRoot()
            roots.append(defaultRoot)
        }

        guard let pictures = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            throw DownloadDirectoryError.picturesDirectoryUnavailable
        }
        let defaultURL = pictures.appendingPathComponent(AppConstants.defaultArchiveFolderName, isDirectory: true)
        let validatedURL = try validatedDirectoryURL(defaultURL, createIfNeeded: true)
        try verifyWritable(validatedURL)

        for index in roots.indices {
            roots[index].isActiveWriteRoot = roots[index].id == defaultRoot.id
        }
        settings.libraryRoots = roots
        settings.activeArchiveRootID = defaultRoot.id
        guard let committedRoot = roots.first(where: { $0.id == defaultRoot.id }) else {
            throw DownloadDirectoryError.rootNotFound
        }
        return ResolvedLibraryRoot(root: committedRoot, url: validatedURL)
    }

    @discardableResult
    func removeRoot(id: UUID) throws -> LibraryRoot {
        guard settings.activeArchiveRootID != id else {
            throw DownloadDirectoryError.noActiveRoot
        }
        guard writeLeaseCounts[id, default: 0] == 0 else {
            throw DownloadDirectoryError.rootInUse
        }
        guard let removed = settings.libraryRoots.first(where: { $0.id == id }) else {
            throw DownloadDirectoryError.rootNotFound
        }
        // 安全作用域保留到进程退出，避免已取得路径的短任务在删除设置后突然失去权限。
        settings.libraryRoots.removeAll { $0.id == id }
        return removed
    }

    func restoreRemovedRoot(_ root: LibraryRoot) {
        guard !settings.libraryRoots.contains(where: { $0.id == root.id }) else { return }
        var restored = root
        restored.isActiveWriteRoot = false
        settings.libraryRoots.append(restored)
    }

    func beginWriteLease(rootID: UUID) throws {
        guard settings.libraryRoots.contains(where: { $0.id == rootID }) else {
            throw DownloadDirectoryError.rootNotFound
        }
        writeLeaseCounts[rootID, default: 0] += 1
    }

    func endWriteLease(rootID: UUID) {
        let remaining = writeLeaseCounts[rootID, default: 0] - 1
        if remaining > 0 {
            writeLeaseCounts[rootID] = remaining
        } else {
            writeLeaseCounts.removeValue(forKey: rootID)
        }
    }

    func statuses() -> [LibraryRootStatus] {
        settings.libraryRoots.map { root in
            do {
                let resolved = try resolve(rootID: root.id)
                return LibraryRootStatus(root: root, url: resolved.url, isAvailable: true)
            } catch {
                return LibraryRootStatus(root: root, url: nil, isAvailable: false)
            }
        }
    }

    func imageURL(rootID: UUID, relativePath: String) throws -> URL {
        let root = try resolve(rootID: rootID)
        let canonicalRoot = root.url.resolvingSymlinksInPath().standardizedFileURL
        let candidate = canonicalRoot
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isDescendant(candidate, of: canonicalRoot) else {
            throw WallpaperStoreError.archivePathOutsideRoot
        }
        return candidate
    }

    /// 删除专用路径解析：不跟随任何子目录符号链接，并拒绝把目录当作图片移入废纸篓。
    func deletableFileURL(rootID: UUID, relativePath: String) throws -> URL {
        let root = try resolve(rootID: rootID)
        let canonicalRoot = root.url.resolvingSymlinksInPath().standardizedFileURL
        let candidate = canonicalRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard isDescendant(candidate, of: canonicalRoot) else {
            throw DownloadDirectoryError.unsafeArchivePath
        }

        let rootComponents = canonicalRoot.pathComponents
        let relativeComponents = candidate.pathComponents.dropFirst(rootComponents.count)
        guard !relativeComponents.isEmpty else { throw DownloadDirectoryError.unsafeArchivePath }

        var current = canonicalRoot
        for (offset, component) in relativeComponents.enumerated() {
            current.appendPathComponent(component)
            // 路径尚不存在时没有文件可删除；仍返回经过词法防越界校验的目标位置。
            guard fileManager.fileExists(atPath: current.path) else { return candidate }
            let attributes = try fileManager.attributesOfItem(atPath: current.path)
            guard let type = attributes[.type] as? FileAttributeType else {
                throw DownloadDirectoryError.archiveItemNotRegularFile
            }
            guard type != .typeSymbolicLink else { throw DownloadDirectoryError.unsafeArchivePath }

            let isFinalComponent = offset == relativeComponents.count - 1
            if isFinalComponent {
                guard type == .typeRegular else {
                    throw DownloadDirectoryError.archiveItemNotRegularFile
                }
            } else {
                guard type == .typeDirectory else {
                    throw DownloadDirectoryError.unsafeArchivePath
                }
            }
        }
        return candidate
    }

    func shutdown() {
        for url in activeSecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
        writeLeaseCounts.removeAll()
    }

    private func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func replace(_ root: LibraryRoot) {
        var roots = settings.libraryRoots
        guard let index = roots.firstIndex(where: { $0.id == root.id }) else { return }
        roots[index] = root
        settings.libraryRoots = roots
    }

    private func validatedDirectoryURL(_ url: URL, createIfNeeded: Bool) throws -> URL {
        if createIfNeeded {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try canonical.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw DownloadDirectoryError.notDirectory }
        return canonical
    }

    private func verifyWritable(_ directory: URL) throws {
        let probe = directory.appendingPathComponent(".dailywallpaper-write-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: probe) }
        do {
            try Data().write(to: probe, options: .atomic)
        } catch {
            throw DownloadDirectoryError.notWritable
        }
    }

    private func isDescendant(_ child: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let childComponents = child.pathComponents
        return childComponents.count > rootComponents.count
            && childComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }
}
