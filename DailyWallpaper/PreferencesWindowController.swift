import AppKit

@MainActor
final class PreferencesViewController: NSViewController {
    var onRemoveLibraryRoot: ((UUID) async throws -> Void)?

    private let settings: SettingsStore
    private let displayRegistry: DisplayRegistry
    private let directoryManager: DownloadDirectoryManager
    private let launchService: LaunchAtLoginService

    private let modeControl = NSSegmentedControl(labels: ["全部显示器相同", "每个显示器独立"], trackingMode: .selectOne, target: nil, action: nil)
    private let displayPopup = NSPopUpButton()
    private let displayDetailsLabel = NSTextField(labelWithString: "")
    private let marketPopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let scalingPopup = NSPopUpButton()
    private let displayAutoApply = NSButton(checkboxWithTitle: "自动更换此显示器", target: nil, action: nil)

    private let activeDirectoryLabel = NSTextField(wrappingLabelWithString: "")
    private let rootsPopup = NSPopUpButton()
    private let rootStatusLabel = NSTextField(labelWithString: "")
    private let chooseDirectoryButton = NSButton(title: "选择目录…", target: nil, action: nil)
    private let restoreDefaultDirectoryButton = NSButton(title: "恢复默认目录", target: nil, action: nil)
    private let removeRootButton = NSButton(title: "移除所选历史目录", target: nil, action: nil)

    private let dailyDownloadButton = NSButton(checkboxWithTitle: "每日自动下载", target: nil, action: nil)
    private let dailyApplyButton = NSButton(checkboxWithTitle: "每日自动更换", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let launchStatusLabel = NSTextField(labelWithString: "")

    private var pageControllers: [MainWindowSection: NSViewController] = [:]
    private var visiblePageController: NSViewController?
    private var removeRootTask: Task<Void, Never>?
    private var directoryChangesEnabled = true
    private var isShutDown = false

    init(
        settings: SettingsStore,
        displayRegistry: DisplayRegistry,
        directoryManager: DownloadDirectoryManager,
        launchService: LaunchAtLoginService
    ) {
        self.settings = settings
        self.displayRegistry = displayRegistry
        self.directoryManager = directoryManager
        self.launchService = launchService
        super.init(nibName: nil, bundle: nil)
        _ = view
        registerActions()
        refreshAll()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displaysChanged),
            name: .dailyWallpaperDisplaysDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .dailyWallpaperSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(libraryDidChange),
            name: .dailyWallpaperLibraryDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        pageControllers = [
            .displays: makeDisplayTab(),
            .downloads: makeDownloadTab(),
            .automation: makeAutomationTab()
        ]
        showPage(.displays)
    }

    func show(section: MainWindowSection) {
        guard section != .library else { return }
        showPage(section)
        refreshAll()
    }

