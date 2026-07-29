import AppKit

@MainActor
final class MediaLibraryViewController: NSViewController,
    NSCollectionViewDataSource,
    NSCollectionViewDelegate,
    NSCollectionViewPrefetching
{
    var onImportRequested: (() -> Void)?
    var onSetWallpaper: ((MediaLibraryItem, [String]?) -> Void)?
    var onDeleteRequested: ((MediaLibraryItem) async throws -> Void)?

    private let index: MediaLibraryIndex
    private let directoryManager: DownloadDirectoryManager
    private let displayRegistry: DisplayRegistry
    private let settings: SettingsStore
    private let thumbnailService = ThumbnailService()

    private let pageSelector = NSSegmentedControl(
        labels: ["媒体库", "今日壁纸"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let todayMarketSelector = NSSegmentedControl(
        labels: ["全部"] + BingMarket.allCases.map(\.localizedName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let sourcePopup = NSPopUpButton()
    private let marketPopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let sortPopup = NSPopUpButton()
    private let searchField = NSSearchField()
    private let currentWallpaperStatusView = CurrentWallpaperStatusView()
    private lazy var toast = ToastPresenter(hostView: view)
    private let emptyStateView = NSStackView()
    private let emptyIconView = NSImageView()
    private let emptyTitleLabel = NSTextField(labelWithString: "媒体库中还没有图片")
    private let emptySubtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyActionButton = NSButton(title: "导入图片…", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let collectionView = ContextCollectionView()
    private let layout = MasonryCollectionViewLayout()

    private var items: [MediaLibraryItem] = []
    private var cursor: MediaLibraryCursor?
    private var reachedEnd = false
    private var isLoading = false
    private var pageTask: Task<Void, Never>?
    private var facetsTask: Task<Void, Never>?
    private var pageGeneration: UInt64 = 0
    private var facetsGeneration: UInt64 = 0
    private var prefetchTokens: [IndexPath: UUID] = [:]
    private var resolutions: [PixelSize] = []
    private var wallpaperActionsEnabled = true
    private var isImportInProgress = false
    private var isLibraryDeletionInProgress = false
    private var isActive = true
    private var isShutDown = false
    private var previewOverlay: ImagePreviewOverlayView?
    private var deletingItemIDs: Set<Int64> = []
    // 保留显示器与系统实际壁纸的完整关系，不能压缩成内容 SHA 集合。
    private var currentWallpaperStatuses: [CurrentDisplayWallpaperStatus] = []

    init(
        index: MediaLibraryIndex,
        directoryManager: DownloadDirectoryManager,
        displayRegistry: DisplayRegistry,
        settings: SettingsStore
    ) {
        self.index = index
        self.directoryManager = directoryManager
        self.displayRegistry = displayRegistry
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        _ = view
        refreshCurrentWallpaperStatus()
        loadFacets()
        reloadFromBeginning()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        buildContent()
    }

    /// 主窗口关闭时立即释放分页任务和缩略图缓存，让菜单栏常驻阶段保持低内存。
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        isActive = false
        releaseLoadedResources()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// 切换到设置页时暂停媒体库，避免隐藏页面继续占用缩略图缓存。
    func suspend() {
        guard !isShutDown, isActive else { return }
        isActive = false
        releaseLoadedResources()
    }

    func resume() {
        guard !isShutDown, !isActive else { return }
        isActive = true
        emptyStateView.isHidden = true
        displayRegistry.refresh()
        refreshCurrentWallpaperStatus()
        loadFacets()
        reloadFromBeginning()
    }

    func setWallpaperActionsEnabled(_ isEnabled: Bool) {
        wallpaperActionsEnabled = isEnabled
    }

    func setImportInProgress(_ isInProgress: Bool) {
        isImportInProgress = isInProgress
        // 同一个空态按钮也用于清除筛选；导入中只禁用“导入图片”动作。
        if emptyActionButton.action == #selector(importPressed) {
            emptyActionButton.isEnabled = !isInProgress
        }
    }

    func setLibraryDeletionInProgress(_ isInProgress: Bool) {
        isLibraryDeletionInProgress = isInProgress
    }

    private func releaseLoadedResources() {
        pageTask?.cancel()
        pageTask = nil
        facetsTask?.cancel()
        facetsTask = nil
        pageGeneration &+= 1
        facetsGeneration &+= 1
        isLoading = false
        let tokens = Array(prefetchTokens.values)
        prefetchTokens.removeAll()
        tokens.forEach(thumbnailService.cancel)
        thumbnailService.close()
        items.removeAll()
        cursor = nil
        reachedEnd = false
        collectionView.reloadData()
        layout.invalidateLayout()
        toast.dismiss(immediately: true)
        previewOverlay?.dismiss(immediately: true)
        currentWallpaperStatuses.removeAll()
        currentWallpaperStatusView.clear()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        guard
            indexPath.item < items.count,
            let itemView = collectionView.makeItem(
                withIdentifier: NSUserInterfaceItemIdentifier("MediaLibraryCollectionItem"),
                for: indexPath
            ) as? MediaLibraryCollectionItem
        else { return NSCollectionViewItem() }

        let item = items[indexPath.item]
        let fileURL = try? directoryManager.imageURL(rootID: item.rootID, relativePath: item.relativeImagePath)
        itemView.configure(
            item: item,
            fileURL: fileURL,
            thumbnailService: thumbnailService,
            currentDisplayNames: currentDisplayNames(for: fileURL)
        )
        return itemView
    }

    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard isActive else { return }
        for indexPath in indexPaths where indexPath.item < items.count && prefetchTokens[indexPath] == nil {
            let item = items[indexPath.item]
            guard let url = try? directoryManager.imageURL(rootID: item.rootID, relativePath: item.relativeImagePath) else { continue }
            var didCompleteSynchronously = false
            let token = thumbnailService.requestThumbnail(
                fileURL: url,
                contentSHA256: item.contentSHA256,
                size: CGSize(
                    width: AppConstants.mediaLibraryThumbnailPointSize,
                    height: AppConstants.mediaLibraryThumbnailPointSize
                ),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                completion: { [weak self] _ in
                    didCompleteSynchronously = true
                    self?.prefetchTokens.removeValue(forKey: indexPath)
                }
            )
            // 内存缓存命中时 completion 会同步执行，不能留下一个已经完成的假 token。
            if !didCompleteSynchronously {
                prefetchTokens[indexPath] = token
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            if let token = prefetchTokens.removeValue(forKey: indexPath) {
                thumbnailService.cancel(token)
            }
        }
    }

    private func buildContent() {
        let contentView = view

        pageSelector.selectedSegment = 0
        pageSelector.target = self
        pageSelector.action = #selector(pageChanged)
        pageSelector.setAccessibilityLabel("媒体库页面")
        pageSelector.setToolTip("浏览全部媒体库", forSegment: 0)
        pageSelector.setToolTip("浏览各国家今天已下载的必应壁纸", forSegment: 1)

        todayMarketSelector.selectedSegment = 0
        todayMarketSelector.target = self
        todayMarketSelector.action = #selector(filtersChanged)
        todayMarketSelector.setAccessibilityLabel("今日壁纸国家")
        todayMarketSelector.setToolTip("全部国家", forSegment: 0)
        for (offset, market) in BingMarket.allCases.enumerated() {
            todayMarketSelector.setToolTip(market.rawValue, forSegment: offset + 1)
        }

        sourcePopup.addItems(withTitles: ["全部来源", "Bing", "外部导入"])
        marketPopup.addItem(withTitle: "全部国家/地区")
        resolutionPopup.addItem(withTitle: "全部分辨率")
        sortPopup.addItems(withTitles: ["最新内容优先", "最早内容优先", "最近导入优先"])
        searchField.placeholderString = "搜索标题或版权"
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true

        [sourcePopup, marketPopup, resolutionPopup, sortPopup, searchField].forEach {
            $0.target = self
            $0.action = #selector(filtersChanged)
        }
        sourcePopup.toolTip = "来源"
        marketPopup.toolTip = "国家或地区"
        resolutionPopup.toolTip = "分辨率"
        sortPopup.toolTip = "排序"

        let pageSpacer = NSView()
        pageSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let pageBar = NSStackView(views: [pageSelector, pageSpacer])
        pageBar.orientation = .horizontal
        pageBar.alignment = .centerY
        pageBar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 6, right: 14)
        pageBar.translatesAutoresizingMaskIntoConstraints = false
        pageSelector.widthAnchor.constraint(equalToConstant: 220).isActive = true

        // 导入入口由主窗口工具栏统一提供；今日页只替换来源、国家和排序控件。
        let toolbar = NSStackView(views: [
            sourcePopup,
            marketPopup,
            todayMarketSelector,
            resolutionPopup,
            sortPopup,
            searchField
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        todayMarketSelector.widthAnchor.constraint(equalToConstant: 350).isActive = true
        todayMarketSelector.isHidden = true

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.windowBackgroundColor]
        collectionView.register(
            MediaLibraryCollectionItem.self,
            forItemWithIdentifier: NSUserInterfaceItemIdentifier("MediaLibraryCollectionItem")
        )
        collectionView.contextMenuProvider = { [weak self] indexPath in self?.menu(for: indexPath) }
        // 双击进入应用内预览页，右键菜单仍可用系统方式打开原图。
        collectionView.doubleClickHandler = { [weak self] indexPath in self?.presentPreview(startingAt: indexPath.item) }

        layout.aspectRatioProvider = { [weak self] indexPath in
            guard let self, indexPath.item < self.items.count else { return 1 }
            return self.items[indexPath.item].aspectRatio
        }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(libraryDidChange),
            name: .dailyWallpaperLibraryDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .dailyWallpaperSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(currentWallpaperContextChanged),
            name: .dailyWallpaperDisplaysDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(currentWallpaperContextChanged),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(currentWallpaperContextChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        // 空状态：大图标 + 标题/副标题 + 引导按钮，区分“库为空”与“筛选无结果”。
        emptyIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
        emptyIconView.contentTintColor = .tertiaryLabelColor
        emptyTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        emptyTitleLabel.alignment = .center
        emptySubtitleLabel.font = .systemFont(ofSize: 12)
        emptySubtitleLabel.textColor = .secondaryLabelColor
        emptySubtitleLabel.alignment = .center
        emptySubtitleLabel.maximumNumberOfLines = 2
        emptyActionButton.bezelStyle = .rounded
        emptyActionButton.controlSize = .large
        emptyActionButton.keyEquivalent = "\r"
        emptyActionButton.target = self
        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 8
        emptyStateView.setViews([emptyIconView, emptyTitleLabel, emptySubtitleLabel, emptyActionButton], in: .center)
        emptyStateView.setCustomSpacing(14, after: emptyIconView)
        emptyStateView.setCustomSpacing(18, after: emptySubtitleLabel)
        emptyStateView.isHidden = true
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        // 加载反馈改用底部玻璃 toast，不再常驻左下角小字。
        currentWallpaperStatusView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(currentWallpaperStatusView)
        contentView.addSubview(pageBar)
        contentView.addSubview(toolbar)
        contentView.addSubview(scrollView)
        contentView.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            currentWallpaperStatusView.topAnchor.constraint(equalTo: contentView.topAnchor),
            currentWallpaperStatusView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            currentWallpaperStatusView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            currentWallpaperStatusView.heightAnchor.constraint(equalToConstant: 116),
            pageBar.topAnchor.constraint(equalTo: currentWallpaperStatusView.bottomAnchor),
            pageBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pageBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: pageBar.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            emptyStateView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -20)
        ])
    }

    /// 根据当前筛选状态切换空态文案与引导动作，并控制显隐。
    private func updateEmptyState() {
        guard items.isEmpty, isActive else {
            emptyStateView.isHidden = true
            return
        }
        let isTodayPage = pageSelector.selectedSegment == 1
        let isFiltered = if isTodayPage {
            todayMarketSelector.selectedSegment > 0
                || resolutionPopup.indexOfSelectedItem > 0
                || !searchField.stringValue.isEmpty
        } else {
            sourcePopup.indexOfSelectedItem > 0
                || marketPopup.indexOfSelectedItem > 0
                || resolutionPopup.indexOfSelectedItem > 0
                || !searchField.stringValue.isEmpty
        }
        if isFiltered {
            emptyIconView.image = NSImage(
                systemSymbolName: "magnifyingglass",
                accessibilityDescription: "没有符合条件的图片"
            )
            emptyTitleLabel.stringValue = isTodayPage ? "这个国家今天还没有壁纸" : "当前筛选没有结果"
            emptySubtitleLabel.stringValue = isTodayPage
                ? "当前国家没有已下载的今日必应图片。"
                : "试试放宽来源、分辨率或搜索条件。"
            emptyActionButton.title = "清除筛选条件"
            emptyActionButton.action = #selector(clearFilters)
            emptyActionButton.isEnabled = true
        } else if isTodayPage {
            emptyIconView.image = NSImage(
                systemSymbolName: "calendar",
                accessibilityDescription: "今日壁纸为空"
            )
            emptyTitleLabel.stringValue = "今天还没有已下载的壁纸"
            emptySubtitleLabel.stringValue = "各国家的今日图片会分别保存在这里。"
            emptyActionButton.title = "返回媒体库"
            emptyActionButton.action = #selector(showLibraryPage)
            emptyActionButton.isEnabled = true
        } else {
            emptyIconView.image = NSImage(
                systemSymbolName: "photo.on.rectangle.angled",
                accessibilityDescription: "媒体库为空"
            )
            emptyTitleLabel.stringValue = "媒体库中还没有图片"
            emptySubtitleLabel.stringValue = "下载今日必应图片，或从本地导入你喜欢的壁纸。"
            emptyActionButton.title = "导入图片…"
            emptyActionButton.action = #selector(importPressed)
            emptyActionButton.isEnabled = !isImportInProgress
        }
        emptyStateView.isHidden = false
        if !DesignTokens.reduceMotion {
            emptyStateView.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = DesignTokens.animationNormal
                self.emptyStateView.animator().alphaValue = 1
            }, completionHandler: nil)
        }
    }

    private func loadFacets() {
        guard isActive else { return }
        facetsTask?.cancel()
        facetsGeneration &+= 1
        let generation = facetsGeneration
        let index = self.index
        facetsTask = Task { [weak self] in
            do {
                let facets = try await index.facets()
                guard
                    let self,
                    !Task.isCancelled,
                    generation == self.facetsGeneration
                else { return }
                let selectedMarket = marketPopup.indexOfSelectedItem > 0 ? marketPopup.titleOfSelectedItem : nil
                let selectedResolution = resolutionPopup.indexOfSelectedItem > 0 ? resolutionPopup.titleOfSelectedItem : nil
                var selectionWasInvalidated = false

                marketPopup.removeAllItems()
                marketPopup.addItem(withTitle: "全部国家/地区")
                marketPopup.addItems(withTitles: facets.markets)
                if let selectedMarket, facets.markets.contains(selectedMarket) {
                    marketPopup.selectItem(withTitle: selectedMarket)
                } else if selectedMarket != nil {
                    selectionWasInvalidated = true
                }
                resolutions = facets.resolutions
                resolutionPopup.removeAllItems()
                resolutionPopup.addItem(withTitle: "全部分辨率")
                resolutionPopup.addItems(withTitles: facets.resolutions.map(\.label))
                if let selectedResolution, facets.resolutions.map(\.label).contains(selectedResolution) {
                    resolutionPopup.selectItem(withTitle: selectedResolution)
                } else if selectedResolution != nil {
                    selectionWasInvalidated = true
                }
                facetsTask = nil
                if selectionWasInvalidated {
                    reloadFromBeginning()
                }
            } catch {
                guard
                    let self,
                    !Task.isCancelled,
                    generation == self.facetsGeneration
                else { return }
                toast.show("筛选选项加载失败：\(error.localizedDescription)", style: .failure)
                facetsTask = nil
            }
        }
    }

    private func reloadFromBeginning() {
        guard isActive else { return }
        pageTask?.cancel()
        pageTask = nil
        pageGeneration &+= 1
        isLoading = false
        items.removeAll(keepingCapacity: true)
        cursor = nil
        reachedEnd = false
        let tokens = Array(prefetchTokens.values)
        prefetchTokens.removeAll()
        tokens.forEach(thumbnailService.cancel)
        collectionView.reloadData()
        layout.invalidateLayout()
        loadNextPage()
    }

    private func loadNextPage() {
        guard isActive, !isLoading, !reachedEnd else { return }
        isLoading = true
        let query = currentQuery()
        let requestedCursor = cursor
        let generation = pageGeneration
        let index = self.index

        pageTask = Task { [weak self] in
            do {
                let page = try await index.page(query: query, after: requestedCursor)
                guard
                    let self,
                    !Task.isCancelled,
                    generation == self.pageGeneration
                else { return }
                let previousCount = items.count
                items.append(contentsOf: page.items)
                cursor = page.nextCursor
                reachedEnd = page.reachedEnd
                isLoading = false
                pageTask = nil
                // 首页整体刷新；后续分页增量插入，新卡片渐显入场且不打断滚动。
                if requestedCursor == nil || page.items.isEmpty || DesignTokens.reduceMotion {
                    collectionView.reloadData()
                    layout.invalidateLayout()
                } else {
                    let inserted = Set((previousCount ..< items.count).map { IndexPath(item: $0, section: 0) })
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = DesignTokens.animationNormal
                        self.collectionView.animator().performBatchUpdates({
                            self.collectionView.insertItems(at: inserted)
                        }, completionHandler: nil)
                    }, completionHandler: nil)
                }
                updateEmptyState()
                // 首页加载完成或到达末尾时给一次性提示；滚动分页途中不打扰。
                if !items.isEmpty {
                    if requestedCursor == nil {
                        toast.show(reachedEnd ? "共 \(items.count) 张图片" : "已加载 \(items.count) 张图片")
                    } else if reachedEnd {
                        toast.show("已加载全部 \(items.count) 张图片")
                    }
                }
            } catch {
                guard
                    let self,
                    !Task.isCancelled,
                    generation == self.pageGeneration
                else { return }
                isLoading = false
                pageTask = nil
                updateEmptyState()
                toast.show("加载失败：\(error.localizedDescription)", style: .failure)
            }
        }
    }

    private func currentQuery() -> MediaLibraryQuery {
        if pageSelector.selectedSegment == 1 {
            let selectedMarket: String? = if todayMarketSelector.selectedSegment > 0 {
                BingMarket.allCases[todayMarketSelector.selectedSegment - 1].rawValue
            } else {
                nil
            }
            let resolution = resolutionPopup.indexOfSelectedItem > 0
                && resolutionPopup.indexOfSelectedItem - 1 < resolutions.count
                ? resolutions[resolutionPopup.indexOfSelectedItem - 1]
                : nil
            return MediaLibraryQuery(
                sourceType: .bing,
                market: selectedMarket,
                contentDay: LocalDay.key(),
                pixelWidth: resolution?.width,
                pixelHeight: resolution?.height,
                searchText: searchField.stringValue,
                sortOrder: .newestContent
            )
        }

        let sourceType: WallpaperSourceType? = switch sourcePopup.indexOfSelectedItem {
        case 1: .bing
        case 2: .imported
        default: nil
        }
        let market = marketPopup.indexOfSelectedItem > 0 ? marketPopup.titleOfSelectedItem : nil
        let resolution = resolutionPopup.indexOfSelectedItem > 0 && resolutionPopup.indexOfSelectedItem - 1 < resolutions.count
            ? resolutions[resolutionPopup.indexOfSelectedItem - 1]
            : nil
        let sortOrder: MediaSortOrder = switch sortPopup.indexOfSelectedItem {
        case 1: .oldestContent
        case 2: .recentlyAdded
        default: .newestContent
        }
        return MediaLibraryQuery(
            sourceType: sourceType,
            market: market,
            pixelWidth: resolution?.width,
            pixelHeight: resolution?.height,
            searchText: searchField.stringValue,
            sortOrder: sortOrder
        )
    }

    private func menu(for indexPath: IndexPath) -> NSMenu? {
        guard indexPath.item < items.count else { return nil }
        collectionView.selectionIndexPaths = [indexPath]
        let item = items[indexPath.item]
        let menu = NSMenu()
        // 各动作的忙碌状态由控制器统一维护，避免 AppKit 自动校验重新启用删除项。
        menu.autoenablesItems = false
        menu.addItem(actionItem(title: "打开原图", action: #selector(openSelectedImage), representedObject: item.id))
        menu.addItem(actionItem(title: "在访达中显示", action: #selector(revealSelectedImage), representedObject: item.id))
        menu.addItem(.separator())
        let applyAllItem = actionItem(title: "设为全部显示器壁纸", action: #selector(setForAllDisplays), representedObject: item.id)
        applyAllItem.isEnabled = wallpaperActionsEnabled
        menu.addItem(applyAllItem)

        let displaysItem = NSMenuItem(title: "设为指定显示器壁纸", action: nil, keyEquivalent: "")
        let displaysMenu = NSMenu()
        for display in displayRegistry.displays {
            let displayItem = actionItem(
                title: display.localizedName,
                action: #selector(setForDisplay(_:)),
                representedObject: ["itemID": item.id, "displayUUID": display.uuid]
            )
            displayItem.isEnabled = wallpaperActionsEnabled
            displaysMenu.addItem(displayItem)
        }
        displaysItem.isEnabled = wallpaperActionsEnabled
        displaysItem.submenu = displaysMenu
        menu.addItem(displaysItem)
        if !item.copyrightText.isEmpty {
            menu.addItem(.separator())
            menu.addItem(actionItem(title: "复制版权信息", action: #selector(copyCopyright), representedObject: item.id))
        }
        menu.addItem(.separator())
        let deleteItem = actionItem(
            title: "删除图片…",
            action: #selector(deleteSelectedImage(_:)),
            representedObject: item.id
        )
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除图片")
        deleteItem.isEnabled = wallpaperActionsEnabled
            && !isImportInProgress
            && !isLibraryDeletionInProgress
            && !deletingItemIDs.contains(item.id)
            && onDeleteRequested != nil
        menu.addItem(deleteItem)
        return menu
    }

    private func actionItem(title: String, action: Selector, representedObject: Any) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = representedObject
        return menuItem
    }

    private func selectedItem(id: Int64? = nil) -> MediaLibraryItem? {
        if let id { return items.first(where: { $0.id == id }) }
        guard let indexPath = collectionView.selectionIndexPaths.first, indexPath.item < items.count else { return nil }
        return items[indexPath.item]
    }

    @objc private func filtersChanged() { reloadFromBeginning() }

    @objc private func pageChanged() {
        let isTodayPage = pageSelector.selectedSegment == 1
        sourcePopup.isHidden = isTodayPage
        marketPopup.isHidden = isTodayPage
        sortPopup.isHidden = isTodayPage
        todayMarketSelector.isHidden = !isTodayPage
        searchField.placeholderString = isTodayPage ? "搜索今日标题或介绍" : "搜索标题或版权"
        reloadFromBeginning()
    }

    private func presentPreview(startingAt index: Int) {
        guard isActive, previewOverlay == nil, items.indices.contains(index) else { return }
        let query = currentQuery()
        let libraryIndex = self.index
        let overlay = ImagePreviewOverlayView(
            items: items,
            startIndex: index,
            nextCursor: cursor,
            reachedEnd: reachedEnd,
            thumbnailService: thumbnailService,
            fileURLProvider: { [directoryManager] item in
                try? directoryManager.imageURL(rootID: item.rootID, relativePath: item.relativeImagePath)
            },
            pageLoader: { [libraryIndex] cursor in
                try await libraryIndex.page(query: query, after: cursor)
            }
        )
        overlay.onDismiss = { [weak self] in
            guard let self else { return }
            previewOverlay = nil
            view.window?.makeFirstResponder(collectionView)
        }
        previewOverlay = overlay
        overlay.present(in: view)
    }

    @objc private func clearFilters() {
        if pageSelector.selectedSegment == 1 {
            todayMarketSelector.selectedSegment = 0
        } else {
            sourcePopup.selectItem(at: 0)
            marketPopup.selectItem(at: 0)
        }
        resolutionPopup.selectItem(at: 0)
        searchField.stringValue = ""
        reloadFromBeginning()
    }

    @objc private func showLibraryPage() {
        pageSelector.selectedSegment = 0
        pageChanged()
    }
    @objc private func importPressed() {
        guard !isImportInProgress else { return }
        onImportRequested?()
    }
    @objc private func libraryDidChange() {
        guard isActive else { return }
        loadFacets()
        reloadFromBeginning()
    }

    /// 配置或壁纸记录变化后重新读取系统实际状态，避免把历史记录误称为当前壁纸。
    @objc private func settingsDidChange() {
        refreshCurrentWallpaperStatus()
    }

    @objc private func currentWallpaperContextChanged() {
        guard isActive else { return }
        refreshCurrentWallpaperStatus()
    }

    private func refreshCurrentWallpaperStatus() {
        guard isActive else { return }
        let records = settings.currentImageByDisplayUUID
        let statuses = displayRegistry.displays.map { display in
            let actualURL = displayRegistry.screen(for: display.uuid)
                .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            let record = records[display.uuid]
            let recordedURL = record.flatMap {
                try? directoryManager.imageURL(rootID: $0.rootID, relativePath: $0.relativeImagePath)
            }
            let verification: CurrentWallpaperVerification
            if let actualURL, FileManager.default.fileExists(atPath: actualURL.path) {
                verification = CurrentWallpaperURLMatcher.matches(actualURL, recordedURL) ? .managed : .external
            } else {
                verification = .unavailable
            }
            return CurrentDisplayWallpaperStatus(
                displayUUID: display.uuid,
                displayName: display.localizedName,
                isMainDisplay: display.isMain,
                actualURL: actualURL,
                actualFileFingerprint: actualURL.flatMap {
                    CurrentWallpaperFileFingerprint.read(from: $0)
                },
                managedRecord: record,
                verification: verification
            )
        }
        guard statuses != currentWallpaperStatuses else { return }
        currentWallpaperStatuses = statuses
        currentWallpaperStatusView.update(statuses: statuses, thumbnailService: thumbnailService)
        refreshVisibleWallpaperBadges()
    }

    private func refreshVisibleWallpaperBadges() {
        for case let itemView as MediaLibraryCollectionItem in collectionView.visibleItems() {
            guard
                let id = itemView.representedMediaID,
                let item = items.first(where: { $0.id == id })
            else { continue }
            let fileURL = try? directoryManager.imageURL(rootID: item.rootID, relativePath: item.relativeImagePath)
            itemView.setCurrentWallpaperBadge(displayNames: currentDisplayNames(for: fileURL))
        }
    }

    private func currentDisplayNames(for fileURL: URL?) -> [String] {
        currentWallpaperStatuses.compactMap { status in
            guard
                status.verification != .unavailable,
                CurrentWallpaperURLMatcher.matches(status.actualURL, fileURL)
            else { return nil }
            return status.displayName
        }
    }

    @objc private func scrollBoundsChanged() {
        let visibleMaxY = scrollView.contentView.bounds.maxY
        let contentHeight = collectionView.collectionViewLayout?.collectionViewContentSize.height ?? 0
        if contentHeight - visibleMaxY < scrollView.contentView.bounds.height * 1.5 {
            loadNextPage()
        }
    }

    @objc private func openSelectedImage(_ sender: Any? = nil) {
        let id = (sender as? NSMenuItem)?.representedObject as? Int64
        guard let item = selectedItem(id: id), let url = try? directoryManager.imageURL(rootID: item.rootID, relativePath: item.relativeImagePath) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealSelectedImage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64, let item = selectedItem(id: id), let url = try? directoryManager.imageURL(rootID: item.rootID, relativePath: item.relativeImagePath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func setForAllDisplays(_ sender: NSMenuItem) {
        guard wallpaperActionsEnabled else { return }
        guard let id = sender.representedObject as? Int64, let item = selectedItem(id: id) else { return }
        onSetWallpaper?(item, nil)
    }

    @objc private func setForDisplay(_ sender: NSMenuItem) {
        guard wallpaperActionsEnabled else { return }
        guard
            let values = sender.representedObject as? [String: Any],
            let id = values["itemID"] as? Int64,
            let displayUUID = values["displayUUID"] as? String,
            let item = selectedItem(id: id)
        else { return }
        onSetWallpaper?(item, [displayUUID])
    }

    @objc private func copyCopyright(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64, let item = selectedItem(id: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.copyrightText, forType: .string)
    }

    @objc private func deleteSelectedImage(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? Int64,
            let item = selectedItem(id: id),
            !deletingItemIDs.contains(id),
            wallpaperActionsEnabled,
            !isImportInProgress,
            !isLibraryDeletionInProgress
        else { return }

        let fullTitle = item.title.isEmpty ? "未命名图片" : item.title
        let title = String(fullTitle.prefix(80))
        let fileURL = try? directoryManager.imageURL(
            rootID: item.rootID,
            relativePath: item.relativeImagePath
        )
        let displayNames = currentDisplayNames(for: fileURL)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "要删除“\(title)”吗？"
        if displayNames.isEmpty {
            alert.informativeText = "原图和元数据将从媒体库移除，并移到系统废纸篓。"
        } else {
            alert.informativeText = "这张图片当前用于：\(displayNames.joined(separator: "、"))。删除后桌面可能暂时保持当前画面，但本应用将无法继续使用该文件。原图和元数据会移到系统废纸篓。"
        }
        let deleteButton = alert.addButton(withTitle: "移到废纸篓")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDeletion(of: item)
        }
    }

    private func performDeletion(of item: MediaLibraryItem) {
        guard let onDeleteRequested, deletingItemIDs.insert(item.id).inserted else { return }
        Task { [weak self] in
            do {
                try await onDeleteRequested(item)
                guard let self else { return }
                deletingItemIDs.remove(item.id)
                toast.show("已将图片移到废纸篓", style: .success)
            } catch is CancellationError {
                self?.deletingItemIDs.remove(item.id)
            } catch {
                guard let self else { return }
                deletingItemIDs.remove(item.id)
                toast.show("删除失败：\(error.localizedDescription)", style: .failure, duration: 4)
            }
        }
    }
}

@MainActor
private final class ContextCollectionView: NSCollectionView {
    var contextMenuProvider: ((IndexPath) -> NSMenu?)?
    var doubleClickHandler: ((IndexPath) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return }
        doubleClickHandler?(indexPath)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return contextMenuProvider?(indexPath)
    }
}
