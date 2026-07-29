import AppKit

/// 三方合并单个设置字段：用户没改过的字段跟随最新持久值，真正编辑过的字段保留草稿。
/// 这样菜单栏等外部入口提交配置后，不会被设置页里无关的旧草稿静默覆盖。
func mergePreferenceDraftValue<Value: Equatable>(
    draft: Value,
    previousBaseline: Value,
    persisted: Value
) -> Value {
    draft == previousBaseline ? persisted : draft
}

@MainActor
final class PreferencesViewController: NSViewController {
    var onRemoveLibraryRoot: ((UUID) async throws -> Void)?

    private struct DisplayConfigurationDraft: Equatable {
        var mode: DisplayConfigurationMode
        var sharedProfile: WallpaperProfile
        var displayAssignments: [String: WallpaperProfile]
    }

    private struct AutomationConfigurationDraft: Equatable {
        var downloadEnabled: Bool
        var applyEnabled: Bool
        var launchAtLoginEnabled: Bool
    }

    private let settings: SettingsStore
    private let displayRegistry: DisplayRegistry
    private let directoryManager: DownloadDirectoryManager
    private let launchService: LaunchAtLoginService
    private let initialSection: MainWindowSection

    private let sharedModeCard = OptionCardButton(
        title: "全部显示器相同",
        subtitle: "所有显示器共用同一套壁纸规则",
        symbolName: "rectangle.on.rectangle"
    )
    private let individualModeCard = OptionCardButton(
        title: "每个显示器独立",
        subtitle: "为每台显示器分别设置规则",
        symbolName: "display.2"
    )
    private let displayPopup = NSPopUpButton()
    private let displayDetailsLabel = NSTextField(labelWithString: "")
    private let marketPopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let scalingPopup = NSPopUpButton()
    private let displayAutoApply = NSButton(checkboxWithTitle: "自动更换此显示器", target: nil, action: nil)
    private let displayRuleTitleLabel = NSTextField(labelWithString: "")
    private let displayRuleSubtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let displaySaveStatusLabel = NSTextField(labelWithString: "设置已保存")
    private let displaySaveButton = NSButton(title: "保存更改", target: nil, action: nil)

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
    private let automationSaveButton = NSButton(title: "保存更改", target: nil, action: nil)

    private var pageControllers: [MainWindowSection: NSViewController] = [:]
    private var visiblePageController: NSViewController?
    private var removeRootTask: Task<Void, Never>?
    private var directoryChangesEnabled = true
    private var isShutDown = false
    private var individualDisplayRows: [NSView] = []
    private var displayDraft = DisplayConfigurationDraft(
        mode: .shared,
        sharedProfile: .default,
        displayAssignments: [:]
    )
    private var displayBaseline = DisplayConfigurationDraft(
        mode: .shared,
        sharedProfile: .default,
        displayAssignments: [:]
    )
    private var automationDraft = AutomationConfigurationDraft(
        downloadEnabled: true,
        applyEnabled: true,
        launchAtLoginEnabled: false
    )
    private var automationBaseline = AutomationConfigurationDraft(
        downloadEnabled: true,
        applyEnabled: true,
        launchAtLoginEnabled: false
    )

    init(
        settings: SettingsStore,
        displayRegistry: DisplayRegistry,
        directoryManager: DownloadDirectoryManager,
        launchService: LaunchAtLoginService,
        initialSection: MainWindowSection = .displays
    ) {
        self.settings = settings
        self.displayRegistry = displayRegistry
        self.directoryManager = directoryManager
        self.launchService = launchService
        self.initialSection = initialSection == .library ? .displays : initialSection
        super.init(nibName: nil, bundle: nil)
        displayBaseline = persistedDisplayConfiguration()
        displayDraft = displayBaseline
        automationBaseline = persistedAutomationConfiguration()
        automationDraft = automationBaseline
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
        // 首次进入下载目录或自动化时直接准备目标页，不先挂载再切走显示器页。
        showPage(initialSection)
    }

    func show(section: MainWindowSection) {
        guard section != .library else { return }
        synchronizeDraftsFromPersistence()
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

        // 设置子页同样采用原子替换。侧栏切页不需要双层淡入动画，
        // 即时切换可避免离窗动画留下 alpha 为 0 的空白页。
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
                targetView.topAnchor.constraint(equalTo: view.topAnchor),
                targetView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                targetView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                targetView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        visiblePageController = controller
        // 视图树和约束变化会自动标记下一轮布局；这里不能同步强制布局，
        // 否则侧栏点击恰逢 AppKit 布局事务时会触发布局重入警告。
        view.needsLayout = true
    }

