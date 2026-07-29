import AppKit

/// 将历史窗口位置收敛到当前屏幕的可见区域。
/// 纯函数便于覆盖异常 autosave 数据，不读取或写入任何系统偏好。
func constrainedWindowFrame(
    _ proposedFrame: NSRect,
    inside visibleFrame: NSRect,
    minimumSize: NSSize,
    defaultSize: NSSize = NSSize(width: 1_120, height: 740)
) -> NSRect {
    let visibleValues = [
        visibleFrame.minX,
        visibleFrame.minY,
        visibleFrame.width,
        visibleFrame.height
    ]
    guard visibleValues.allSatisfy(\.isFinite), visibleFrame.width > 0, visibleFrame.height > 0 else {
        return proposedFrame
    }

    let minimumWidth = min(max(1, minimumSize.width), visibleFrame.width)
    let minimumHeight = min(max(1, minimumSize.height), visibleFrame.height)
    let fallbackWidth = min(max(minimumWidth, defaultSize.width), visibleFrame.width)
    let fallbackHeight = min(max(minimumHeight, defaultSize.height), visibleFrame.height)

    var frame = proposedFrame
    let proposedValues = [frame.minX, frame.minY, frame.width, frame.height]
    if !proposedValues.allSatisfy(\.isFinite) || frame.width <= 0 || frame.height <= 0 {
        // 历史数据损坏时使用默认大小，并在当前屏幕内居中。
        frame = NSRect(
            x: visibleFrame.midX - fallbackWidth / 2,
            y: visibleFrame.midY - fallbackHeight / 2,
            width: fallbackWidth,
            height: fallbackHeight
        )
    }

    frame.size.width = min(max(frame.width, minimumWidth), visibleFrame.width)
    frame.size.height = min(max(frame.height, minimumHeight), visibleFrame.height)
    frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
    frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
    return frame
}

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
    var onDeleteLibraryItem: ((MediaLibraryItem) async throws -> Void)?
    var onRemoveLibraryRoot: ((UUID) async throws -> Void)?
    var onClose: (() -> Void)?

    private let index: MediaLibraryIndex
    private let settings: SettingsStore
    private let displayRegistry: DisplayRegistry
    private let directoryManager: DownloadDirectoryManager
    private let launchService: LaunchAtLoginService

    private let sidebarController = MainSidebarViewController()
    private let contentHostController = MainContentHostViewController()
    private lazy var statusToast = ToastPresenter(hostView: contentHostController.view, bottomOffset: 68)
    private var libraryController: MediaLibraryViewController?
    private var preferencesController: PreferencesViewController?
    private var downloadToolbarItem: NSToolbarItem?
    private var downloadAndApplyToolbarItem: NSToolbarItem?
    private var importToolbarItem: NSToolbarItem?
    private var selectedSection: MainWindowSection = .library
    private var isUpdateInProgress = false
    private var isImportInProgress = false
    private var isLibraryDeletionInProgress = false
    private var hasPositionedWindow = false
    private var isShutDown = false
    private var lastStatusMessage = "等待更新"

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
        let frameAutosaveName = "DailyWallpaper.MainWindow"
        window.setFrameAutosaveName(frameAutosaveName)
        // 恢复只执行一次，避免首次 show() 再次套用旧值并覆盖尺寸修正。
        let didRestoreFrame = window.setFrameUsingName(frameAutosaveName)
        if didRestoreFrame, let screen = window.screen ?? NSScreen.main {
            let restoredFrame = constrainedWindowFrame(
                window.frame,
                inside: screen.visibleFrame,
                minimumSize: window.minSize
            )
            window.setFrame(restoredFrame, display: false)
        }
        hasPositionedWindow = didRestoreFrame

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
        if !hasPositionedWindow {
            window?.center()
        }
        hasPositionedWindow = true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(_ status: UpdateStatus) {
        isUpdateInProgress = status.isBusy
        sidebarController.update(status)
        if status.message != lastStatusMessage {
            lastStatusMessage = status.message
            presentStatusToast(status)
        }
        let canUpdate = !status.isBusy && !isLibraryDeletionInProgress
        downloadToolbarItem?.isEnabled = canUpdate
        downloadAndApplyToolbarItem?.isEnabled = canUpdate
        libraryController?.setWallpaperActionsEnabled(canUpdate)
        refreshDirectoryChangeAvailability()
    }

    func setImportInProgress(_ isInProgress: Bool) {
        isImportInProgress = isInProgress
        importToolbarItem?.isEnabled = !isInProgress && !isLibraryDeletionInProgress
        libraryController?.setImportInProgress(isInProgress)
        refreshDirectoryChangeAvailability()
    }

    func setLibraryDeletionInProgress(_ isInProgress: Bool) {
        isLibraryDeletionInProgress = isInProgress
        let canUpdate = !isUpdateInProgress && !isInProgress
        downloadToolbarItem?.isEnabled = canUpdate
        downloadAndApplyToolbarItem?.isEnabled = canUpdate
        importToolbarItem?.isEnabled = !isImportInProgress && !isInProgress
        libraryController?.setWallpaperActionsEnabled(canUpdate)
        libraryController?.setLibraryDeletionInProgress(isInProgress)
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
        statusToast.dismiss(immediately: true)
        libraryController?.shutdown()
        preferencesController?.shutdown()
        contentHostController.clear()
        libraryController = nil
        preferencesController = nil
    }

    private func select(_ section: MainWindowSection) {
        guard !isShutDown else { return }
        statusToast.dismiss(immediately: true)

        // 先完整准备并替换目标页面，再提交侧栏状态和释放旧页资源。
        // 这样首次创建设置页时，不会短暂留下已经 suspend 的媒体库空壳。
        switch section {
        case .library:
            let controller = makeLibraryController()
            contentHostController.show(controller)
            controller.resume()
        case .displays, .downloads, .automation:
            let controller = makePreferencesController(initialSection: section)
            controller.show(section: section)
            contentHostController.show(controller)
            // 目标页已经可见后再释放媒体库资源，避免构造期间显示半完成的旧页面。
            libraryController?.suspend()
        }

        selectedSection = section
        sidebarController.setSelectedSection(section)
    }

    private func makeLibraryController() -> MediaLibraryViewController {
        if let libraryController { return libraryController }
        let controller = MediaLibraryViewController(
            index: index,
            directoryManager: directoryManager,
            displayRegistry: displayRegistry,
            settings: settings
        )
        controller.onImportRequested = { [weak self] in self?.onImportRequested?() }
        controller.onSetWallpaper = { [weak self] item, displayUUIDs in
            self?.onSetWallpaper?(item, displayUUIDs)
        }
        controller.onDeleteRequested = { [weak self] item in
            guard let self, let handler = self.onDeleteLibraryItem else { throw CancellationError() }
            try await handler(item)
        }
        controller.setWallpaperActionsEnabled(!isUpdateInProgress)
        controller.setImportInProgress(isImportInProgress)
        controller.setLibraryDeletionInProgress(isLibraryDeletionInProgress)
        libraryController = controller
        return controller
    }

    private func makePreferencesController(initialSection: MainWindowSection) -> PreferencesViewController {
        if let preferencesController { return preferencesController }
        let controller = PreferencesViewController(
            settings: settings,
            displayRegistry: displayRegistry,
            directoryManager: directoryManager,
            launchService: launchService,
            initialSection: initialSection
        )
        controller.onRemoveLibraryRoot = { [weak self] rootID in
            guard let self, let handler = self.onRemoveLibraryRoot else { return }
            try await handler(rootID)
        }
        controller.setDirectoryChangesEnabled(!(
            isUpdateInProgress || isImportInProgress || isLibraryDeletionInProgress
        ))
        preferencesController = controller
        return controller
    }

    private func refreshDirectoryChangeAvailability() {
        preferencesController?.setDirectoryChangesEnabled(!(
            isUpdateInProgress || isImportInProgress || isLibraryDeletionInProgress
        ))
    }

    /// 更新阶段改用内容区底部的玻璃提示，不再依赖侧栏角落里的小号状态文字。
    private func presentStatusToast(_ status: UpdateStatus) {
        let style: ToastPresenter.Style = switch status.phase {
        case .success: .success
        case .failed: .failure
        case .idle, .checking, .downloading, .applying: .info
        }
        statusToast.show(status.message, style: style, duration: status.isBusy ? 2.4 : 3.2)
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
        switch itemIdentifier {
        case .downloadToday:
            item.label = "下载今日图片"
            item.toolTip = "下载今日图片到媒体库"
            item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: item.toolTip)
            item.target = self
            item.action = #selector(downloadPressed)
            item.isEnabled = !isUpdateInProgress && !isLibraryDeletionInProgress
            downloadToolbarItem = item
        case .downloadAndApply:
            item.label = "下载并应用"
            item.toolTip = "下载今日图片并应用为壁纸"
            item.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: item.toolTip)
            item.target = self
            item.action = #selector(downloadAndApplyPressed)
            item.isEnabled = !isUpdateInProgress && !isLibraryDeletionInProgress
            downloadAndApplyToolbarItem = item
        case .importImages:
            item.label = "导入图片"
            item.toolTip = "从外部文件或文件夹导入图片"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: item.toolTip)
            item.target = self
            item.action = #selector(importPressed)
            item.isEnabled = !isImportInProgress && !isLibraryDeletionInProgress
            importToolbarItem = item
        default:
            return nil
        }
        // 使用 macOS 标准无边框工具栏图标，避免三个常用命令都套一层重复的圆形底板。
        item.isBordered = false
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

        // 先强制加载目标视图，再移除旧页；整个替换发生在同一个主线程事件中。
        // 原生侧栏导航采用即时切换，避免透明层、双重动画和旧页面残影。
        let targetView = controller.view
        targetView.alphaValue = 1
        targetView.translatesAutoresizingMaskIntoConstraints = false
        for child in children where child !== controller && child !== previousController {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        previousController?.view.removeFromSuperview()
        previousController?.removeFromParent()

        if controller.parent !== self {
            addChild(controller)
        }
        if targetView.superview !== view {
            view.addSubview(targetView)
            NSLayoutConstraint.activate([
                // 全尺寸标题栏下，右侧内容必须从安全区域开始，避免页面标题和说明被工具栏覆盖。
                targetView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                targetView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                targetView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                targetView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
            ])
        }
        visibleController = controller
        // 约束激活已经会安排布局；同步强制布局可能重入 AppKit 当前布局事务。
        view.needsLayout = true
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

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.setAccessibilityLabel("正在更新壁纸")

        let header = NSStackView(views: [appIcon, titleStack, headerSpacer, progressIndicator])
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

        background.addSubview(header)
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: background.safeAreaLayoutGuide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: background.safeAreaLayoutGuide.bottomAnchor, constant: -12)
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
        if status.isBusy {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
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
