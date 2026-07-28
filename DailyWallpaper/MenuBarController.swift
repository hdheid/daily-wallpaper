import AppKit
import ImageIO

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    var onOpenLibrary: (() -> Void)?
    var onImportImages: (() -> Void)?
    var onOpenPreferences: (() -> Void)?

    private let settings: SettingsStore
    private let displayRegistry: DisplayRegistry
    private let directoryManager: DownloadDirectoryManager
    private let coordinator: UpdateCoordinator
    private let launchService: LaunchAtLoginService

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let displayItem = NSMenuItem(title: "显示器：正在识别", action: nil, keyEquivalent: "")
    private let statusTextItem = NSMenuItem(title: "状态：等待更新", action: nil, keyEquivalent: "")
    private let lastUpdateItem = NSMenuItem(title: "最后更新：尚未更新", action: nil, keyEquivalent: "")
    private let titleItem = NSMenuItem(title: "Daily Wallpaper", action: nil, keyEquivalent: "")
    private let copyrightItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let downloadItem = NSMenuItem(title: "立即下载今日图片", action: #selector(downloadNow), keyEquivalent: "")
    private let downloadAndApplyItem = NSMenuItem(title: "立即下载并更换", action: #selector(downloadAndApplyNow), keyEquivalent: "r")
    private let autoDownloadItem = NSMenuItem(title: "每日自动下载", action: #selector(toggleAutomaticDownload), keyEquivalent: "")
    private let autoApplyItem = NSMenuItem(title: "每日自动更换", action: #selector(toggleAutomaticApply), keyEquivalent: "")
    private let launchItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let previewItem = NSMenuItem()
    private let previewImageView = NSImageView()
    private var cachedPreviewURL: URL?
    private var cachedPreviewImage: NSImage?

    init(
        settings: SettingsStore,
        displayRegistry: DisplayRegistry,
        directoryManager: DownloadDirectoryManager,
        coordinator: UpdateCoordinator,
        launchService: LaunchAtLoginService
    ) {
        self.settings = settings
        self.displayRegistry = displayRegistry
        self.directoryManager = directoryManager
        self.coordinator = coordinator
        self.launchService = launchService
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        buildMenu()
        refresh()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .dailyWallpaperSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .dailyWallpaperDisplaysDidChange,
            object: nil
        )
    }

    func update(_ status: UpdateStatus) {
        statusTextItem.title = "状态：\(status.message)"
        downloadItem.isEnabled = !status.isBusy
        downloadAndApplyItem.isEnabled = !status.isBusy
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: status.isBusy ? "arrow.triangle.2.circlepath" : "photo.on.rectangle.angled",
                accessibilityDescription: status.message
            )
        }
        setBusyAnimation(status.isBusy)
        refreshCurrentImage()
    }

    /// 忙碌时菜单栏图标持续旋转，直观提示后台任务进行中。
    private func setBusyAnimation(_ isBusy: Bool) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        if isBusy, !DesignTokens.reduceMotion {
            guard layer.animation(forKey: "busySpin") == nil else { return }
            // 旋转需要以中心为锚点，同步修正 position 避免图标偏移。
            let frame = layer.frame
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: frame.midX, y: frame.midY)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * CGFloat.pi
            spin.duration = 1.1
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            layer.add(spin, forKey: "busySpin")
        } else {
            layer.removeAnimation(forKey: "busySpin")
        }
    }

    func shutdown() {
        NotificationCenter.default.removeObserver(self)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func buildMenu() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Daily Wallpaper")
            button.image?.isTemplate = true
            button.toolTip = "Daily Wallpaper"
        }

        menu.delegate = self
        titleItem.isEnabled = false
        titleItem.attributedTitle = NSAttributedString(
            string: "Daily Wallpaper",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        )
        [displayItem, statusTextItem, lastUpdateItem, copyrightItem].forEach { $0.isEnabled = false }

        // 当前壁纸缩略图预览：非交互信息项，菜单打开时按需刷新。
        let previewContainer = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 128))
        previewImageView.frame = NSRect(x: 14, y: 4, width: 212, height: 120)
        previewImageView.autoresizingMask = [.width]
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = 6
        previewImageView.layer?.masksToBounds = true
        previewContainer.addSubview(previewImageView)
        previewItem.view = previewContainer
        previewItem.isEnabled = false

        downloadItem.target = self
        downloadAndApplyItem.target = self
        autoDownloadItem.target = self
        autoApplyItem.target = self
        launchItem.target = self

        menu.addItem(titleItem)
        menu.addItem(previewItem)
        menu.addItem(displayItem)
        menu.addItem(statusTextItem)
        menu.addItem(lastUpdateItem)
        menu.addItem(copyrightItem)
        menu.addItem(.separator())
        downloadItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        downloadAndApplyItem.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
        menu.addItem(downloadItem)
        menu.addItem(downloadAndApplyItem)

        let libraryItem = NSMenuItem(title: "打开媒体库", action: #selector(openLibrary), keyEquivalent: "l")
        libraryItem.target = self
        libraryItem.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: nil)
        menu.addItem(libraryItem)
        let importItem = NSMenuItem(title: "导入图片…", action: #selector(importImages), keyEquivalent: "i")
        importItem.target = self
        importItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        menu.addItem(importItem)
        let directoryItem = NSMenuItem(title: "打开下载目录", action: #selector(openDownloadDirectory), keyEquivalent: "")
        directoryItem.target = self
        directoryItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(directoryItem)
        let currentItem = NSMenuItem(title: "打开当前图片", action: #selector(openCurrentImage), keyEquivalent: "")
        currentItem.target = self
        currentItem.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        menu.addItem(currentItem)
        let revealItem = NSMenuItem(title: "在访达中显示当前图片", action: #selector(revealCurrentImage), keyEquivalent: "")
        revealItem.target = self
        revealItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        menu.addItem(revealItem)

        menu.addItem(.separator())
        menu.addItem(autoDownloadItem)
        menu.addItem(autoApplyItem)
        let preferencesItem = NSMenuItem(title: "设置…", action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        preferencesItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(preferencesItem)
        menu.addItem(launchItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Daily Wallpaper", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func refresh() {
        let displays = displayRegistry.refresh()
        displayItem.title = "显示器：\(displays.count) 台 · \(settings.configurationMode.localizedName)"
        autoDownloadItem.state = settings.automaticDailyDownloadEnabled ? .on : .off
        autoApplyItem.state = settings.automaticDailyApplyEnabled ? .on : .off
        autoApplyItem.isEnabled = settings.automaticDailyDownloadEnabled
        launchItem.state = launchService.status == .enabled ? .on : .off
        launchItem.toolTip = launchService.status == .requiresApproval ? "需要在系统设置的登录项中批准" : nil
        if let date = settings.lastSuccessfulUpdateAt {
            lastUpdateItem.title = "最后更新：\(Self.dateFormatter.string(from: date))"
        } else {
            lastUpdateItem.title = "最后更新：尚未更新"
        }
        refreshCurrentImage()
    }

    private func refreshCurrentImage() {
        guard let record = settings.currentImageByDisplayUUID.values.sorted(by: { $0.updatedAt > $1.updatedAt }).first else {
            copyrightItem.isHidden = true
            previewItem.isHidden = true
            return
        }
        let text = record.copyrightText.isEmpty ? record.title : record.copyrightText
        copyrightItem.title = String(text.prefix(90))
        copyrightItem.toolTip = text
        copyrightItem.isHidden = text.isEmpty
        refreshPreviewThumbnail()
    }

    /// 菜单顶部的当前壁纸缩略图；按 URL 缓存，避免每次开菜单都重新解码大图。
    private func refreshPreviewThumbnail() {
        guard let url = currentImageURL() else {
            previewItem.isHidden = true
            return
        }
        if url != cachedPreviewURL {
            cachedPreviewImage = Self.downsampledImage(at: url, maxPixelSize: 480)
            cachedPreviewURL = url
        }
        previewImageView.image = cachedPreviewImage
        previewItem.isHidden = cachedPreviewImage == nil
    }

    private nonisolated static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    private func currentImageURL() -> URL? {
        guard let record = settings.currentImageByDisplayUUID.values.sorted(by: { $0.updatedAt > $1.updatedAt }).first else { return nil }
        return try? directoryManager.imageURL(rootID: record.rootID, relativePath: record.relativeImagePath)
    }

    @objc private func settingsChanged() { refresh() }
    @objc private func downloadNow() { coordinator.trigger(.manualDownload) }
    @objc private func downloadAndApplyNow() { coordinator.trigger(.manualDownloadAndApply) }
    @objc private func openLibrary() { onOpenLibrary?() }
    @objc private func importImages() { onImportImages?() }
    @objc private func openPreferences() { onOpenPreferences?() }

    @objc private func openDownloadDirectory() {
        guard let root = try? directoryManager.ensureActiveRoot() else { return }
        NSWorkspace.shared.open(root.url)
    }

    @objc private func openCurrentImage() {
        guard let url = currentImageURL() else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealCurrentImage() {
        guard let url = currentImageURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func toggleAutomaticDownload() {
        settings.automaticDailyDownloadEnabled.toggle()
        refresh()
    }

    @objc private func toggleAutomaticApply() {
        settings.automaticDailyApplyEnabled.toggle()
        refresh()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try launchService.setEnabled(launchService.status != .enabled)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
