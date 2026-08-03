import AppKit
import UniformTypeIdentifiers

private struct TrashedLibraryFile {
    let originalURL: URL
    let trashURL: URL
}

private enum MediaLibraryDeletionError: LocalizedError {
    case busy
    case invalidArchiveIdentity
    case trashLocationUnavailable
    case partialRecoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy: "正在下载、导入或修改媒体库，请稍后再删除"
        case .invalidArchiveIdentity: "图片归档路径与媒体库记录不一致，已停止删除"
        case .trashLocationUnavailable: "无法确认文件在废纸篓中的位置"
        case let .partialRecoveryFailed(details): "删除未能完整回滚：\(details)"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 设置快照放在双方都能访问的图片目录，避免开发版与 GitHub 安装包落入不同偏好域后配置归零。
    private lazy var settings = SettingsStore(persistenceURL: SettingsStore.defaultPersistenceURL())
    private let displayRegistry = DisplayRegistry()
    private let store = WallpaperStore()
    private let bingService = BingImageService()
    private let retryTimer = RetryTimer()
    private let eventMonitor = AutomationEventMonitor()
    private let launchService = LaunchAtLoginService()
    private let archiveMetadataReconciler = ArchiveMetadataReconciler()

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
    private var libraryItemDeletionTask: Task<Void, Error>?
    private var importService: ImageImportService?
    private var terminationTask: Task<Void, Never>?
    private var isTerminating = false
    private var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["DAILY_WALLPAPER_UNIT_TEST_HOST"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App-hosted XCTest 不得初始化真实设置、媒体库和后台更新任务。
        guard !isRunningUnitTests else { return }
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
            settings.onConfigurationChange = { [weak self] in
                self?.requestUpdate(.settingsChanged)
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
            eventMonitor.onEvent = { [weak self] trigger in
                self?.requestUpdate(trigger)
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
        guard !isRunningUnitTests else { return .terminateNow }
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
        let pendingDeletion = libraryItemDeletionTask
        let coordinator = coordinator
        let mediaIndex = mediaIndex
        terminationTask = Task { [weak self, weak sender] in
            await coordinator?.shutdown()
            await pendingImport?.value
            await pendingReconciliation?.value
            for task in pendingRootRemovals {
                _ = try? await task.value
            }
            _ = try? await pendingDeletion?.value
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
        guard !isRunningUnitTests else { return }
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
        // 菜单栏模式重新打开主窗口时恢复普通应用身份，让 Dock 和 Command-Tab 一起回来。
        NSApp.setActivationPolicy(.regular)
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
        controller.onDownloadRequested = { [weak self] in self?.requestUpdate(.manualDownload) }
        controller.onDownloadAndApplyRequested = { [weak self] in self?.requestUpdate(.manualDownloadAndApply) }
        controller.onImportRequested = { [weak self] in self?.beginImport() }
        controller.onSetWallpaper = { [weak self] item, displayUUIDs in
            self?.coordinator?.applyLibraryItem(item, displayUUIDs: displayUUIDs)
        }
        controller.onDeleteLibraryItem = { [weak self] item in
            guard let self else { throw CancellationError() }
            try await self.deleteLibraryItem(item)
        }
        controller.onRemoveLibraryRoot = { [weak self] rootID in
            guard let self else { return }
            try await self.removeLibraryRoot(rootID)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, self.mainWindowController === controller else { return }
            self.mainWindowController = nil
            guard !self.isTerminating else { return }
            // 红色关闭按钮只关闭前台窗口；后台任务和菜单栏继续运行，并隐藏 Dock 图标。
            NSApp.setActivationPolicy(.accessory)
        }
        mainWindowController = controller
        if let coordinator { controller.update(coordinator.status) }
        controller.setImportInProgress(importTask != nil)
        controller.setLibraryDeletionInProgress(libraryItemDeletionTask != nil)
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
        // 文件菜单的忙碌状态由应用统一维护，不能让 AppKit 自动校验覆盖手动禁用结果。
        fileMenu.autoenablesItems = false
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
    @objc private func downloadFromMenu() { requestUpdate(.manualDownload) }
    @objc private func downloadAndApplyFromMenu() { requestUpdate(.manualDownloadAndApply) }

    private func updateCommandAvailability(_ status: UpdateStatus) {
        let canUpdate = !status.isBusy && libraryItemDeletionTask == nil
        downloadMenuItem?.isEnabled = canUpdate
        downloadAndApplyMenuItem?.isEnabled = canUpdate
    }

    private func setImportInProgress(_ isInProgress: Bool) {
        importMenuItem?.isEnabled = !isInProgress && libraryItemDeletionTask == nil
        menuBarController?.setImportInProgress(isInProgress)
        mainWindowController?.setImportInProgress(isInProgress)
    }

    private func setLibraryDeletionInProgress(_ isInProgress: Bool) {
        coordinator?.setLibraryMutationInProgress(isInProgress)
        let status = coordinator?.status ?? UpdateStatus(phase: .idle, message: "等待更新", isBusy: false)
        updateCommandAvailability(status)
        importMenuItem?.isEnabled = !isInProgress && importTask == nil
        menuBarController?.setLibraryDeletionInProgress(isInProgress)
        mainWindowController?.setLibraryDeletionInProgress(isInProgress)
    }

    private func requestUpdate(_ trigger: UpdateTrigger) {
        guard !isTerminating else { return }
        coordinator?.trigger(trigger)
    }

    private func beginImport() {
        guard
            !isTerminating,
            importTask == nil,
            libraryItemDeletionTask == nil,
            let importService
        else { return }
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
        guard libraryItemDeletionTask == nil else { throw MediaLibraryDeletionError.busy }
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

    private func deleteLibraryItem(_ item: MediaLibraryItem) async throws {
        guard !isTerminating else { throw CancellationError() }
        guard
            libraryItemDeletionTask == nil,
            libraryRootRemovalTasks.isEmpty,
            importTask == nil,
            coordinator?.status.isBusy != true
        else {
            throw MediaLibraryDeletionError.busy
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performDeleteLibraryItem(item)
        }
        libraryItemDeletionTask = task
        setLibraryDeletionInProgress(true)
        do {
            try await task.value
            finishLibraryItemDeletion()
        } catch {
            finishLibraryItemDeletion()
            throw error
        }
    }

    private func finishLibraryItemDeletion() {
        libraryItemDeletionTask = nil
        setLibraryDeletionInProgress(false)
    }

    private func performDeleteLibraryItem(_ item: MediaLibraryItem) async throws {
        guard let index = mediaIndex else { throw MediaLibraryIndexError.closed }

        // 启动恢复任务可能正准备写回同一条记录；先结束它，避免删除后索引再次出现。
        let reconciliation = pendingIndexReconciliationTask
        pendingIndexReconciliationTask = nil
        pendingIndexReconciliationID = nil
        reconciliation?.cancel()
        await reconciliation?.value
        defer {
            // 删除只暂停启动恢复流程；无论删除成功与否，都要让队列中的其他图片在本次运行继续恢复。
            if reconciliation != nil, !isTerminating, let pendingIndexQueue {
                reconcilePendingIndexEntries(queue: pendingIndexQueue, index: index)
            }
        }
        guard
            importTask == nil,
            libraryRootRemovalTasks.isEmpty,
            coordinator?.status.isBusy != true
        else {
            throw MediaLibraryDeletionError.busy
        }

        // 先移除待恢复项，避免文件和 SQLite 已删除后，旧队列在下次启动把记录重新写回。
        if let pendingIndexQueue {
            try await pendingIndexQueue.remove(
                rootID: item.rootID,
                relativeMetadataPath: item.relativeMetadataPath
            )
        }

        let normalizedHash = item.contentSHA256.lowercased()
        guard
            normalizedHash.count == 64,
            normalizedHash.allSatisfy(\.isHexDigit)
        else { throw MediaLibraryDeletionError.invalidArchiveIdentity }

        // 删除路径不跟随子目录符号链接，且必须仍符合“同目录、同 SHA、图片 + JSON”归档结构。
        let imageURL = try directoryManager.deletableFileURL(
            rootID: item.rootID,
            relativePath: item.relativeImagePath
        )
        let metadataURL = try directoryManager.deletableFileURL(
            rootID: item.rootID,
            relativePath: item.relativeMetadataPath
        )
        guard
            imageURL != metadataURL,
            imageURL.deletingLastPathComponent() == metadataURL.deletingLastPathComponent(),
            imageURL.deletingPathExtension().lastPathComponent.lowercased() == normalizedHash,
            metadataURL.deletingPathExtension().lastPathComponent.lowercased() == normalizedHash,
            !imageURL.pathExtension.isEmpty,
            imageURL.pathExtension.lowercased() != "json",
            metadataURL.pathExtension.lowercased() == "json"
        else { throw MediaLibraryDeletionError.invalidArchiveIdentity }

        var trashedFiles: [TrashedLibraryFile] = []
        var filesMovedWithoutKnownTrashURL: [URL] = []
        do {
            for url in [imageURL, metadataURL] where FileManager.default.fileExists(atPath: url.path) {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                if let trashURL = resultingURL as URL? {
                    trashedFiles.append(TrashedLibraryFile(originalURL: url, trashURL: trashURL))
                } else if FileManager.default.fileExists(atPath: url.path) {
                    // API 没有返回废纸篓位置且原文件仍在时，不继续提交索引删除。
                    throw MediaLibraryDeletionError.trashLocationUnavailable
                } else {
                    // trashItem 已成功，但极少数文件系统可能不回传新位置；继续删除精确索引，避免悬空记录。
                    filesMovedWithoutKnownTrashURL.append(url)
                }
            }

            guard try await index.deleteRecord(matching: item) else {
                throw MediaLibraryIndexError.recordNotFound
            }
        } catch {
            var recoveryFailures: [String] = []

            // 文件已经进入废纸篓但索引提交失败时逐项放回；任何失败都必须反馈给调用方。
            for file in trashedFiles.reversed() {
                do {
                    guard !FileManager.default.fileExists(atPath: file.originalURL.path) else {
                        recoveryFailures.append("\(file.originalURL.lastPathComponent) 的原位置已被占用")
                        continue
                    }
                    try FileManager.default.moveItem(at: file.trashURL, to: file.originalURL)
                } catch {
                    recoveryFailures.append("无法恢复 \(file.originalURL.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            for originalURL in filesMovedWithoutKnownTrashURL
                where !FileManager.default.fileExists(atPath: originalURL.path)
            {
                recoveryFailures.append("无法定位并恢复 \(originalURL.lastPathComponent)")
            }

            guard !recoveryFailures.isEmpty else { throw error }

            // 至少一个文件无法恢复时，不允许精确匹配的索引继续指向缺失文件。
            do {
                _ = try await index.deleteRecord(matching: item)
            } catch {
                recoveryFailures.append("无法同步清理媒体库索引：\(error.localizedDescription)")
            }
            settings.removeWallpaperReferences(
                toRootID: item.rootID,
                relativeImagePath: item.relativeImagePath
            )
            NotificationCenter.default.post(name: .dailyWallpaperLibraryDidChange, object: self)
            let originalMessage = error.localizedDescription
            throw MediaLibraryDeletionError.partialRecoveryFailed(
                "\(originalMessage)；\(recoveryFailures.joined(separator: "；"))"
            )
        }

        settings.removeWallpaperReferences(
            toRootID: item.rootID,
            relativeImagePath: item.relativeImagePath
        )
        NotificationCenter.default.post(name: .dailyWallpaperLibraryDidChange, object: self)
    }

    private func performRemoveLibraryRoot(_ rootID: UUID) async throws {
        // 启动恢复可能正在校验旧记录；先取消并等待，避免删除完成后又写回悬空 rootID。
        let reconciliation = pendingIndexReconciliationTask
        pendingIndexReconciliationTask = nil
        pendingIndexReconciliationID = nil
        reconciliation?.cancel()
        await reconciliation?.value
        defer {
            // 移除一个目录只暂停恢复任务，其他已登记目录仍应在本次运行继续完成恢复。
            if reconciliation != nil, !isTerminating, let pendingIndexQueue, let mediaIndex {
                reconcilePendingIndexEntries(queue: pendingIndexQueue, index: mediaIndex)
            }
        }

        guard let index = mediaIndex else { throw MediaLibraryIndexError.closed }
        let removedRoot = try directoryManager.removeRoot(id: rootID)
        do {
            try await index.deleteRecords(rootID: rootID)
            try? await pendingIndexQueue?.remove(rootID: rootID)
            settings.removeWallpaperReferences(toRootID: rootID)
            settings.removeArchiveReconciliationState(rootID: rootID)
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

            // 设置或 SQLite 位于不同运行域时，以图片目录中的旁车 JSON 轻量重建派生索引。
            for status in directoryManager.statuses() {
                guard !Task.isCancelled else { return }
                let hasIndexedItems = (try? await index.containsItems(rootID: status.root.id)) == true
                guard
                    settings.archiveReconciliationVersion(for: status.root.id)
                        < ArchiveMetadataReconciler.currentVersion || !hasIndexedItems,
                    let rootURL = status.url
                else { continue }
                do {
                    let count = try await archiveMetadataReconciler.reconcile(
                        root: ResolvedLibraryRoot(root: status.root, url: rootURL),
                        index: index
                    )
                    settings.markArchiveReconciled(
                        rootID: status.root.id,
                        version: ArchiveMetadataReconciler.currentVersion
                    )
                    restoredAny = restoredAny || count > 0
                } catch is CancellationError {
                    return
                } catch let error as ArchiveMetadataReconciliationError {
                    // 单张损坏不应阻止同一次扫描中已恢复的其他图片刷新到媒体库。
                    restoredAny = restoredAny || error.restoredCount > 0
                    continue
                } catch {
                    // 离线目录或单次读取失败不会标记完成，下次启动会从头幂等重试。
                    continue
                }
            }

            // rootID 不再存在时对应记录已无法解析文件路径；成功重扫后清掉这些可再生的旧索引。
            do {
                let staleRootIDs = try await index.rootIDs().subtracting(knownRootIDs)
                for rootID in staleRootIDs {
                    try await index.deleteRecords(rootID: rootID)
                }
                restoredAny = restoredAny || !staleRootIDs.isEmpty
            } catch {
                // 清理失败不影响已恢复记录；SQLite 下次启动仍会再次尝试。
            }
            if restoredAny {
                NotificationCenter.default.post(name: .dailyWallpaperLibraryDidChange, object: self)
            }
        }
    }
}
