import AppKit

enum MainWindowSection: Int, CaseIterable {
    case library
    case displays
    case downloads
    case automation

    var title: String {
        switch self {
        case .library: "媒体库"
        case .displays: "显示器"
        case .downloads: "下载目录"
        case .automation: "自动化"
        }
    }

    var symbolName: String {
        switch self {
        case .library: "photo.stack"
        case .displays: "display.2"
        case .downloads: "externaldrive"
        case .automation: "clock.arrow.circlepath"
        }
    }
}

/// 应用的唯一前台窗口。业务对象仍由 AppDelegate 统一创建，这里只负责展示和路由。
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    var onDownloadRequested: (() -> Void)?
    var onDownloadAndApplyRequested: (() -> Void)?
    var onImportRequested: (() -> Void)?
    var onSetWallpaper: ((MediaLibraryItem, [String]?) -> Void)?
    var onRemoveLibraryRoot: ((UUID) async throws -> Void)?
    var onClose: (() -> Void)?

    private let index: MediaLibraryIndex
    private let settings: SettingsStore
    private let displayRegistry: DisplayRegistry
    private let directoryManager: DownloadDirectoryManager
    private let launchService: LaunchAtLoginService

    private let sidebarController = MainSidebarViewController()
    private let contentHostController = MainContentHostViewController()
    private var libraryController: MediaLibraryViewController?
    private var preferencesController: PreferencesViewController?
    private var downloadToolbarItem: NSToolbarItem?
    private var downloadAndApplyToolbarItem: NSToolbarItem?
    private var importToolbarItem: NSToolbarItem?
    private var selectedSection: MainWindowSection = .library
    private var isUpdateInProgress = false
    private var isImportInProgress = false
    private var hasCenteredWindow = false
    private var isShutDown = false

    init(
        index: MediaLibraryIndex,
        settings: SettingsStore,
        displayRegistry: DisplayRegistry,
        directoryManager: DownloadDirectoryManager,
        launchService: LaunchAtLoginService
    ) {
        self.index = index
        self.settings = settings
        self.displayRegistry = displayRegistry
        self.directoryManager = directoryManager
        self.launchService = launchService

        let splitController = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 196
        sidebarItem.maximumThickness = 236
        sidebarItem.canCollapse = false
        splitController.addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: contentHostController)
        contentItem.minimumThickness = 780
        splitController.addSplitViewItem(contentItem)
        splitController.splitView.dividerStyle = .thin

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppConstants.displayName
        // 品牌名仍作为窗口语义标题保留，但不在工具栏上方重复显示英文。
        window.titleVisibility = .hidden
        window.contentViewController = splitController
        window.minSize = NSSize(width: 1_000, height: 600)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .automatic

        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("DailyWallpaper.MainWindow")

        let toolbar = NSToolbar(identifier: "DailyWallpaper.MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        sidebarController.onSelectionChange = { [weak self] section in
            self?.select(section)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(section: MainWindowSection? = nil) {
        select(section ?? selectedSection)
        if !hasCenteredWindow, window?.setFrameUsingName("DailyWallpaper.MainWindow") != true {
            window?.center()
        }
        hasCenteredWindow = true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(_ status: UpdateStatus) {
        isUpdateInProgress = status.isBusy
        sidebarController.update(status)
        downloadToolbarItem?.isEnabled = !status.isBusy
        downloadAndApplyToolbarItem?.isEnabled = !status.isBusy
        libraryController?.setWallpaperActionsEnabled(!status.isBusy)
        refreshDirectoryChangeAvailability()
    }

    func setImportInProgress(_ isInProgress: Bool) {
        isImportInProgress = isInProgress
        importToolbarItem?.isEnabled = !isInProgress
        libraryController?.setImportInProgress(isInProgress)
        refreshDirectoryChangeAvailability()
    }

    func windowWillClose(_ notification: Notification) {
        shutdown()
        onClose?()
    }

    /// 窗口关闭后不保留图片列表、分页任务和缩略图缓存，后台仅剩轻量调度对象。
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        sidebarController.onSelectionChange = nil
        libraryController?.shutdown()
        preferencesController?.shutdown()
        contentHostController.clear()
        libraryController = nil
        preferencesController = nil
    }

    private func select(_ section: MainWindowSection) {
        guard !isShutDown else { return }
        selectedSection = section
        sidebarController.setSelectedSection(section)

        switch section {
        case .library:
            let controller = makeLibraryController()
            controller.resume()
            contentHostController.show(controller)
        case .displays, .downloads, .automation:
            // 设置页不需要保留图片解码缓存；切离媒体库即释放，返回时再按页加载。
            libraryController?.suspend()
            let controller = makePreferencesController()
            controller.show(section: section)
            contentHostController.show(controller)
        }
    }

    private func makeLibraryController() -> MediaLibraryViewController {
        if let libraryController { return libraryController }
        let controller = MediaLibraryViewController(
            index: index,
            directoryManager: directoryManager,
            displayRegistry: displayRegistry
        )
        controller.onImportRequested = { [weak self] in self?.onImportRequested?() }
        controller.onSetWallpaper = { [weak self] item, displayUUIDs in
            self?.onSetWallpaper?(item, displayUUIDs)
        }
        controller.setWallpaperActionsEnabled(!isUpdateInProgress)
        controller.setImportInProgress(isImportInProgress)
        libraryController = controller
        return controller
    }

    private func makePreferencesController() -> PreferencesViewController {
        if let preferencesController { return preferencesController }
        let controller = PreferencesViewController(
            settings: settings,
            displayRegistry: displayRegistry,
            directoryManager: directoryManager,
            launchService: launchService
        )
        controller.onRemoveLibraryRoot = { [weak self] rootID in
            guard let self, let handler = self.onRemoveLibraryRoot else { return }
            try await handler(rootID)
        }
        controller.setDirectoryChangesEnabled(!(isUpdateInProgress || isImportInProgress))
        preferencesController = controller
        return controller
    }

    private func refreshDirectoryChangeAvailability() {
        preferencesController?.setDirectoryChangesEnabled(!(isUpdateInProgress || isImportInProgress))
    }

    @objc private func downloadPressed() { onDownloadRequested?() }
    @objc private func downloadAndApplyPressed() { onDownloadAndApplyRequested?() }
    @objc private func importPressed() { onImportRequested?() }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace, .downloadToday, .downloadAndApply, .importImages]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace, .downloadToday, .downloadAndApply, .importImages]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.isBordered = true
        switch itemIdentifier {
        case .downloadToday:
            item.label = "下载今日图片"
            item.toolTip = "下载今日图片到媒体库"
            item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: item.toolTip)
            item.target = self
            item.action = #selector(downloadPressed)
            item.isEnabled = !isUpdateInProgress
            downloadToolbarItem = item
        case .downloadAndApply:
            item.label = "下载并应用"
            item.toolTip = "下载今日图片并应用为壁纸"
            item.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: item.toolTip)
            item.target = self
            item.action = #selector(downloadAndApplyPressed)
            item.isEnabled = !isUpdateInProgress
            downloadAndApplyToolbarItem = item
        case .importImages:
            item.label = "导入图片"
            item.toolTip = "从外部文件或文件夹导入图片"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: item.toolTip)
            item.target = self
            item.action = #selector(importPressed)
            item.isEnabled = !isImportInProgress
            importToolbarItem = item
        default:
            return nil
        }
        return item
    }
}