    /// 设置页会监听全局配置变化，主窗口销毁时显式解除监听。
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        removeRootTask?.cancel()
        removeRootTask = nil
        NotificationCenter.default.removeObserver(self)
    }

    func setDirectoryChangesEnabled(_ isEnabled: Bool) {
        directoryChangesEnabled = isEnabled
        chooseDirectoryButton.isEnabled = isEnabled
        restoreDefaultDirectoryButton.isEnabled = isEnabled
        chooseDirectoryButton.toolTip = isEnabled ? "选择新的图片下载目录" : "下载或导入进行中，暂时不能切换目录"
        restoreDefaultDirectoryButton.toolTip = isEnabled ? "恢复到系统图片目录" : "下载或导入进行中，暂时不能切换目录"
        selectedRootChanged()
    }

    private func showPage(_ section: MainWindowSection) {
        guard let controller = pageControllers[section], visiblePageController !== controller else { return }
        let previousController = visiblePageController
        // 快速连续切换时，先清掉仍在淡出中的历史分页。
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
                controller.view.topAnchor.constraint(equalTo: view.topAnchor),
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        visiblePageController = controller

        // 分页切换交叉淡入淡出，与主窗口切页体验保持一致。
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
                guard previousController !== self.visiblePageController else { return }
                previousController.view.removeFromSuperview()
                previousController.removeFromParent()
            }
        })
    }

    private func makeDisplayTab() -> NSViewController {
        let controller = NSViewController()
        controller.title = "显示器"
        controller.view = NSView()

        marketPopup.addItems(withTitles: ["zh-CN", "en-US", "ja-JP", "de-DE", "fr-FR"])
        resolutionPopup.addItems(withTitles: WallpaperResolutionPreference.allCases.map(\.localizedName))
        scalingPopup.addItems(withTitles: WallpaperScaling.allCases.map(\.localizedName))
        displayDetailsLabel.textColor = .secondaryLabelColor

        let modeCard = sectionCard([modeControl])
        let displayCard = sectionCard([
            labeledRow("当前显示器", displayPopup),
            displayDetailsLabel,
            labeledRow("国家或地区", marketPopup),
            labeledRow("下载分辨率", resolutionPopup),
            labeledRow("显示方式", scalingPopup),
            displayAutoApply
        ])
        let stack = NSStackView(views: [
            pageHeader("显示器", subtitle: "为全部显示器使用同一套规则，或分别配置每一台显示器。"),
            heading("配置方式"),
            modeCard,
            heading("壁纸规则"),
            displayCard
        ])
        configureRootStack(stack, in: controller.view)
        modeCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        displayCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return controller
    }

    private func makeDownloadTab() -> NSViewController {
        let controller = NSViewController()
        controller.title = "下载"
        controller.view = NSView()

        activeDirectoryLabel.maximumNumberOfLines = 1
        activeDirectoryLabel.lineBreakMode = .byTruncatingMiddle
        activeDirectoryLabel.textColor = .secondaryLabelColor
        rootStatusLabel.lineBreakMode = .byTruncatingMiddle
        rootStatusLabel.textColor = .secondaryLabelColor

        chooseDirectoryButton.target = self
        chooseDirectoryButton.action = #selector(chooseDirectory)
        chooseDirectoryButton.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        chooseDirectoryButton.imagePosition = .imageLeading
        let openButton = NSButton(title: "在访达中打开", target: self, action: #selector(openActiveDirectory))
        restoreDefaultDirectoryButton.target = self
        restoreDefaultDirectoryButton.action = #selector(restoreDefaultDirectory)
        let actions = NSStackView(views: [chooseDirectoryButton, openButton, restoreDefaultDirectoryButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let directoryCard = sectionCard([activeDirectoryLabel, actions])
        let rootsCard = sectionCard([rootsPopup, rootStatusLabel, removeRootButton])
        let stack = NSStackView(views: [
            pageHeader("下载目录", subtitle: "管理图片归档位置，以及媒体库当前可访问的根目录。"),
            heading("当前下载目录"),
            directoryCard,
            heading("媒体库根目录"),
            rootsCard
        ])
        configureRootStack(stack, in: controller.view)
        directoryCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rootsCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        // 卡片内边距 14x2，路径标签需限宽才能触发中部截断。
        activeDirectoryLabel.widthAnchor.constraint(equalTo: directoryCard.widthAnchor, constant: -28).isActive = true
        rootStatusLabel.widthAnchor.constraint(equalTo: rootsCard.widthAnchor, constant: -28).isActive = true
        return controller
    }

    private func makeAutomationTab() -> NSViewController {
        let controller = NSViewController()
        controller.title = "自动化"
        controller.view = NSView()
        launchStatusLabel.textColor = .secondaryLabelColor

        let dailyCard = sectionCard([dailyDownloadButton, dailyApplyButton])
        let launchCard = sectionCard([launchAtLoginButton, launchStatusLabel])
        let stack = NSStackView(views: [
            pageHeader("自动化", subtitle: "控制每日下载、更换壁纸以及登录启动行为。"),
            heading("每日任务"),
            dailyCard,
            heading("系统启动"),
            launchCard
        ])
        configureRootStack(stack, in: controller.view)
        dailyCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        launchCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return controller
    }

    private func registerActions() {
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        displayPopup.target = self
        displayPopup.action = #selector(selectedDisplayChanged)
        [marketPopup, resolutionPopup, scalingPopup].forEach {
            $0.target = self
            $0.action = #selector(profileChanged)
        }
        displayAutoApply.target = self
        displayAutoApply.action = #selector(profileChanged)
        rootsPopup.target = self
        rootsPopup.action = #selector(selectedRootChanged)
        removeRootButton.target = self
        removeRootButton.action = #selector(removeSelectedRoot)
        dailyDownloadButton.target = self
        dailyDownloadButton.action = #selector(automaticDownloadChanged)
        dailyApplyButton.target = self
        dailyApplyButton.action = #selector(automaticApplyChanged)
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(launchAtLoginChanged)
    }

    private func refreshAll() {
        displayRegistry.refresh()
        modeControl.selectedSegment = settings.configurationMode == .shared ? 0 : 1
        refreshDisplays()
        refreshProfileControls()
        refreshDirectories()
        refreshAutomationControls()
    }

    private func refreshDisplays() {
        let selectedUUID = selectedDisplayUUID
        displayPopup.removeAllItems()
        for display in displayRegistry.displays {
            displayPopup.addItem(withTitle: display.localizedName + (display.isMain ? "（主显示器）" : ""))
            displayPopup.lastItem?.representedObject = display.uuid
        }
        if let selectedUUID, let index = displayRegistry.displays.firstIndex(where: { $0.uuid == selectedUUID }) {
            displayPopup.selectItem(at: index)
        } else if !displayRegistry.displays.isEmpty {
            displayPopup.selectItem(at: 0)
        }
        displayPopup.isEnabled = settings.configurationMode == .individual
        updateDisplayDetails()
    }

    private func refreshProfileControls() {
        let profile: WallpaperProfile
        if settings.configurationMode == .shared {
            profile = settings.sharedProfile
        } else if let uuid = selectedDisplayUUID {
            profile = settings.displayAssignments[uuid] ?? .default
        } else {
            profile = .default
        }

        if let index = marketPopup.itemTitles.firstIndex(of: profile.normalizedMarket) {
            marketPopup.selectItem(at: index)
        } else {
            marketPopup.addItem(withTitle: profile.normalizedMarket)
            marketPopup.selectItem(withTitle: profile.normalizedMarket)
        }
        resolutionPopup.selectItem(at: WallpaperResolutionPreference.allCases.firstIndex(of: profile.resolutionPreference) ?? 0)
        scalingPopup.selectItem(at: WallpaperScaling.allCases.firstIndex(of: profile.scaling) ?? 0)
        displayAutoApply.state = profile.automaticApplyEnabled ? .on : .off
        displayAutoApply.isEnabled = settings.configurationMode == .individual
    }

    private func refreshDirectories() {
        let statuses = directoryManager.statuses()
        if let active = try? directoryManager.ensureActiveRoot() {
            activeDirectoryLabel.stringValue = active.url.path
            activeDirectoryLabel.toolTip = active.url.path
        } else {
            activeDirectoryLabel.stringValue = "当前目录不可访问"
            activeDirectoryLabel.toolTip = nil
        }

        let selectedID = rootsPopup.selectedItem?.representedObject as? UUID
        rootsPopup.removeAllItems()
        for status in statuses {
            let suffix = status.root.isActiveWriteRoot ? "（当前）" : (status.isAvailable ? "" : "（离线）")
            rootsPopup.addItem(withTitle: status.root.displayName + suffix)
            rootsPopup.lastItem?.representedObject = status.root.id
        }
        if let selectedID, let item = rootsPopup.itemArray.first(where: { ($0.representedObject as? UUID) == selectedID }) {
            rootsPopup.select(item)
        }
        selectedRootChanged()
    }

    private func refreshAutomationControls() {
        dailyDownloadButton.state = settings.automaticDailyDownloadEnabled ? .on : .off
        dailyApplyButton.state = settings.automaticDailyApplyEnabled ? .on : .off
        dailyApplyButton.isEnabled = settings.automaticDailyDownloadEnabled
        launchAtLoginButton.state = currentLaunchAtLoginEnabled ? .on : .off
        launchAtLoginButton.isEnabled = true

        switch launchService.status {
        case .disabled:
            launchStatusLabel.stringValue = "当前未启用"
        case .enabled:
            launchStatusLabel.stringValue = "已启用"
        case .requiresApproval:
            launchStatusLabel.stringValue = "需要在系统设置的“登录项”中批准"
        case .unavailable:
            launchAtLoginButton.state = .off
            launchAtLoginButton.isEnabled = false
            launchStatusLabel.stringValue = "当前应用签名或安装位置不支持登录启动"
        }
    }

    private var currentLaunchAtLoginEnabled: Bool {
        switch launchService.status {
        case .enabled, .requiresApproval: true
        case .disabled, .unavailable: false
        }
    }

    private var selectedDisplayUUID: String? {
        displayPopup.selectedItem?.representedObject as? String
    }

    private func updateDisplayDetails() {
        guard let uuid = selectedDisplayUUID, let display = displayRegistry.displays.first(where: { $0.uuid == uuid }) else {
            displayDetailsLabel.stringValue = "未检测到显示器"
            return
        }
        displayDetailsLabel.stringValue = "逻辑尺寸 \(display.logicalWidth)x\(display.logicalHeight) · 像素 \(display.pixelWidth)x\(display.pixelHeight)"
    }

    private func currentEditedProfile() -> WallpaperProfile {
        WallpaperProfile(
            market: marketPopup.titleOfSelectedItem ?? "zh-CN",
            resolutionPreference: WallpaperResolutionPreference.allCases[safe: resolutionPopup.indexOfSelectedItem] ?? .automatic,
            scaling: WallpaperScaling.allCases[safe: scalingPopup.indexOfSelectedItem] ?? .fill,
            automaticApplyEnabled: displayAutoApply.state == .on
        )
    }

    @objc private func displaysChanged() { refreshDisplays(); refreshProfileControls() }
    @objc private func settingsChanged() { refreshAll() }
    @objc private func libraryDidChange() { refreshDirectories() }

    @objc private func modeChanged() {
        settings.saveDisplayConfiguration(
            mode: modeControl.selectedSegment == 0 ? .shared : .individual,
            sharedProfile: settings.sharedProfile,
            displayAssignments: settings.displayAssignments
        )
        refreshDisplays()
        refreshProfileControls()
    }

    @objc private func selectedDisplayChanged() {
        updateDisplayDetails()
        refreshProfileControls()
    }

    /// 控件变化时直接提交，遵循 macOS 设置即时生效的惯例；每次交互只发布一次配置变更。
    @objc private func profileChanged() {
        let profile = currentEditedProfile()
        if settings.configurationMode == .shared {
            settings.saveDisplayConfiguration(
                mode: .shared,
                sharedProfile: profile,
                displayAssignments: settings.displayAssignments
            )
        } else if let uuid = selectedDisplayUUID {
            var assignments = settings.displayAssignments
            assignments[uuid] = profile
            settings.saveDisplayConfiguration(
                mode: .individual,
                sharedProfile: settings.sharedProfile,
                displayAssignments: assignments
            )
        }
    }

    @objc private func chooseDirectory() {
        guard directoryChangesEnabled else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self, directoryChangesEnabled, response == .OK, let url = panel?.url else { return }
            do {
                _ = try directoryManager.addCustomRoot(url: url)
                refreshDirectories()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func openActiveDirectory() {
        guard let root = try? directoryManager.ensureActiveRoot() else { return }
        NSWorkspace.shared.open(root.url)
    }

    @objc private func restoreDefaultDirectory() {
        guard directoryChangesEnabled else { return }
        do {
            _ = try directoryManager.restoreDefaultRoot()
            refreshDirectories()
        } catch {
            showError(error)
        }
    }

    @objc private func selectedRootChanged() {
        guard let id = rootsPopup.selectedItem?.representedObject as? UUID else {
            rootStatusLabel.stringValue = ""
            rootStatusLabel.toolTip = nil
            removeRootButton.isEnabled = false
            return
        }
        let status = directoryManager.statuses().first(where: { $0.root.id == id })
        rootStatusLabel.stringValue = status?.url?.path ?? "目录当前离线或授权已失效"
        rootStatusLabel.toolTip = status?.url?.path
        removeRootButton.isEnabled = directoryChangesEnabled
            && removeRootTask == nil
            && status?.root.isActiveWriteRoot == false
        removeRootButton.toolTip = directoryChangesEnabled
            ? "只从媒体库移除记录，不删除目录中的图片"
            : "下载或导入进行中，暂时不能移除媒体库目录"
    }

    @objc private func removeSelectedRoot() {
        guard
            directoryChangesEnabled,
            let id = rootsPopup.selectedItem?.representedObject as? UUID,
            let onRemoveLibraryRoot
        else { return }
        guard removeRootTask == nil else { return }
        removeRootButton.isEnabled = false
        removeRootTask = Task { [weak self] in
            do {
                // 窗口关闭会先取消包装任务，避免它在退出快照之后才注册新的目录移除操作。
                try Task.checkCancellation()
                try await onRemoveLibraryRoot(id)
                guard let self, !Task.isCancelled, !isShutDown else { return }
                removeRootTask = nil
                refreshDirectories()
            } catch {
                guard let self, !Task.isCancelled, !isShutDown else { return }
                removeRootTask = nil
                showError(error)
                selectedRootChanged()
            }
        }
    }

    /// setter 自带“下载/更换”联动不变量，提交后回读归一化结果刷新控件。
    @objc private func automaticDownloadChanged() {
        settings.automaticDailyDownloadEnabled = dailyDownloadButton.state == .on
        refreshAutomationControls()
    }

    @objc private func automaticApplyChanged() {
        settings.automaticDailyApplyEnabled = dailyApplyButton.state == .on
        refreshAutomationControls()
    }

    @objc private func launchAtLoginChanged() {
        do {
            try launchService.setEnabled(launchAtLoginButton.state == .on)
        } catch {
            showError(error)
        }
        refreshAutomationControls()
    }

    private func configureRootStack(_ stack: NSStackView, in view: NSView) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            // 页面可能承载在全尺寸标题栏窗口内，使用安全区域确保标题和说明始终完整可见。
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -28)
        ])
    }

    private func pageHeader(_ title: String, subtitle: String) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5
        return header
    }

    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    /// macOS 系统设置风格的分组圆角卡片，承载一组相关设置行。
    private func sectionCard(_ views: [NSView]) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        if let host = box.contentView {
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
        }
        return box
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
