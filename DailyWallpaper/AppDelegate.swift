import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let displayRegistry = DisplayRegistry()
    private let store = WallpaperStore()
    private let bingService = BingImageService()
    private let retryTimer = RetryTimer()
    private let eventMonitor = AutomationEventMonitor()
    private let launchService = LaunchAtLoginService()

    private lazy var directoryManager = DownloadDirectoryManager(settings: settings)
    private var mediaIndex: MediaLibraryIndex?
    private var pendingIndexQueue: PendingIndexQueue?
    private var coordinator: UpdateCoordinator?
    private var menuBarController: MenuBarController?
    private var mainWindowController: MainWindowController?
    private var downloadMenuItem: NSMenuItem?
    private var downloadAndApplyMenuItem: NSMenuItem?
    private var importMenuItem: NSMenuItem?
    private var importProgressWindowController: ImportProgressWindowController?
    private var importTask: Task<Void, Never>?
    private var pendingIndexReconciliationTask: Task<Void, Never>?
    private var pendingIndexReconciliationID: UUID?
    private var libraryRootRemovalTasks: [UUID: Task<Void, Error>] = [:]
    private var importService: ImageImportService?
    private var terminationTask: Task<Void, Never>?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            configureApplicationMenu()
            let databaseURL = try MediaLibraryIndex.defaultDatabaseURL()
            let index = try MediaLibraryIndex(databaseURL: databaseURL)
            let pendingQueue = try PendingIndexQueue(fileURL: PendingIndexQueue.defaultQueueURL())
            mediaIndex = index
            pendingIndexQueue = pendingQueue
            _ = try? directoryManager.ensureActiveRoot()

            let applier = WallpaperApplier(registry: displayRegistry)
            let coordinator = UpdateCoordinator(
                settings: settings,
                displayRegistry: displayRegistry,
                directoryManager: directoryManager,
                bingService: bingService,
                store: store,
                index: index,
                pendingIndexQueue: pendingQueue,
                applier: applier,
                retryTimer: retryTimer
            )
            self.coordinator = coordinator
            settings.onConfigurationChange = { [weak coordinator] in
                coordinator?.trigger(.settingsChanged)
            }
            importService = ImageImportService(store: store, index: index, pendingIndexQueue: pendingQueue)
            reconcilePendingIndexEntries(queue: pendingQueue, index: index)

            let menu = MenuBarController(
                settings: settings,
                displayRegistry: displayRegistry,
                directoryManager: directoryManager,
                coordinator: coordinator,
                launchService: launchService
            )
            menu.onOpenLibrary = { [weak self] in self?.openMainWindow(section: .library) }
            menu.onImportImages = { [weak self] in self?.beginImport() }
            menu.onOpenPreferences = { [weak self] in self?.openMainWindow(section: .displays) }
            menuBarController = menu

            coordinator.onStatusChange = { [weak self, weak menu] status in
                menu?.update(status)
                self?.mainWindowController?.update(status)
                self?.updateCommandAvailability(status)
            }
            eventMonitor.onEvent = { [weak coordinator] trigger in
                coordinator?.trigger(trigger)
            }
            eventMonitor.start()
            openMainWindow(section: .library)
            // 资源测试可通过环境变量禁止启动时联网和更换壁纸，不影响正常用户启动。
            if ProcessInfo.processInfo.environment["DAILY_WALLPAPER_DISABLE_STARTUP_UPDATE"] != "1" {
                coordinator.trigger(.startup)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Daily Wallpaper 无法启动"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        isTerminating = true

        importTask?.cancel()
        pendingIndexReconciliationTask?.cancel()
        eventMonitor.stop()
        retryTimer.cancel()
        bingService.invalidate()
        menuBarController?.shutdown()
        mainWindowController?.shutdown()
        settings.onConfigurationChange = nil

        let pendingImport = importTask
        let pendingReconciliation = pendingIndexReconciliationTask
        let pendingRootRemovals = Array(libraryRootRemovalTasks.values)
        let coordinator = coordinator
        let mediaIndex = mediaIndex
        terminationTask = Task { [weak self, weak sender] in
            await coordinator?.shutdown()
            await pendingImport?.value
            await pendingReconciliation?.value
            for task in pendingRootRemovals {
                _ = try? await task.value
            }
            guard let self else {
                sender?.reply(toApplicationShouldTerminate: true)
                return
            }
            self.importTask = nil
            self.pendingIndexReconciliationTask = nil
            self.pendingIndexReconciliationID = nil
            self.directoryManager.shutdown()
            await mediaIndex?.close()
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 正常退出已在 applicationShouldTerminate 中等待异步任务；这里仅做幂等兜底。
        eventMonitor.stop()
        retryTimer.cancel()
        bingService.invalidate()
        pendingIndexReconciliationTask?.cancel()
        directoryManager.shutdown()
        menuBarController?.shutdown()
        mainWindowController?.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow(section: nil)
        return true
    }

    private func openMainWindow(section: MainWindowSection?) {
        guard !isTerminating else { return }
        if let controller = mainWindowController {
            controller.show(section: section)
            return
        }
        guard let index = mediaIndex else { return }
        let controller = MainWindowController(
            index: index,
            settings: settings,
            displayRegistry: displayRegistry,
            directoryManager: directoryManager,
            launchService: launchService
        )
        controller.onDownloadRequested = { [weak self] in self?.coordinator?.trigger(.manualDownload) }
        controller.onDownloadAndApplyRequested = { [weak self] in self?.coordinator?.trigger(.manualDownloadAndApply) }
        controller.onImportRequested = { [weak self] in self?.beginImport() }
        controller.onSetWallpaper = { [weak self] item, displayUUIDs in
            self?.coordinator?.applyLibraryItem(item, displayUUIDs: displayUUIDs)
        }
        controller.onRemoveLibraryRoot = { [weak self] rootID in
            guard let self else { return }
            try await self.removeLibraryRoot(rootID)
        }
        controller.onClose = { [weak self, weak controller] in
            guard self?.mainWindowController === controller else { return }
            self?.mainWindowController = nil
        }
        mainWindowController = controller
        if let coordinator { controller.update(coordinator.status) }
        controller.setImportInProgress(importTask != nil)
        controller.show(section: section ?? .library)
    }

    /// 进入普通前台应用模式后补齐标准菜单，保证搜索框编辑和常见快捷键走响应链。
    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu(title: AppConstants.displayName)
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let aboutItem = NSMenuItem(
            title: "关于 \(AppConstants.displayName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        applicationMenu.addItem(aboutItem)
        applicationMenu.addItem(.separator())

        let preferencesItem = NSMenuItem(title: "设置…", action: #selector(openPreferencesFromMenu), keyEquivalent: ",")
        preferencesItem.target = self
        applicationMenu.addItem(preferencesItem)
        applicationMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "隐藏 \(AppConstants.displayName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        applicationMenu.addItem(hideItem)
        let hideOthersItem = NSMenuItem(
            title: "隐藏其他应用",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        applicationMenu.addItem(hideOthersItem)
        let showAllItem = NSMenuItem(
            title: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        applicationMenu.addItem(showAllItem)
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出 \(AppConstants.displayName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        applicationMenu.addItem(quitItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        let importItem = NSMenuItem(title: "导入图片…", action: #selector(importFromMenu), keyEquivalent: "i")
        importItem.target = self
        fileMenu.addItem(importItem)
        self.importMenuItem = importItem
        fileMenu.addItem(.separator())
        let downloadItem = NSMenuItem(title: "下载今日图片", action: #selector(downloadFromMenu), keyEquivalent: "d")
        downloadItem.target = self
        fileMenu.addItem(downloadItem)
        self.downloadMenuItem = downloadItem
        let applyItem = NSMenuItem(title: "下载并应用", action: #selector(downloadAndApplyFromMenu), keyEquivalent: "r")
        applyItem.target = self
        fileMenu.addItem(applyItem)
        downloadAndApplyMenuItem = applyItem
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        let bringAllToFrontItem = NSMenuItem(
            title: "前置全部窗口",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        bringAllToFrontItem.target = NSApp
        windowMenu.addItem(bringAllToFrontItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openPreferencesFromMenu() { openMainWindow(section: .displays) }
    @objc private func importFromMenu() { beginImport() }
    @objc private func downloadFromMenu() { coordinator?.trigger(.manualDownload) }
    @objc private func downloadAndApplyFromMenu() { coordinator?.trigger(.manualDownloadAndApply) }

    private func updateCommandAvailability(_ status: UpdateStatus) {
        downloadMenuItem?.isEnabled = !status.isBusy
        downloadAndApplyMenuItem?.isEnabled = !status.isBusy
    }

    private func setImportInProgress(_ isInProgress: Bool) {
        importMenuItem?.isEnabled = !isInProgress
        mainWindowController?.setImportInProgress(isInProgress)
    }

    private func beginImport() {
        guard !isTerminating, importTask == nil, let importService else { return }
        importProgressWindowController?.close()
        importProgressWindowController = nil

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "导入"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let labelField = NSTextField(string: "Imported")
        labelField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let labelAlert = NSAlert()
        labelAlert.messageText = "设置导入标签"
        labelAlert.informativeText = "标签用于媒体库筛选和归档目录名称。"
        labelAlert.accessoryView = labelField
        labelAlert.addButton(withTitle: "开始导入")
        labelAlert.addButton(withTitle: "取消")
        guard labelAlert.runModal() == .alertFirstButtonReturn else { return }

        let destinationRoot: ResolvedLibraryRoot
        do {
            destinationRoot = try directoryManager.ensureActiveRoot()
            try directoryManager.beginWriteLease(rootID: destinationRoot.root.id)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let availableRoots = Dictionary(uniqueKeysWithValues: directoryManager.statuses().compactMap { status in
            status.url.map { (status.root.id, $0) }
        })

        let progressController = ImportProgressWindowController()
        progressController.onCancel = { [weak self] in self?.importTask?.cancel() }
        progressController.onClose = { [weak self, weak progressController] in
            guard self?.importProgressWindowController === progressController else { return }
            self?.importProgressWindowController = nil
        }
        importProgressWindowController = progressController
        progressController.show()

        let selectedURLs = panel.urls
        let label = labelField.stringValue
        importTask = Task { [weak self] in
            let summary = await importService.importURLs(
                selectedURLs,
                label: label,
                destinationRoot: destinationRoot,
                availableRootURLs: availableRoots,
                progressHandler: { progress in
                    Task { @MainActor [weak progressController] in
                        progressController?.update(progress)
                    }
                }
            )
            guard let self else { return }
            self.directoryManager.endWriteLease(rootID: destinationRoot.root.id)
            progressController.finish(summary)
            self.importTask = nil
            self.setImportInProgress(false)
            NotificationCenter.default.post(name: .dailyWallpaperLibraryDidChange, object: self)
        }
        setImportInProgress(true)
    }

    private func removeLibraryRoot(_ rootID: UUID) async throws {
        guard !isTerminating else { throw CancellationError() }
        if let task = libraryRootRemovalTasks[rootID] {
            try await task.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performRemoveLibraryRoot(rootID)
        }
        libraryRootRemovalTasks[rootID] = task
        do {
            try await task.value
            libraryRootRemovalTasks[rootID] = nil
        } catch {
            libraryRootRemovalTasks[rootID] = nil
            throw error
        }
    }

    private func performRemoveLibraryRoot(_ rootID: UUID) async throws {
        // 启动恢复可能正在校验旧记录；先取消并等待，避免删除完成后又写回悬空 rootID。
        let reconciliation = pendingIndexReconciliationTask
        pendingIndexReconciliationTask = nil
        pendingIndexReconciliationID = nil
        reconciliation?.cancel()
        await reconciliation?.value

        guard let index = mediaIndex else { throw MediaLibraryIndexError.closed }
        let removedRoot = try directoryManager.removeRoot(id: rootID)
        do {
            try await index.deleteRecords(rootID: rootID)
            try? await pendingIndexQueue?.remove(rootID: rootID)
            settings.removeWallpaperReferences(toRootID: rootID)
            NotificationCenter.default.post(name: .dailyWallpaperLibraryDidChange, object: self)
        } catch {
            directoryManager.restoreRemovedRoot(removedRoot)
            throw error
        }
    }

    private func reconcilePendingIndexEntries(queue: PendingIndexQueue, index: MediaLibraryIndex) {
        let reconciliationID = UUID()
        pendingIndexReconciliationID = reconciliationID
        pendingIndexReconciliationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // 只清理由本任务登记的句柄，避免未来支持重复恢复时旧任务误清新任务。
                if pendingIndexReconciliationID == reconciliationID {
                    pendingIndexReconciliationTask = nil
                    pendingIndexReconciliationID = nil
                }
            }
            let knownRootIDs = Set(settings.libraryRoots.map(\.id))
            var restoredAny = false
            for metadata in await queue.all() {
                guard !Task.isCancelled else { return }
                guard knownRootIDs.contains(metadata.rootID) else {
                    // 根目录已由用户移除时清掉陈旧队列项；临时离线的已知根目录仍会保留。
                    try? await queue.remove(metadata)
                    continue
                }
                guard
                    let imageURL = try? directoryManager.imageURL(
                        rootID: metadata.rootID,
                        relativePath: metadata.relativeImagePath
                    ),
                    await store.isValidArchivedImage(
                        imageURL,
                        expectedSHA256: metadata.contentSHA256
                    )
                else { continue }
                guard !Task.isCancelled else { return }
                do {
                    _ = try await index.upsert(metadata)
                    try await queue.remove(metadata)
                    restoredAny = true
                } catch {
                    // 数据库仍不可写时保留队列，等待下次正常启动再试。
                    continue
                }
            }
            if restoredAny {
                NotificationCenter.default.post(name: .dailyWallpaperLibraryDidChange, object: self)
            }
        }
    }
}