private extension NSToolbarItem.Identifier {
    static let downloadToday = NSToolbarItem.Identifier("DailyWallpaper.Toolbar.DownloadToday")
    static let downloadAndApply = NSToolbarItem.Identifier("DailyWallpaper.Toolbar.DownloadAndApply")
    static let importImages = NSToolbarItem.Identifier("DailyWallpaper.Toolbar.ImportImages")
}

@MainActor
private final class MainContentHostViewController: NSViewController {
    private var visibleController: NSViewController?

    override func loadView() {
        view = NSView()
    }

    func show(_ controller: NSViewController) {
        guard visibleController !== controller else { return }
        let previousController = visibleController
        // 快速连续切页时，先清掉仍在淡出中的历史页面。
        for child in children where child !== controller && child !== previousController {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        if controller.parent !== self {
            addChild(controller)
        }
        if controller.view.superview !== view {
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(controller.view)
            NSLayoutConstraint.activate([
                // 全尺寸标题栏下，右侧内容必须从安全区域开始，避免页面标题和说明被工具栏覆盖。
                controller.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                controller.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
            ])
        }
        visibleController = controller

        // 新旧页面交叉淡入淡出，避免切页时的生硬跳变。
        guard let previousController, !DesignTokens.reduceMotion else {
            previousController?.view.removeFromSuperview()
            previousController?.removeFromParent()
            controller.view.alphaValue = 1
            return
        }
        controller.view.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DesignTokens.animationNormal
            controller.view.animator().alphaValue = 1
            previousController.view.animator().alphaValue = 0
        }, completionHandler: {
            // 动画回调在主线程触发，用 assumeIsolated 满足 @Sendable 回调的隔离检查。
            MainActor.assumeIsolated {
                previousController.view.alphaValue = 1
                guard previousController !== self.visibleController else { return }
                previousController.view.removeFromSuperview()
                previousController.removeFromParent()
            }
        })
    }

    func clear() {
        visibleController?.view.removeFromSuperview()
        visibleController?.removeFromParent()
        visibleController = nil
    }
}

