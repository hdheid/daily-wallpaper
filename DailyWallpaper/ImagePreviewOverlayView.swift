import AppKit
import ImageIO

/// 双击卡片进入的应用内预览层：大图居中展示，悬停浮现标题与介绍，
/// 底部胶片条按媒体库查询继续分页，支持点击切换与方向键翻页，Esc 或关闭按钮退出。
@MainActor
final class ImagePreviewOverlayView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var onDismiss: (() -> Void)?

    private let backgroundView = NSVisualEffectView()
    private let imageContainer = HoverTrackingView()
    private let imageView = PreviewImageView()
    private let spinner = NSProgressIndicator()
    private let infoBar = NSVisualEffectView()
    private let infoTitleLabel = NSTextField(labelWithString: "")
    private let infoDescriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let infoDetailLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let filmstripBar = NSVisualEffectView()
    private let filmstripScroll = NSScrollView()
    private let filmstrip = PreviewFilmstripCollectionView()

    private var items: [MediaLibraryItem]
    private let thumbnailService: ThumbnailService
    private let fileURLProvider: (MediaLibraryItem) -> URL?
    private let pageLoader: @MainActor (MediaLibraryCursor?) async throws -> MediaLibraryPage
    private let imageLoader = PreviewImageLoader()
    private var currentIndex: Int
    private var nextCursor: MediaLibraryCursor?
    private var reachedEnd: Bool
    private var imageLoadTask: Task<Void, Never>?
    private var pageLoadTask: Task<Void, Never>?
    private var isPageLoading = false
    private var advanceAfterPageLoad = false
    private var isInfoBarVisible = false
    private var isDismissing = false

    init(
        items: [MediaLibraryItem],
        startIndex: Int,
        nextCursor: MediaLibraryCursor?,
        reachedEnd: Bool,
        thumbnailService: ThumbnailService,
        fileURLProvider: @escaping (MediaLibraryItem) -> URL?,
        pageLoader: @escaping @MainActor (MediaLibraryCursor?) async throws -> MediaLibraryPage
    ) {
        self.items = items
        self.thumbnailService = thumbnailService
        self.fileURLProvider = fileURLProvider
        self.pageLoader = pageLoader
        self.nextCursor = nextCursor
        self.reachedEnd = reachedEnd
        currentIndex = min(max(0, startIndex), max(0, items.count - 1))
        super.init(frame: .zero)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func present(in hostView: NSView) {
        // 先给覆盖层一个有效初始尺寸，避免首帧在零尺寸视图上计算图片采样规格。
        frame = hostView.bounds
        translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: hostView.topAnchor),
            leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])
        if DesignTokens.reduceMotion {
            alphaValue = 1
        } else {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = DesignTokens.animationNormal
                animator().alphaValue = 1
            }, completionHandler: nil)
        }
        // 让 AppKit 在当前事件结束后自然完成约束布局。同步强制布局会在双击事件触发的
        // collection view 布局事务里重入，产生 layoutSubtreeIfNeeded 递归警告。
        DispatchQueue.main.async { [weak self] in
            guard let self, !isDismissing, superview != nil else { return }
            window?.makeFirstResponder(self)
            showItem(at: currentIndex, scrollFilmstrip: true)
        }
    }

    func dismiss(immediately: Bool) {
        guard !isDismissing else { return }
        isDismissing = true
        imageLoadTask?.cancel()
        imageLoadTask = nil
        pageLoadTask?.cancel()
        pageLoadTask = nil
        spinner.stopAnimation(nil)
        if immediately || DesignTokens.reduceMotion {
            removeFromSuperview()
            onDismiss?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DesignTokens.animationFast
            animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                self?.removeFromSuperview()
                self?.onDismiss?()
            }
        })
    }

    // MARK: - 布局

    private func buildContent() {
        // 全屏玻璃底：模糊媒体库网格，同时挡住下层点击。
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.onHoverChanged = { [weak self] hovering in self?.setInfoBarVisible(hovering) }
        imageContainer.addSubview(imageView)
        addSubview(imageContainer)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        // 悬停信息条：玻璃胶囊浮在大图下缘，展示标题、介绍与详情。
        infoBar.material = .hudWindow
        infoBar.blendingMode = .withinWindow
        infoBar.state = .active
        infoBar.wantsLayer = true
        infoBar.layer?.cornerRadius = 12
        infoBar.layer?.masksToBounds = true
        infoBar.alphaValue = 0
        infoBar.translatesAutoresizingMaskIntoConstraints = false

        infoTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        infoTitleLabel.lineBreakMode = .byTruncatingTail
        infoTitleLabel.maximumNumberOfLines = 1
        infoDescriptionLabel.font = .systemFont(ofSize: 12)
        infoDescriptionLabel.textColor = .secondaryLabelColor
        infoDescriptionLabel.maximumNumberOfLines = 2
        infoDetailLabel.font = .systemFont(ofSize: 11)
        infoDetailLabel.textColor = .tertiaryLabelColor
        infoDetailLabel.lineBreakMode = .byTruncatingTail
        infoDetailLabel.maximumNumberOfLines = 1

        let infoStack = NSStackView(views: [infoTitleLabel, infoDescriptionLabel, infoDetailLabel])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 4
        infoStack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoBar.addSubview(infoStack)
        addSubview(infoBar)

        configureGlassButton(closeButton, symbolName: "xmark", accessibilityLabel: "关闭预览", action: #selector(closePressed))
        configureGlassButton(prevButton, symbolName: "chevron.left", accessibilityLabel: "上一张", action: #selector(prevPressed))
        configureGlassButton(nextButton, symbolName: "chevron.right", accessibilityLabel: "下一张", action: #selector(nextPressed))

        // 底部胶片条：横向缩略图序列，当前项高亮。
        let flowLayout = NSCollectionViewFlowLayout()
        flowLayout.scrollDirection = .horizontal
        flowLayout.itemSize = NSSize(width: 96, height: 60)
        flowLayout.minimumLineSpacing = 8
        flowLayout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        filmstrip.collectionViewLayout = flowLayout
        filmstrip.dataSource = self
        filmstrip.delegate = self
        filmstrip.isSelectable = true
        filmstrip.allowsEmptySelection = false
        filmstrip.backgroundColors = [.clear]
        filmstrip.register(
            FilmstripThumbnailItem.self,
            forItemWithIdentifier: NSUserInterfaceItemIdentifier("FilmstripThumbnailItem")
        )

        filmstripScroll.documentView = filmstrip
        filmstripScroll.drawsBackground = false
        filmstripScroll.hasHorizontalScroller = true
        filmstripScroll.verticalScrollElasticity = .none
        filmstripScroll.translatesAutoresizingMaskIntoConstraints = false

        filmstripBar.material = .hudWindow
        filmstripBar.blendingMode = .withinWindow
        filmstripBar.state = .active
        filmstripBar.translatesAutoresizingMaskIntoConstraints = false
        filmstripBar.addSubview(filmstripScroll)
        addSubview(filmstripBar)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageContainer.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            imageContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            imageContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            imageContainer.bottomAnchor.constraint(equalTo: filmstripBar.topAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),
            infoStack.topAnchor.constraint(equalTo: infoBar.topAnchor),
            infoStack.leadingAnchor.constraint(equalTo: infoBar.leadingAnchor),
            infoStack.trailingAnchor.constraint(equalTo: infoBar.trailingAnchor),
            infoStack.bottomAnchor.constraint(equalTo: infoBar.bottomAnchor),
            infoBar.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
            infoBar.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor, constant: -16),
            infoBar.widthAnchor.constraint(lessThanOrEqualTo: imageContainer.widthAnchor, constant: -80),
            closeButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 14),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            prevButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            prevButton.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            nextButton.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),
            filmstripScroll.topAnchor.constraint(equalTo: filmstripBar.topAnchor),
            filmstripScroll.leadingAnchor.constraint(equalTo: filmstripBar.leadingAnchor),
            filmstripScroll.trailingAnchor.constraint(equalTo: filmstripBar.trailingAnchor),
            filmstripScroll.bottomAnchor.constraint(equalTo: filmstripBar.bottomAnchor),
            filmstripBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            filmstripBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            filmstripBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            filmstripBar.heightAnchor.constraint(equalToConstant: 76)
        ])
    }

    private func configureGlassButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 16
        button.layer?.masksToBounds = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        button.contentTintColor = .white
        button.target = self
        button.action = action
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    // MARK: - 切换与加载

    private func showItem(at index: Int, scrollFilmstrip: Bool) {
        guard items.indices.contains(index) else { return }
        advanceAfterPageLoad = false
        currentIndex = index
        let item = items[index]
        updateInformation(for: item, at: index)
        updateNavigationButtons()

        let indexPath = IndexPath(item: index, section: 0)
        filmstrip.selectionIndexPaths = [indexPath]
        if scrollFilmstrip {
            filmstrip.scrollToItems(at: [indexPath], scrollPosition: .centeredHorizontally)
        }
        loadFullImage(for: item)
        loadMoreIfNeeded()
    }

    private func loadFullImage(for item: MediaLibraryItem) {
        imageLoadTask?.cancel()
        imageLoadTask = nil
        spinner.stopAnimation(nil)
        // 切换时立即清空旧图，不能让新标题短暂配上上一张画面。
        imageView.image = nil
        imageView.layer?.removeAnimation(forKey: "previewFade")
        guard let url = fileURLProvider(item) else {
            imageView.image = NSImage(
                systemSymbolName: "externaldrive.badge.exclamationmark",
                accessibilityDescription: "图片不可访问"
            )
            return
        }
        spinner.startAnimation(nil)
        // 按窗口尺寸降采样解码，避免原图整幅载入内存。
        let scale = window?.backingScaleFactor ?? 2
        let measuredPixels = max(imageContainer.bounds.width, imageContainer.bounds.height) * scale
        let limit = max(1_600, min(measuredPixels, 4_096))
        let imageLoader = self.imageLoader
        imageLoadTask = Task { [weak self] in
            let cgImage = await imageLoader.load(url: url, maxPixelSize: limit)
            guard let self, !Task.isCancelled else { return }
            imageLoadTask = nil
            spinner.stopAnimation(nil)
            if let cgImage {
                if !DesignTokens.reduceMotion, let layer = imageView.layer {
                    let transition = CATransition()
                    transition.type = .fade
                    transition.duration = DesignTokens.animationNormal
                    layer.add(transition, forKey: "previewFade")
                }
                imageView.image = NSImage(cgImage: cgImage, size: .zero)
            } else {
                imageView.image = NSImage(
                    systemSymbolName: "photo.badge.exclamationmark",
                    accessibilityDescription: "图片加载失败"
                )
            }
        }
    }

    private func updateInformation(for item: MediaLibraryItem, at index: Int) {
        let title = item.title.isEmpty ? "未命名图片" : item.title
        let description = item.copyrightText.isEmpty
            ? (item.sourceType == .bing ? "必应每日图片" : "外部导入图片")
            : item.copyrightText
        let date = item.contentDate.formatted(date: .abbreviated, time: .omitted)
        infoTitleLabel.stringValue = title
        infoDescriptionLabel.stringValue = description
        infoDetailLabel.stringValue = "\(index + 1) / \(items.count) · \(item.sourceType.localizedName)"
            + " · \(item.sourceType == .bing ? BingMarket.localizedName(for: item.market) : item.market)"
            + " · \(item.pixelWidth)x\(item.pixelHeight) · \(date)"
        imageView.setAccessibilityLabel(title)
    }

    private func updateNavigationButtons() {
        prevButton.isEnabled = currentIndex > 0
        nextButton.isEnabled = currentIndex < items.count - 1 || !reachedEnd
        prevButton.alphaValue = prevButton.isEnabled ? 1 : 0.3
        nextButton.alphaValue = nextButton.isEnabled ? 1 : 0.3
    }

    /// 接近胶片条末尾时继续读取同一筛选条件的下一页；始终只允许一个分页任务。
    private func loadMoreIfNeeded(force: Bool = false) {
        guard !isPageLoading, !reachedEnd else { return }
        guard force || currentIndex >= max(0, items.count - 6) else { return }
        guard let requestedCursor = nextCursor else {
            advanceAfterPageLoad = false
            reachedEnd = true
            updateNavigationButtons()
            return
        }
        isPageLoading = true
        let pageLoader = self.pageLoader
        pageLoadTask = Task { [weak self] in
            do {
                let page = try await pageLoader(requestedCursor)
                guard let self, !Task.isCancelled, !isDismissing else { return }
                let previousCount = items.count
                items.append(contentsOf: page.items)
                nextCursor = page.nextCursor
                reachedEnd = page.reachedEnd
                isPageLoading = false
                pageLoadTask = nil

                if !page.items.isEmpty {
                    let inserted = Set((previousCount ..< items.count).map { IndexPath(item: $0, section: 0) })
                    filmstrip.insertItems(at: inserted)
                }
                if items.indices.contains(currentIndex) {
                    updateInformation(for: items[currentIndex], at: currentIndex)
                }
                updateNavigationButtons()
                if advanceAfterPageLoad, currentIndex + 1 < items.count {
                    advanceAfterPageLoad = false
                    showItem(at: currentIndex + 1, scrollFilmstrip: true)
                } else {
                    advanceAfterPageLoad = false
                }
            } catch {
                guard let self, !Task.isCancelled, !isDismissing else { return }
                isPageLoading = false
                pageLoadTask = nil
                advanceAfterPageLoad = false
                infoDetailLabel.stringValue += " · 更多图片加载失败"
                NSAccessibility.post(
                    element: self,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: "更多图片加载失败",
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue
                    ]
                )
            }
        }
    }

    private func setInfoBarVisible(_ visible: Bool) {
        guard isInfoBarVisible != visible else { return }
        isInfoBarVisible = visible
        let alpha: CGFloat = visible ? 1 : 0
        if DesignTokens.reduceMotion {
            infoBar.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DesignTokens.animationNormal
            infoBar.animator().alphaValue = alpha
        }, completionHandler: nil)
    }

    // MARK: - 交互

    @objc private func closePressed() { dismiss(immediately: false) }
    @objc private func prevPressed() {
        showItem(at: currentIndex - 1, scrollFilmstrip: true)
        window?.makeFirstResponder(self)
    }
    @objc private func nextPressed() {
        advanceToNextItem()
        window?.makeFirstResponder(self)
    }

    /// 按钮和方向键共用同一前进逻辑；到达已加载页末时等待分页完成后自动进入下一张。
    private func advanceToNextItem() {
        if currentIndex + 1 < items.count {
            showItem(at: currentIndex + 1, scrollFilmstrip: true)
        } else if !reachedEnd {
            advanceAfterPageLoad = true
            loadMoreIfNeeded(force: true)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            dismiss(immediately: false)
        case 123, 126: // ← / ↑
            showItem(at: currentIndex - 1, scrollFilmstrip: true)
        case 124, 125: // → / ↓
            advanceToNextItem()
        default:
            super.keyDown(with: event)
        }
    }

    // 吞掉空白区域点击，避免事件穿透到底部媒体库网格。
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // MARK: - 胶片条数据源

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
                withIdentifier: NSUserInterfaceItemIdentifier("FilmstripThumbnailItem"),
                for: indexPath
            ) as? FilmstripThumbnailItem
        else { return NSCollectionViewItem() }
        let item = items[indexPath.item]
        itemView.configure(item: item, fileURL: fileURLProvider(item), thumbnailService: thumbnailService)
        return itemView
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, indexPath.item != currentIndex else { return }
        showItem(at: indexPath.item, scrollFilmstrip: false)
        window?.makeFirstResponder(self)
    }
}

