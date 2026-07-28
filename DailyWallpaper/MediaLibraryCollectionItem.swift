import AppKit

@MainActor
final class MediaLibraryCollectionItem: NSCollectionViewItem {
    private let contentContainer = CardContentView()
    private let previewView = NSImageView()
    private let placeholderIconView = NSImageView()
    private let metadataBackgroundView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var thumbnailToken: UUID?
    private weak var thumbnailService: ThumbnailService?
    private(set) var representedMediaID: Int64?
    private var isHovered = false

    override func loadView() {
        let card = CardHoverView()
        card.onHoverChanged = { [weak self] hovering in self?.setHovered(hovering) }
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

        contentContainer.addSubview(previewView)
        contentContainer.addSubview(placeholderIconView)
        contentContainer.addSubview(metadataBackgroundView)
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
            labels.topAnchor.constraint(equalTo: metadataBackgroundView.topAnchor, constant: 7),
            labels.leadingAnchor.constraint(equalTo: metadataBackgroundView.leadingAnchor, constant: 9),
            labels.trailingAnchor.constraint(equalTo: metadataBackgroundView.trailingAnchor, constant: -9),
            labels.bottomAnchor.constraint(equalTo: metadataBackgroundView.bottomAnchor, constant: -7)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 固定 shadowPath，避免滚动时反复离屏渲染阴影。
        view.layer?.shadowPath = CGPath(
            roundedRect: view.bounds,
            cornerWidth: DesignTokens.cardCornerRadius,
            cornerHeight: DesignTokens.cardCornerRadius,
            transform: nil
        )
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            updateChromeAppearance()
        }
    }

    private func setHovered(_ hovering: Bool) {
        guard isHovered != hovering else { return }
        isHovered = hovering
        updateChromeAppearance()
    }

    /// 统一根据 hover / 选中状态刷新提升、阴影、边框与元数据条显隐。
    private func updateChromeAppearance() {
        guard let cardLayer = view.layer, let containerLayer = contentContainer.layer else { return }
        let duration = DesignTokens.reduceMotion ? 0 : DesignTokens.animationFast

        let lifted = isHovered || isSelected
        var transform = CATransform3DIdentity
        if lifted {
            let bounds = view.bounds
            let scale = DesignTokens.cardHoverLift
            transform = CATransform3DTranslate(transform, bounds.midX, bounds.midY, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            transform = CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
        }

        // 选中时用 accent 光晕，悬停时用普通投影。
        let shadowColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.black.cgColor
        let shadowOpacity: Float = isSelected ? 0.5 : (isHovered ? DesignTokens.cardShadowOpacity : 0)
        let borderWidth: CGFloat = isSelected ? DesignTokens.cardSelectionBorderWidth : 0

        cardLayer.shadowColor = shadowColor
        animateLayer(cardLayer, keyPath: "transform", to: NSValue(caTransform3D: transform), duration: duration)
        animateLayer(cardLayer, keyPath: "shadowOpacity", to: shadowOpacity, duration: duration)
        animateLayer(containerLayer, keyPath: "borderWidth", to: borderWidth, duration: duration)

        let metadataAlpha: CGFloat = lifted ? 1 : 0
        if DesignTokens.reduceMotion {
            metadataBackgroundView.alphaValue = metadataAlpha
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DesignTokens.animationFast
                metadataBackgroundView.animator().alphaValue = metadataAlpha
            }
        }
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
        }
        layer.setValue(value, forKeyPath: keyPath)
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
        view.toolTip = nil
        // 复用前重置 hover 视觉状态，避免滚动时残留提升与阴影。
        isHovered = false
        metadataBackgroundView.alphaValue = 0
        view.layer?.removeAllAnimations()
        view.layer?.transform = CATransform3DIdentity
        view.layer?.shadowOpacity = 0
        contentContainer.layer?.removeAllAnimations()
        contentContainer.layer?.borderWidth = 0
    }

    func configure(item: MediaLibraryItem, fileURL: URL?, thumbnailService: ThumbnailService) {
        cancelThumbnail()
        representedMediaID = item.id
        self.thumbnailService = thumbnailService
        let title = item.title.isEmpty ? "未命名图片" : item.title
        let description = item.copyrightText.isEmpty
            ? (item.sourceType == .bing ? "必应每日图片" : "外部导入图片")
            : item.copyrightText
        let date = item.contentDate.formatted(date: .abbreviated, time: .omitted)
        let detail = "\(item.sourceType.localizedName) · \(item.market) · \(item.pixelWidth)x\(item.pixelHeight) · \(date)"
        titleLabel.stringValue = title
        descriptionLabel.stringValue = description
        detailLabel.stringValue = detail
        view.toolTip = [title, description, detail].joined(separator: "\n")
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

/// 卡片内容容器：通过 updateLayer 使用语义色，随系统深浅色自动刷新。
@MainActor
private final class CardContentView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}