@MainActor
private final class MainSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelectionChange: ((MainWindowSection) -> Void)?

    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "等待更新")
    private let progressIndicator = NSProgressIndicator()
    private var isUpdatingSelection = false

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        view = background

        let appIcon = NSImageView(image: NSImage(
            systemSymbolName: "photo.stack",
            accessibilityDescription: AppConstants.displayName
        ) ?? NSImage())
        appIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        appIcon.contentTintColor = .controlAccentColor
        appIcon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let titleLabel = NSTextField(labelWithString: AppConstants.displayName)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let subtitleLabel = NSTextField(labelWithString: "壁纸与媒体库")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1

        let header = NSStackView(views: [appIcon, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9
        header.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Navigation"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 34
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.allowsEmptySelection = false
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.setAccessibilityLabel("主导航")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setAccessibilityLabel("更新状态")
        let footer = NSStackView(views: [progressIndicator, statusLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 7
        footer.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(header)
        background.addSubview(scrollView)
        background.addSubview(footer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: background.safeAreaLayoutGuide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: background.safeAreaLayoutGuide.bottomAnchor, constant: -14)
        ])
        setSelectedSection(.library)
    }

    func setSelectedSection(_ section: MainWindowSection) {
        _ = view
        guard tableView.selectedRow != section.rawValue else { return }
        isUpdatingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: section.rawValue), byExtendingSelection: false)
        tableView.scrollRowToVisible(section.rawValue)
        isUpdatingSelection = false
    }

    func update(_ status: UpdateStatus) {
        if statusLabel.stringValue != status.message {
            setStatusMessage(status.message)
        }
        if status.isBusy {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    /// 状态文字变化时淡出淡入，避免文案瞬间跳变。
    private func setStatusMessage(_ message: String) {
        guard !DesignTokens.reduceMotion else {
            statusLabel.stringValue = message
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DesignTokens.animationFast
            self.statusLabel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.statusLabel.stringValue = message
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = DesignTokens.animationFast
                    self.statusLabel.animator().alphaValue = 1
                }, completionHandler: nil)
            }
        })
    }

    func numberOfRows(in tableView: NSTableView) -> Int { MainWindowSection.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let section = MainWindowSection(rawValue: row) else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(
            systemSymbolName: section.symbolName,
            accessibilityDescription: section.title
        ) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = icon
        cell.textField = label
        cell.addSubview(icon)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection, let section = MainWindowSection(rawValue: tableView.selectedRow) else { return }
        onSelectionChange?(section)
    }
}