    private func makeDisplayTab() -> NSViewController {
        let controller = NSViewController()
        controller.title = "显示器"
        controller.view = NSView()

        marketPopup.addItems(withTitles: BingMarket.allCases.map(\.rawValue))
        resolutionPopup.addItems(withTitles: WallpaperResolutionPreference.allCases.map(\.localizedName))
        scalingPopup.addItems(withTitles: WallpaperScaling.allCases.map(\.localizedName))
        displayDetailsLabel.textColor = .secondaryLabelColor

        // 配置方式保持两张独立选项卡，但限制页面最大宽度，避免宽窗口下退化成横向 Banner。
        let modeRow = NSStackView(views: [sharedModeCard, individualModeCard])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 12
        modeRow.distribution = .fillEqually
        sharedModeCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
        individualModeCard.heightAnchor.constraint(equalTo: sharedModeCard.heightAnchor).isActive = true

        // 统一控件列宽，让三行规则形成稳定的原生表单节奏。
        [marketPopup, resolutionPopup, scalingPopup].forEach {
            $0.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        displayPopup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        displayDetailsLabel.font = .systemFont(ofSize: 11)
        displayDetailsLabel.lineBreakMode = .byTruncatingTail
        displayDetailsLabel.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let currentDisplayRow = labeledRow("当前显示器", displayPopup)
        let displayDetailsRow = labeledRow("", displayDetailsLabel)
        let autoApplyRow = labeledRow("", displayAutoApply)
        individualDisplayRows = [currentDisplayRow, displayDetailsRow, autoApplyRow]

        let form = NSStackView(views: [
            currentDisplayRow,
            displayDetailsRow,
            labeledRow("国家或地区", marketPopup),
            labeledRow("下载分辨率", resolutionPopup),
            labeledRow("显示方式", scalingPopup),
            autoApplyRow
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 11
        let formRow = centeredContentRow(form)

        displaySaveStatusLabel.font = .systemFont(ofSize: 11)
        displaySaveStatusLabel.textColor = .secondaryLabelColor
        configureSaveButton(displaySaveButton)
        let ruleHeader = displayRuleHeader()
        let ruleSeparator = separatorView()
        let footerSeparator = separatorView()
        let saveFooter = settingsActionFooter(status: displaySaveStatusLabel, button: displaySaveButton)
        let displayCard = sectionCard([
            ruleHeader,
            ruleSeparator,
            formRow,
            footerSeparator,
            saveFooter
        ], spacing: 12)
        let stack = NSStackView(views: [
            pageHeader("显示器", subtitle: "为全部显示器使用同一套规则，或分别配置每一台显示器。"),
            heading("配置方式"),
            modeRow,
            displayCard
        ])
        stack.setCustomSpacing(20, after: modeRow)
        configureRootStack(stack, in: controller.view)
        modeRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        displayCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        [ruleHeader, ruleSeparator, formRow, footerSeparator, saveFooter].forEach {
            $0.widthAnchor.constraint(equalTo: displayCard.widthAnchor, constant: -28).isActive = true
        }
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
        configureSaveButton(automationSaveButton)
        let saveRow = trailingActionRow(automationSaveButton)
        let stack = NSStackView(views: [
            pageHeader("自动化", subtitle: "控制每日下载、更换壁纸以及登录启动行为。"),
            heading("每日任务"),
            dailyCard,
            heading("系统启动"),
            launchCard,
            saveRow
        ])
        configureRootStack(stack, in: controller.view)
        dailyCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        launchCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        saveRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return controller
    }

    private func registerActions() {
        sharedModeCard.target = self
        sharedModeCard.action = #selector(modeCardTapped(_:))
        individualModeCard.target = self
        individualModeCard.action = #selector(modeCardTapped(_:))
        displayPopup.target = self
        displayPopup.action = #selector(selectedDisplayChanged)
        [marketPopup, resolutionPopup, scalingPopup].forEach {
            $0.target = self
            $0.action = #selector(profileChanged)
        }
        displayAutoApply.target = self
        displayAutoApply.action = #selector(profileChanged)
        displaySaveButton.target = self
        displaySaveButton.action = #selector(saveDisplayChanges)
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
        automationSaveButton.target = self
        automationSaveButton.action = #selector(saveAutomationChanges)
    }

    private func refreshAll() {
        displayRegistry.refresh()
        sharedModeCard.isChosen = displayDraft.mode == .shared
        individualModeCard.isChosen = displayDraft.mode == .individual
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
        let isIndividual = displayDraft.mode == .individual
        displayPopup.isEnabled = isIndividual
        // 共享模式不显示不可操作的单屏设置，减少灰色死控件和无意义留白。
        individualDisplayRows.forEach { $0.isHidden = !isIndividual }
        updateDisplayDetails()
    }

    private func refreshProfileControls() {
        let profile: WallpaperProfile
        if displayDraft.mode == .shared {
            profile = displayDraft.sharedProfile
        } else if let uuid = selectedDisplayUUID {
            profile = displayDraft.displayAssignments[uuid] ?? .default
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
        displayAutoApply.isEnabled = displayDraft.mode == .individual
        refreshDisplaySaveState()
    }

    private func refreshDisplaySaveState() {
        let hasUnsavedChanges = displayDraft != displayBaseline
        displaySaveButton.isEnabled = hasUnsavedChanges
        displaySaveStatusLabel.stringValue = hasUnsavedChanges ? "有未保存的更改" : "设置已保存"
        displaySaveStatusLabel.textColor = hasUnsavedChanges ? .controlAccentColor : .secondaryLabelColor
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
        dailyDownloadButton.state = automationDraft.downloadEnabled ? .on : .off
        dailyApplyButton.state = automationDraft.applyEnabled ? .on : .off
        dailyApplyButton.isEnabled = automationDraft.downloadEnabled
        launchAtLoginButton.state = automationDraft.launchAtLoginEnabled ? .on : .off
        launchAtLoginButton.isEnabled = true

        if automationDraft.launchAtLoginEnabled != currentLaunchAtLoginEnabled {
            launchStatusLabel.stringValue = automationDraft.launchAtLoginEnabled
                ? "尚未保存，保存后启用"
                : "尚未保存，保存后关闭"
        } else {
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
        automationSaveButton.isEnabled = automationDraft != automationBaseline
    }

    private var currentLaunchAtLoginEnabled: Bool {
        switch launchService.status {
        case .enabled, .requiresApproval: true
        case .disabled, .unavailable: false
        }
    }

    private func persistedDisplayConfiguration() -> DisplayConfigurationDraft {
        DisplayConfigurationDraft(
            mode: settings.configurationMode,
            sharedProfile: settings.sharedProfile,
            displayAssignments: settings.displayAssignments
        )
    }

    private func persistedAutomationConfiguration() -> AutomationConfigurationDraft {
        AutomationConfigurationDraft(
            downloadEnabled: settings.automaticDailyDownloadEnabled,
            applyEnabled: settings.automaticDailyApplyEnabled,
            launchAtLoginEnabled: currentLaunchAtLoginEnabled
        )
    }

    private var selectedDisplayUUID: String? {
        displayPopup.selectedItem?.representedObject as? String
    }

    private func updateDisplayDetails() {
        guard let uuid = selectedDisplayUUID, let display = displayRegistry.displays.first(where: { $0.uuid == uuid }) else {
            displayDetailsLabel.stringValue = "未检测到显示器"
            refreshDisplayRuleSummary(display: nil)
            return
        }
        displayDetailsLabel.stringValue = "逻辑尺寸 \(display.logicalWidth)x\(display.logicalHeight) · 像素 \(display.pixelWidth)x\(display.pixelHeight)"
        refreshDisplayRuleSummary(display: display)
    }

    private func refreshDisplayRuleSummary(display: DisplayDescriptor?) {
        if displayDraft.mode == .shared {
            displayRuleTitleLabel.stringValue = "全部显示器"
            let count = displayRegistry.displays.count
            displayRuleSubtitleLabel.stringValue = count > 0
                ? "已连接 \(count) 台显示器，共用以下壁纸规则"
                : "当前没有检测到显示器"
            return
        }

        guard let display else {
            displayRuleTitleLabel.stringValue = "单独配置"
            displayRuleSubtitleLabel.stringValue = "当前没有检测到显示器"
            return
        }
        displayRuleTitleLabel.stringValue = display.localizedName
        let role = display.isMain ? "主显示器" : "已连接显示器"
        displayRuleSubtitleLabel.stringValue = "\(role) · \(display.pixelWidth)x\(display.pixelHeight) 像素"
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
    @objc private func settingsChanged() {
        synchronizeDraftsFromPersistence()
        refreshAll()
    }

    private func synchronizeDraftsFromPersistence() {
        let previousDisplayBaseline = displayBaseline
        let previousAutomationBaseline = automationBaseline
        let persistedDisplay = persistedDisplayConfiguration()
        let persistedAutomation = persistedAutomationConfiguration()

        // 按字段做三方合并，避免一个脏字段冻结整份草稿并覆盖其他入口刚提交的配置。
        displayDraft = DisplayConfigurationDraft(
            mode: mergePreferenceDraftValue(
                draft: displayDraft.mode,
                previousBaseline: previousDisplayBaseline.mode,
                persisted: persistedDisplay.mode
            ),
            sharedProfile: mergePreferenceDraftValue(
                draft: displayDraft.sharedProfile,
                previousBaseline: previousDisplayBaseline.sharedProfile,
                persisted: persistedDisplay.sharedProfile
            ),
            displayAssignments: mergePreferenceDraftValue(
                draft: displayDraft.displayAssignments,
                previousBaseline: previousDisplayBaseline.displayAssignments,
                persisted: persistedDisplay.displayAssignments
            )
        )

        let mergedApply = mergePreferenceDraftValue(
            draft: automationDraft.applyEnabled,
            previousBaseline: previousAutomationBaseline.applyEnabled,
            persisted: persistedAutomation.applyEnabled
        )
        let mergedDownload = mergePreferenceDraftValue(
            draft: automationDraft.downloadEnabled,
            previousBaseline: previousAutomationBaseline.downloadEnabled,
            persisted: persistedAutomation.downloadEnabled
        )
        automationDraft = AutomationConfigurationDraft(
            // 自动更换依赖自动下载；三方合并后再次归一化，不能让页面短暂进入无效组合。
            downloadEnabled: mergedDownload || mergedApply,
            applyEnabled: mergedApply,
            launchAtLoginEnabled: mergePreferenceDraftValue(
                draft: automationDraft.launchAtLoginEnabled,
                previousBaseline: previousAutomationBaseline.launchAtLoginEnabled,
                persisted: persistedAutomation.launchAtLoginEnabled
            )
        )
        displayBaseline = persistedDisplay
        automationBaseline = persistedAutomation
    }
    @objc private func libraryDidChange() { refreshDirectories() }

    @objc private func modeCardTapped(_ sender: NSControl) {
        let mode: DisplayConfigurationMode = sender === individualModeCard ? .individual : .shared
        guard displayDraft.mode != mode else { return }
        displayDraft.mode = mode
        sharedModeCard.isChosen = mode == .shared
        individualModeCard.isChosen = mode == .individual
        refreshDisplays()
        refreshProfileControls()
    }

    @objc private func selectedDisplayChanged() {
        updateDisplayDetails()
        refreshProfileControls()
    }

    /// 控件变化只更新页面草稿，点击“保存更改”后才一次性提交。
    @objc private func profileChanged() {
        let profile = currentEditedProfile()
        if displayDraft.mode == .shared {
            displayDraft.sharedProfile = profile
        } else if let uuid = selectedDisplayUUID {
            displayDraft.displayAssignments[uuid] = profile
        }
        refreshDisplaySaveState()
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

    /// 草稿阶段也保持下载/更换联动，避免保存出无效组合。
    @objc private func automaticDownloadChanged() {
        automationDraft.downloadEnabled = dailyDownloadButton.state == .on
        if !automationDraft.downloadEnabled {
            automationDraft.applyEnabled = false
        }
        refreshAutomationControls()
    }

    @objc private func automaticApplyChanged() {
        automationDraft.applyEnabled = dailyApplyButton.state == .on
        if automationDraft.applyEnabled {
            automationDraft.downloadEnabled = true
        }
        refreshAutomationControls()
    }

    @objc private func launchAtLoginChanged() {
        automationDraft.launchAtLoginEnabled = launchAtLoginButton.state == .on
        refreshAutomationControls()
    }

    @objc private func saveDisplayChanges() {
        guard displayDraft != displayBaseline else { return }
        settings.saveDisplayConfiguration(
            mode: displayDraft.mode,
            sharedProfile: displayDraft.sharedProfile,
            displayAssignments: displayDraft.displayAssignments
        )
        displayBaseline = persistedDisplayConfiguration()
        displayDraft = displayBaseline
        refreshAll()
    }

    @objc private func saveAutomationChanges() {
        guard automationDraft != automationBaseline else { return }
        do {
            // 登录项注册可能失败，先完成它再写每日任务配置，避免只保存一半。
            if automationDraft.launchAtLoginEnabled != currentLaunchAtLoginEnabled {
                try launchService.setEnabled(automationDraft.launchAtLoginEnabled)
            }
            settings.saveAutomationConfiguration(
                downloadEnabled: automationDraft.downloadEnabled,
                applyEnabled: automationDraft.applyEnabled
            )
            automationBaseline = persistedAutomationConfiguration()
            automationDraft = automationBaseline
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

        // 设置页内容高度会随显示器模式变化。使用系统滚动容器兜住最小窗口，
        // 避免独立模式的表单或底部保存区被压缩，同时不引入任何常驻定时器。
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // AppKit 普通 NSView 的坐标原点在左下角；翻转文档视图可确保滚动位置从页面标题开始。
        let documentView = SettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        documentView.addSubview(stack)

        // 宽窗口使用舒适的阅读列，窄窗口则在保留 28pt 边距的前提下自动收缩。
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 820)
        preferredWidth.priority = NSLayoutConstraint.Priority(751)
        let fillAvailableWidth = stack.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -56)
        fillAvailableWidth.priority = .defaultHigh

        // 内容较少时文档视图至少铺满可视区域；内容较多时则按 stack 的自然高度扩展并滚动。
        let fitViewportHeight = documentView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor)
        fitViewportHeight.priority = .defaultHigh
        let fitContentHeight = documentView.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 28)
        // 短页面保留底部自然留白，不要为了贴满视口把纵向 Stack 的内容间距拉开；
        // 当内容高于视口时，必需的边界约束会打破视口等高约束，再由此约束撑开文档高度。
        fitContentHeight.priority = NSLayoutConstraint.Priority(249)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            fitViewportHeight,

            stack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -28),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
            preferredWidth,
            fillAvailableWidth,
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -28),
            fitContentHeight
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

    private func configureSaveButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.keyEquivalent = "\r"
        button.isEnabled = false
    }

    private func trailingActionRow(_ button: NSButton) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func displayRuleHeader() -> NSStackView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        displayRuleTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        displayRuleSubtitleLabel.font = .systemFont(ofSize: 11)
        displayRuleSubtitleLabel.textColor = .secondaryLabelColor
        displayRuleSubtitleLabel.maximumNumberOfLines = 2
        let labels = NSStackView(views: [displayRuleTitleLabel, displayRuleSubtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, labels, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func centeredContentRow(_ content: NSView) -> NSStackView {
        let leadingSpacer = NSView()
        let trailingSpacer = NSView()
        leadingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [leadingSpacer, content, trailingSpacer])
        // 两个占位视图进入同一个视图树后再激活约束，避免 AppKit 因没有共同祖先而抛出异常。
        leadingSpacer.widthAnchor.constraint(equalTo: trailingSpacer.widthAnchor).isActive = true
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 0
        return row
    }

    private func settingsActionFooter(status: NSTextField, button: NSButton) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [status, spacer, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func separatorView() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    /// 原生玻璃质感的分组卡片，承载一组相关设置行。
    private func sectionCard(_ views: [NSView], spacing: CGFloat = 10) -> NSView {
        let card = GlassCardView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .followsWindowActiveState
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = spacing
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
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

/// 玻璃分组卡片：在 updateLayer 中刷新描边色，随系统深浅色自动适配。
@MainActor
private final class GlassCardView: NSVisualEffectView {
    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// 设置页滚动文档使用左上角原点，首次进入页面时始终从标题开始显示。
@MainActor
private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// 卡片式单选项：玻璃底 + 图标 + 标题/副标题，选中态用 accent 描边。
@MainActor
private final class OptionCardButton: NSButton {
    private let background = NSVisualEffectView()
    private let iconView = NSImageView()
    private let checkView = NSImageView()

    var isChosen = false {
        didSet {
            state = isChosen ? .on : .off
            updateAppearance()
        }
    }

    init(title: String, subtitle: String, symbolName: String) {
        super.init(frame: .zero)
        setButtonType(.radio)
        isBordered = false
        self.title = ""
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        background.material = .contentBackground
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [titleLabel, subtitleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        // 选中对勾固定占位，切换时卡片宽度不抖动。
        checkView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        checkView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        checkView.contentTintColor = .controlAccentColor
        checkView.setContentHuggingPriority(.required, for: .horizontal)

        let content = NSStackView(views: [iconView, texts, checkView])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        setAccessibilityLabel(title)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 所有子视图都只是装饰，命中测试统一交给真正的 NSButton，保留键盘与 VoiceOver 原生语义。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, isEnabled, super.hitTest(point) != nil else { return nil }
        return self
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let borderColor: NSColor = isChosen ? .controlAccentColor : .separatorColor
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.borderColor = borderColor.cgColor
        }
        layer?.borderWidth = isChosen ? 2 : 0.5
        iconView.contentTintColor = isChosen ? .controlAccentColor : .secondaryLabelColor
        checkView.isHidden = !isChosen
        alphaValue = isEnabled ? 1 : 0.55
    }
}