/// 预览图片只在既定容器内等比缩放，不允许原图像素尺寸反向撑大主窗口。
/// NSImageView 默认会把图片尺寸作为 intrinsicContentSize，超大壁纸可能因此把胶片条顶出屏幕。
@MainActor
private final class PreviewImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

/// ImageIO 解码串行执行。取消旧任务会跳过尚未开始的请求，运行中的请求结束后才处理最新图片。
private actor PreviewImageLoader {
    func load(url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        guard !Task.isCancelled else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }
}

/// 胶片条不抢占第一响应者，方向键和 Esc 始终由预览层统一处理。
@MainActor
private final class PreviewFilmstripCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
}

/// 胶片条缩略图：圆角小卡片，当前项用 accent 描边高亮。
@MainActor
private final class FilmstripThumbnailItem: NSCollectionViewItem {
    private let thumbnailView = NSImageView()
    private var thumbnailToken: UUID?
    private weak var thumbnailService: ThumbnailService?
    private var representedMediaID: Int64?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thumbnailView)
        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: view.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    private func updateSelectionAppearance() {
        view.layer?.borderWidth = isSelected ? 2 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        thumbnailView.alphaValue = isSelected ? 1 : 0.7
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let token = thumbnailToken {
            thumbnailService?.cancel(token)
        }
        thumbnailToken = nil
        representedMediaID = nil
        thumbnailView.image = nil
        updateSelectionAppearance()
    }

    func configure(item: MediaLibraryItem, fileURL: URL?, thumbnailService: ThumbnailService) {
        representedMediaID = item.id
        self.thumbnailService = thumbnailService
        updateSelectionAppearance()
        guard let fileURL else { return }
        let expectedID = item.id
        thumbnailToken = thumbnailService.requestThumbnail(
            fileURL: fileURL,
            contentSHA256: item.contentSHA256,
            size: CGSize(width: 96, height: 60),
            scale: NSScreen.main?.backingScaleFactor ?? 2
        ) { [weak self] result in
            guard let self, representedMediaID == expectedID, case let .success(image) = result else { return }
            thumbnailView.image = image
        }
    }
}

/// 悬停追踪容器：进出时回调，用于信息条显隐。
@MainActor
private final class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}
