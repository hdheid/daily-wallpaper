import AppKit
import CryptoKit

enum CurrentWallpaperVerification: Equatable {
    case managed
    case external
    case unavailable
}

/// 单台已连接显示器在当前 Space 下的系统壁纸状态。
struct CurrentDisplayWallpaperStatus: Equatable {
    let displayUUID: String
    let displayName: String
    let isMainDisplay: Bool
    let actualURL: URL?
    /// 文件被原地覆盖时 URL 不会变化，轻量指纹用于让状态与缩略图缓存及时失效。
    let actualFileFingerprint: String?
    let managedRecord: CurrentWallpaperRecord?
    let verification: CurrentWallpaperVerification

    var title: String {
        if verification == .managed, let managedRecord, !managedRecord.title.isEmpty {
            return managedRecord.title
        }
        guard let actualURL else { return "未检测到壁纸" }
        let filename = actualURL.deletingPathExtension().lastPathComponent
        return filename.isEmpty ? "系统壁纸" : filename
    }

    var statusText: String {
        switch verification {
        case .managed: "由 Daily Wallpaper 管理"
        case .external: "系统外部壁纸"
        case .unavailable: actualURL == nil ? "系统状态未知" : "壁纸文件不可访问"
        }
    }

    var thumbnailCacheKey: String {
        let sourceIdentity: String
        if verification == .managed, let managedRecord {
            sourceIdentity = "managed:\(managedRecord.contentSHA256)"
        } else if let actualURL {
            sourceIdentity = "file:\(CurrentWallpaperURLMatcher.canonicalPath(actualURL))"
        } else {
            sourceIdentity = "unavailable:\(displayUUID)"
        }
        let rawKey = "\(sourceIdentity)|\(actualFileFingerprint ?? "unknown")"
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum CurrentWallpaperFileFingerprint {
    /// 仅读取文件元数据，不扫描图片内容；适合窗口激活时频繁核验当前壁纸。
    static func read(from url: URL, fileManager: FileManager = .default) -> String? {
        let path = CurrentWallpaperURLMatcher.canonicalPath(url)
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(size):\(modifiedAt.bitPattern):\(fileNumber)"
    }
}

enum CurrentWallpaperURLMatcher {
    /// 系统与归档层可能给出含符号链接或冗余路径组件的 URL，统一后再判断文件身份。
    static func matches(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs, lhs.isFileURL, rhs.isFileURL else { return false }
        return canonicalPath(lhs) == canonicalPath(rhs)
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// 媒体库顶部的当前壁纸状态带。每台显示器一张小卡片，避免只看到模糊的“当前壁纸”徽章。
@MainActor
final class CurrentWallpaperStatusView: NSView {
    private let displayStack = NSStackView()
    private let displayScrollView = NSScrollView()
    private let displayDocumentView = CurrentWallpaperDisplayDocumentView()
    private let emptyLabel = NSTextField(labelWithString: "未检测到已连接显示器")
    private var cards: [CurrentWallpaperDisplayCardView] = []
    private var cardMinimumWidthConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(
        statuses: [CurrentDisplayWallpaperStatus],
        thumbnailService: ThumbnailService
    ) {
        clear()
        emptyLabel.isHidden = !statuses.isEmpty
        displayScrollView.isHidden = statuses.isEmpty
        for status in statuses {
            let card = CurrentWallpaperDisplayCardView()
            card.configure(status: status, thumbnailService: thumbnailService)
            cards.append(card)
            displayStack.addArrangedSubview(card)
            // 少量显示器由 fillEqually 自动铺满；数量较多时保持可读宽度并启用横向滚动。
            cardMinimumWidthConstraints.append(card.widthAnchor.constraint(greaterThanOrEqualToConstant: 220))
        }
        NSLayoutConstraint.activate(cardMinimumWidthConstraints)
        setAccessibilityLabel(statuses.isEmpty
            ? "当前没有已连接显示器"
            : statuses.map { "\($0.displayName)：\($0.title)，\($0.statusText)" }.joined(separator: "；"))
    }

    func clear() {
        NSLayoutConstraint.deactivate(cardMinimumWidthConstraints)
        cardMinimumWidthConstraints.removeAll()
        cards.forEach { card in
            card.prepareForRemoval()
            displayStack.removeArrangedSubview(card)
            card.removeFromSuperview()
        }
        cards.removeAll()
    }

    private func buildContent() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let titleLabel = NSTextField(labelWithString: "当前壁纸")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let scopeLabel = NSTextField(labelWithString: "当前 Space")
        scopeLabel.font = .systemFont(ofSize: 11)
        scopeLabel.textColor = .tertiaryLabelColor
        let heading = NSStackView(views: [titleLabel, scopeLabel])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 7

        displayStack.orientation = .horizontal
        displayStack.alignment = .centerY
        displayStack.spacing = 10
        displayStack.distribution = .fillEqually
        displayStack.translatesAutoresizingMaskIntoConstraints = false

        displayScrollView.drawsBackground = false
        displayScrollView.borderType = .noBorder
        displayScrollView.hasVerticalScroller = false
        displayScrollView.hasHorizontalScroller = true
        displayScrollView.autohidesScrollers = true
        displayScrollView.scrollerStyle = .overlay
        displayScrollView.verticalScrollElasticity = .none
        displayScrollView.translatesAutoresizingMaskIntoConstraints = false
        displayDocumentView.translatesAutoresizingMaskIntoConstraints = false
        displayScrollView.documentView = displayDocumentView
        displayDocumentView.addSubview(displayStack)
        displayScrollView.isHidden = true

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)

        let content = NSStackView(views: [heading, displayScrollView, emptyLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            displayScrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
            displayScrollView.heightAnchor.constraint(equalToConstant: 72),

            // 文档至少与可视区域等宽；卡片最小宽度不足以容纳时，文档自然向右扩展。
            displayDocumentView.topAnchor.constraint(equalTo: displayScrollView.contentView.topAnchor),
            displayDocumentView.leadingAnchor.constraint(equalTo: displayScrollView.contentView.leadingAnchor),
            displayDocumentView.heightAnchor.constraint(equalTo: displayScrollView.contentView.heightAnchor),
            displayDocumentView.widthAnchor.constraint(greaterThanOrEqualTo: displayScrollView.contentView.widthAnchor),
            displayStack.topAnchor.constraint(equalTo: displayDocumentView.topAnchor),
            displayStack.leadingAnchor.constraint(equalTo: displayDocumentView.leadingAnchor),
            displayStack.trailingAnchor.constraint(equalTo: displayDocumentView.trailingAnchor),
            displayStack.bottomAnchor.constraint(equalTo: displayDocumentView.bottomAnchor)
        ])
    }
}

/// 横向状态带使用左上角原点，滚动到起点时始终先看到主显示器一侧。
@MainActor
private final class CurrentWallpaperDisplayDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class CurrentWallpaperDisplayCardView: NSVisualEffectView {
    private let thumbnailView = NSImageView()
    private let placeholderView = NSImageView()
    private let displayLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var thumbnailToken: UUID?
    private weak var thumbnailService: ThumbnailService?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(status: CurrentDisplayWallpaperStatus, thumbnailService: ThumbnailService) {
        prepareForRemoval()
        self.thumbnailService = thumbnailService
        displayLabel.stringValue = status.displayName + (status.isMainDisplay ? "（主显示器）" : "")
        titleLabel.stringValue = status.title
        statusLabel.stringValue = status.statusText
        statusLabel.textColor = switch status.verification {
        case .managed: .controlAccentColor
        case .external: .secondaryLabelColor
        case .unavailable: .systemOrange
        }
        setAccessibilityLabel("\(displayLabel.stringValue)，\(status.title)，\(status.statusText)")

        guard
            let url = status.actualURL,
            FileManager.default.fileExists(atPath: url.path)
        else {
            showPlaceholder(symbolName: "display.trianglebadge.exclamationmark")
            return
        }

        placeholderView.isHidden = true
        thumbnailToken = thumbnailService.requestThumbnail(
            fileURL: url,
            contentSHA256: status.thumbnailCacheKey,
            size: CGSize(width: 92, height: 58),
            scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(image):
                thumbnailView.image = image
                placeholderView.isHidden = true
            case .failure:
                showPlaceholder(symbolName: "photo.badge.exclamationmark")
            }
        }
    }

    func prepareForRemoval() {
        if let thumbnailToken {
            thumbnailService?.cancel(thumbnailToken)
        }
        thumbnailToken = nil
        thumbnailView.image = nil
        placeholderView.isHidden = false
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    private func buildContent() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 5
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        placeholderView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .light)
        placeholderView.contentTintColor = .tertiaryLabelColor
        placeholderView.translatesAutoresizingMaskIntoConstraints = false

        displayLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        displayLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [displayLabel, titleLabel, statusLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [thumbnailView, labels])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 9
        content.edgeInsets = NSEdgeInsets(top: 7, left: 7, bottom: 7, right: 9)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(placeholderView)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 92),
            thumbnailView.heightAnchor.constraint(equalToConstant: 58),
            placeholderView.centerXAnchor.constraint(equalTo: thumbnailView.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: thumbnailView.centerYAnchor),
            heightAnchor.constraint(equalToConstant: 72)
        ])
    }

    private func showPlaceholder(symbolName: String) {
        thumbnailView.image = nil
        placeholderView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        placeholderView.isHidden = false
    }
}
