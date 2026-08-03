import AppKit

@MainActor
final class MediaLibraryCollectionItem: NSCollectionViewItem {
    private let contentContainer = CardContentView()
    private let previewView = NSImageView()
    private let placeholderIconView = NSImageView()
    private let metadataBackgroundView = NSVisualEffectView()
    private let currentBadgeView = NSVisualEffectView()
    private let currentBadgeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var thumbnailToken: UUID?
    private weak var thumbnailService: ThumbnailService?
    private(set) var representedMediaID: Int64?
    private var isHovered = false
    private var hoverLocation: NSPoint?

    override func loadView() {
        let card = CardHoverView()
        card.onHoverChanged = { [weak self] hovering, location in
            self?.setHovered(hovering, location: location)
        }
        card.onPointerMoved = { [weak self] location in
            self?.setPointerLocation(location)
        }
        view = card
        view.wantsLayer = true
        // 阴影画在外层，圆角裁剪放在内层容器，二者不能共用同一个 layer。
        view.layer?.masksToBounds = false
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0
        view.layer?.shadowRadius = DesignTokens.cardShadowRadius
        view.layer?.shadowOffset = CGSize(width: 0, height: DesignTokens.cardShadowOffsetY)

        contentContainer.wantsLayer = true
        contentContainer.layer?.cornerRadius = DesignTokens.cardCornerRadius
        contentContainer.layer?.masksToBounds = true
        contentContainer.layer?.borderWidth = 0
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.imageAlignment = .alignCenter
        previewView.wantsLayer = true
        previewView.layer?.masksToBounds = true
        previewView.translatesAutoresizingMaskIntoConstraints = false

        // 加载中/失败态的居中占位图标，正常展示缩略图时隐藏。
        placeholderIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        placeholderIconView.contentTintColor = .tertiaryLabelColor
        placeholderIconView.translatesAutoresizingMaskIntoConstraints = false
        placeholderIconView.isHidden = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        descriptionLabel.font = .systemFont(ofSize: 11)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.maximumNumberOfLines = 2

        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1

        let labels = NSStackView(views: [titleLabel, descriptionLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        // 元数据条改为毛玻璃材质，平时隐藏、悬停或选中时渐显，让图片本身成为主角。
        metadataBackgroundView.material = .hudWindow
        metadataBackgroundView.blendingMode = .withinWindow
        metadataBackgroundView.state = .active
        metadataBackgroundView.alphaValue = 0
        metadataBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        metadataBackgroundView.addSubview(labels)

        // “当前壁纸”徽章：玻璃胶囊常驻左上角，标记正在使用的图片。
        currentBadgeView.material = .hudWindow
        currentBadgeView.blendingMode = .withinWindow
        currentBadgeView.state = .active
        currentBadgeView.wantsLayer = true
        currentBadgeView.layer?.cornerRadius = 10
        currentBadgeView.layer?.masksToBounds = true
        currentBadgeView.isHidden = true
        currentBadgeView.translatesAutoresizingMaskIntoConstraints = false

        let badgeIcon = NSImageView(image: NSImage(
            systemSymbolName: "checkmark.seal.fill",
            accessibilityDescription: "当前壁纸"
        ) ?? NSImage())
        badgeIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        badgeIcon.contentTintColor = .controlAccentColor

        currentBadgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        currentBadgeLabel.textColor = .labelColor
        currentBadgeLabel.lineBreakMode = .byTruncatingTail
        currentBadgeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let badgeStack = NSStackView(views: [badgeIcon, currentBadgeLabel])
        badgeStack.orientation = .horizontal
        badgeStack.alignment = .centerY
        badgeStack.spacing = 3
        badgeStack.edgeInsets = NSEdgeInsets(top: 3, left: 7, bottom: 3, right: 8)
        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        currentBadgeView.addSubview(badgeStack)

        contentContainer.addSubview(previewView)
        contentContainer.addSubview(placeholderIconView)
        contentContainer.addSubview(metadataBackgroundView)
        contentContainer.addSubview(currentBadgeView)
        view.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            previewView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            placeholderIconView.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            placeholderIconView.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            metadataBackgroundView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            metadataBackgroundView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            metadataBackgroundView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            currentBadgeView.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 8),
            currentBadgeView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 8),
            currentBadgeView.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -8),
            badgeStack.topAnchor.constraint(equalTo: currentBadgeView.topAnchor),
            badgeStack.leadingAnchor.constraint(equalTo: currentBadgeView.leadingAnchor),
            badgeStack.trailingAnchor.constraint(equalTo: currentBadgeView.trailingAnchor),
            badgeStack.bottomAnchor.constraint(equalTo: currentBadgeView.bottomAnchor),
            labels.topAnchor.constraint(equalTo: metadataBackgroundView.topAnchor, constant: 7),
            labels.leadingAnchor.constraint(equalTo: metadataBackgroundView.leadingAnchor, constant: 9),
            labels.trailingAnchor.constraint(equalTo: metadataBackgroundView.trailingAnchor, constant: -9),
            labels.bottomAnchor.constraint(equalTo: metadataBackgroundView.bottomAnchor, constant: -7)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 向四周均匀外扩投影轮廓，配合零偏移形成环绕阴影；固定路径可避免滚动时反复离屏计算。
        let shadowBounds = view.bounds.insetBy(
            dx: -DesignTokens.cardShadowSpread,
            dy: -DesignTokens.cardShadowSpread
        )
        view.layer?.shadowPath = CGPath(
            roundedRect: shadowBounds,
            cornerWidth: DesignTokens.cardCornerRadius + DesignTokens.cardShadowSpread,
            cornerHeight: DesignTokens.cardCornerRadius + DesignTokens.cardShadowSpread,
            transform: nil
        )
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            updateChromeAppearance()
        }
    }

    private func setHovered(_ hovering: Bool, location: NSPoint?) {
        guard isHovered != hovering else { return }
        isHovered = hovering
        hoverLocation = hovering ? location : nil
        updateChromeAppearance()
    }

    /// 仅在鼠标实际移动时刷新 3D 姿态，不创建计时器或持续渲染任务。
    private func setPointerLocation(_ location: NSPoint) {
        guard isHovered else { return }
        if DesignTokens.reduceMotion {
            // 系统运行中切换“减弱动态效果”时，立即清掉仍在展示的 3D 姿态。
            updateInteractiveTransform(duration: 0)
            return
        }
        if let previous = hoverLocation {
            let deltaX = location.x - previous.x
            let deltaY = location.y - previous.y
            // 忽略亚像素级抖动，避免高刷新率鼠标产生无意义的图层提交。
            guard deltaX * deltaX + deltaY * deltaY >= 2.25 else { return }
        }
        hoverLocation = location
        // 指针跟随必须即时更新；只在进入和离开时使用缓动，避免高频重启 CAAnimation。
        updateInteractiveTransform(duration: 0)
    }

    /// 系统辅助功能设置变化时，由媒体库统一通知当前可见卡片刷新姿态。
    func refreshAccessibilityMotionState() {
        updateChromeAppearance()
    }

    /// 统一根据 hover / 选中状态刷新 3D 姿态、阴影、边框与元数据条显隐。
    private func updateChromeAppearance() {
        guard let cardLayer = view.layer, let containerLayer = contentContainer.layer else { return }
        let duration = DesignTokens.reduceMotion ? 0 : DesignTokens.animationNormal

        let lifted = isHovered || isSelected
        cardLayer.zPosition = lifted ? 1 : 0

        // 选中时用 accent 光晕，悬停时用普通投影。
        let shadowColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.black.cgColor
        let shadowOpacity: Float = isSelected ? 0.5 : (isHovered ? DesignTokens.cardShadowOpacity : 0)
        let borderWidth: CGFloat = isSelected ? DesignTokens.cardSelectionBorderWidth : 0

        cardLayer.shadowColor = shadowColor
        updateInteractiveTransform(duration: duration)
        animateLayer(cardLayer, keyPath: "shadowOpacity", to: shadowOpacity, duration: duration)
        animateLayer(containerLayer, keyPath: "borderWidth", to: borderWidth, duration: duration)

        let metadataAlpha: CGFloat = lifted ? 1 : 0
        if DesignTokens.reduceMotion {
            metadataBackgroundView.alphaValue = metadataAlpha
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DesignTokens.animationSlow
                metadataBackgroundView.animator().alphaValue = metadataAlpha
            }
        }
    }

    /// 构造鼠标按压卡片的透视姿态：指针所在一侧后沉，对侧自然上翘。
    private func updateInteractiveTransform(duration: TimeInterval) {
        guard let cardLayer = view.layer else { return }
        let transform: CATransform3D
        if isHovered, !DesignTokens.reduceMotion {
            transform = pressedTransform(at: hoverLocation ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY))
        } else {
            transform = CATransform3DIdentity
        }
        animateLayer(cardLayer, keyPath: "transform", to: NSValue(caTransform3D: transform), duration: duration)
    }

    private func pressedTransform(at location: NSPoint) -> CATransform3D {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return CATransform3DIdentity }

        let normalizedX = min(1, max(-1, (location.x - bounds.midX) / (bounds.width / 2)))
        let rawY = min(1, max(-1, (location.y - bounds.midY) / (bounds.height / 2)))
        // 统一为“向上为正”，兼容翻转与非翻转坐标系。
        let normalizedY = view.isFlipped ? -rawY : rawY

        var transform = CATransform3DIdentity
        transform.m34 = -1 / DesignTokens.cardPerspectiveDistance
        // AppKit 管理的根 layer 默认以左下角为锚点；透视后移会缩放平移量，因此先做深度补偿，
        // 再显式平移到中心，确保卡片在任何指针方向下都不会整体漂移。
        let depthCompensation = 1 + DesignTokens.cardPressedDepth / DesignTokens.cardPerspectiveDistance
        transform = CATransform3DTranslate(
            transform,
            bounds.midX * depthCompensation,
            bounds.midY * depthCompensation,
            -DesignTokens.cardPressedDepth
        )
        transform = CATransform3DRotate(
            transform,
            -normalizedY * DesignTokens.cardMaximumTilt,
            1,
            0,
            0
        )
        transform = CATransform3DRotate(
            transform,
            normalizedX * DesignTokens.cardMaximumTilt,
            0,
            1,
            0
        )
        transform = CATransform3DScale(
            transform,
            DesignTokens.cardPressedScale,
            DesignTokens.cardPressedScale,
            1
        )
        return CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
    }

    /// 层被 NSView 接管后隐式动画被禁用，layer 属性需要显式动画驱动。
    private func animateLayer(_ layer: CALayer, keyPath: String, to value: Any, duration: TimeInterval) {
        if duration > 0 {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
            animation.toValue = value
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: keyPath)
        } else {
            // 即时交互或“减弱动态效果”需要覆盖仍在播放的同名显式动画。
            layer.removeAnimation(forKey: keyPath)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
        representedMediaID = nil
        previewView.image = nil
        previewView.layer?.removeAllAnimations()
        placeholderIconView.isHidden = true
        titleLabel.stringValue = ""
        descriptionLabel.stringValue = ""
        detailLabel.stringValue = ""
        currentBadgeLabel.stringValue = ""
        view.toolTip = nil
        currentBadgeView.isHidden = true
        // 复用前重置 hover 视觉状态，避免滚动时残留提升与阴影。
        isHovered = false
        hoverLocation = nil
        metadataBackgroundView.alphaValue = 0
        view.layer?.removeAllAnimations()
        view.layer?.transform = CATransform3DIdentity
        view.layer?.zPosition = 0
        view.layer?.shadowOpacity = 0
        contentContainer.layer?.removeAllAnimations()
        contentContainer.layer?.borderWidth = 0
    }

    func configure(
        item: MediaLibraryItem,
        fileURL: URL?,
        thumbnailService: ThumbnailService,
        currentDisplayNames: [String]
    ) {
        cancelThumbnail()
        representedMediaID = item.id
        setCurrentWallpaperBadge(displayNames: currentDisplayNames)
        self.thumbnailService = thumbnailService
        let title = item.title.isEmpty ? "未命名图片" : item.title
        let description = item.copyrightText.isEmpty
            ? (item.sourceType == .bing ? "必应每日图片" : "外部导入图片")
            : item.copyrightText
        let date = item.contentDate.formatted(date: .abbreviated, time: .omitted)
        let marketName = item.sourceType == .bing ? BingMarket.localizedName(for: item.market) : item.market
        let detail = "\(item.sourceType.localizedName) · \(marketName) · \(item.pixelWidth)x\(item.pixelHeight) · \(date)"
        titleLabel.stringValue = title
        descriptionLabel.stringValue = description
        detailLabel.stringValue = detail
        let currentDisplayText = currentDisplayNames.isEmpty
            ? nil
            : "当前用于：\(currentDisplayNames.joined(separator: "、"))"
        view.toolTip = [title, description, detail, currentDisplayText]
            .compactMap { $0 }
            .joined(separator: "\n")
        previewView.setAccessibilityLabel(title)

        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            showPlaceholder(symbolName: "externaldrive.badge.exclamationmark", description: "图片不可访问")
            return
        }
        // 加载中使用中性底色留白，缩略图就绪后淡入，避免图标占位的跳变感。
        previewView.image = nil
        placeholderIconView.isHidden = true
        let expectedID = item.id
        thumbnailToken = thumbnailService.requestThumbnail(
            fileURL: fileURL,
            contentSHA256: item.contentSHA256,
            size: CGSize(
                width: AppConstants.mediaLibraryThumbnailPointSize,
                height: AppConstants.mediaLibraryThumbnailPointSize
            ),
            scale: NSScreen.main?.backingScaleFactor ?? 2
        ) { [weak self] result in
            guard let self, self.representedMediaID == expectedID else { return }
            switch result {
            case let .success(image):
                setThumbnail(image)
            case .failure:
                showPlaceholder(symbolName: "photo.badge.exclamationmark", description: "缩略图生成失败")
            }
        }
    }

    private func setThumbnail(_ image: NSImage) {
        placeholderIconView.isHidden = true
        if !DesignTokens.reduceMotion, let layer = previewView.layer {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = DesignTokens.animationNormal
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(transition, forKey: "thumbnailFade")
        }
        previewView.image = image
    }

    private func showPlaceholder(symbolName: String, description: String) {
        previewView.image = nil
        placeholderIconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        placeholderIconView.isHidden = false
    }

    /// 壁纸切换后刷新可见卡片的徽章，并保留具体显示器归属。
    func setCurrentWallpaperBadge(displayNames: [String]) {
        currentBadgeView.isHidden = displayNames.isEmpty
        switch displayNames.count {
        case 0:
            currentBadgeLabel.stringValue = ""
        case 1:
            currentBadgeLabel.stringValue = "当前：\(displayNames[0])"
        default:
            currentBadgeLabel.stringValue = "当前：\(displayNames.count) 台显示器"
        }
        currentBadgeView.setAccessibilityLabel(displayNames.isEmpty
            ? nil
            : "当前用于\(displayNames.joined(separator: "、"))")
    }

    private func cancelThumbnail() {
        if let token = thumbnailToken {
            thumbnailService?.cancel(token)
        }
        thumbnailToken = nil
    }
}

/// 卡片根视图：负责 hover 追踪。
@MainActor
private final class CardHoverView: NSView {
    var onHoverChanged: ((Bool, NSPoint?) -> Void)?
    var onPointerMoved: ((NSPoint) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true, convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false, nil)
    }
}

/// 卡片内容容器：通过 updateLayer 使用语义色，随系统深浅色自动刷新。
@MainActor
private final class CardContentView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}
