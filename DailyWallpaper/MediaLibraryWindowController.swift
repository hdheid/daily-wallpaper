import AppKit

@MainActor
final class MediaLibraryViewController: NSViewController,
    NSCollectionViewDataSource,
    NSCollectionViewDelegate,
    NSCollectionViewPrefetching
{
    var onImportRequested: (() -> Void)?
    var onSetWallpaper: ((MediaLibraryItem, [String]?) -> Void)?

    private let index: MediaLibraryIndex
    private let directoryManager: DownloadDirectoryManager
    private let displayRegistry: DisplayRegistry
    private let thumbnailService = ThumbnailService()

    private let sourcePopup = NSPopUpButton()
    private let marketPopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let sortPopup = NSPopUpButton()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "正在加载…")
    private let emptyStateView = NSStackView()
    private let emptyIconView = NSImageView()
    private let emptyTitleLabel = NSTextField(labelWithString: "媒体库中还没有图片")
    private let emptySubtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyActionButton = NSButton(title: "导入图片…", target: nil, action: nil)
    private let importButton = NSButton(title: "导入", target: nil, action: nil)
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
    private var isActive = true
    private var isShutDown = false

    init(
        index: MediaLibraryIndex,
        directoryManager: DownloadDirectoryManager,
        displayRegistry: DisplayRegistry
    ) {
        self.index = index
        self.directoryManager = directoryManager
        self.displayRegistry = displayRegistry
        super.init(nibName: nil, bundle: nil)
        _ = view
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
        releaseLoadedResources(status: "媒体库已关闭")
        NotificationCenter.default.removeObserver(self)
    }

    /// 切换到设置页时暂停媒体库，避免隐藏页面继续占用缩略图缓存。
    func suspend() {
        guard !isShutDown, isActive else { return }
        isActive = false
        releaseLoadedResources(status: "媒体库已暂停")
    }

    func resume() {
        guard !isShutDown, !isActive else { return }
        isActive = true
        emptyStateView.isHidden = true
        loadFacets()
        reloadFromBeginning()
    }

    func setWallpaperActionsEnabled(_ isEnabled: Bool) {
        wallpaperActionsEnabled = isEnabled
    }

    func setImportInProgress(_ isInProgress: Bool) {
        isImportInProgress = isInProgress
        importButton.isEnabled = !isInProgress
    }

    private func releaseLoadedResources(status: String) {
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
        statusLabel.stringValue = status
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
        itemView.configure(item: item, fileURL: fileURL, thumbnailService: thumbnailService)
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

        importButton.target = self
        importButton.action = #selector(importPressed)
        importButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        importButton.imagePosition = .imageLeading
        importButton.isEnabled = !isImportInProgress

        let toolbar = NSStackView(views: [sourcePopup, marketPopup, resolutionPopup, sortPopup, searchField, importButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

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
        collectionView.doubleClickHandler = { [weak self] _ in self?.openSelectedImage() }

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

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

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

        contentView.addSubview(toolbar)
        contentView.addSubview(scrollView)
        contentView.addSubview(statusLabel)
        contentView.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
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
        let isFiltered = sourcePopup.indexOfSelectedItem > 0
            || marketPopup.indexOfSelectedItem > 0
            || resolutionPopup.indexOfSelectedItem > 0
            || !searchField.stringValue.isEmpty
        if isFiltered {
            emptyIconView.image = NSImage(
                systemSymbolName: "magnifyingglass",
                accessibilityDescription: "没有符合条件的图片"
            )
            emptyTitleLabel.stringValue = "当前筛选没有结果"
            emptySubtitleLabel.stringValue = "试试放宽来源、分辨率或搜索条件。"
            emptyActionButton.title = "清除筛选条件"
            emptyActionButton.action = #selector(clearFilters)
        } else {
            emptyIconView.image = NSImage(
                systemSymbolName: "photo.on.rectangle.angled",
                accessibilityDescription: "媒体库为空"
            )
            emptyTitleLabel.stringValue = "媒体库中还没有图片"
            emptySubtitleLabel.stringValue = "下载今日必应图片，或从本地导入你喜欢的壁纸。"
            emptyActionButton.title = "导入图片…"
            emptyActionButton.action = #selector(importPressed)
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
                statusLabel.stringValue = error.localizedDescription
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
        statusLabel.stringValue = items.isEmpty ? "正在加载…" : "已加载 \(items.count) 张 · 正在加载下一页…"
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
                statusLabel.stringValue = reachedEnd ? "共加载 \(items.count) 张 · 已到末尾" : "已加载 \(items.count) 张"
            } catch {
                guard
                    let self,
                    !Task.isCancelled,
                    generation == self.pageGeneration
                else { return }
                isLoading = false
                pageTask = nil
                updateEmptyState()
                statusLabel.stringValue = "加载失败：\(error.localizedDescription)"
            }
        }
    }

    private func currentQuery() -> MediaLibraryQuery {
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
    @objc private func clearFilters() {
        sourcePopup.selectItem(at: 0)
        marketPopup.selectItem(at: 0)
        resolutionPopup.selectItem(at: 0)
        searchField.stringValue = ""
        reloadFromBeginning()
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
