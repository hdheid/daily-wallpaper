import AppKit

/// 玻璃胶囊样式的轻量提示：底部居中弹出，短暂停留后自动淡出。
/// 用于替代不显眼的角落小字提示；同一宿主视图上新提示会顶替旧提示。
@MainActor
final class ToastPresenter {
    enum Style {
        case info
        case success
        case failure

        var symbolName: String {
            switch self {
            case .info: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .failure: "exclamationmark.triangle.fill"
            }
        }

        var tintColor: NSColor {
            switch self {
            case .info: .secondaryLabelColor
            case .success: .systemGreen
            case .failure: .systemOrange
            }
        }
    }

    private weak var hostView: NSView?
    private let bottomOffset: CGFloat
    private var toastView: PassthroughToastView?
    private var dismissTask: Task<Void, Never>?

    init(hostView: NSView, bottomOffset: CGFloat = 18) {
        self.hostView = hostView
        self.bottomOffset = bottomOffset
    }

    func show(_ message: String, style: Style = .info, duration: TimeInterval = 2.4) {
        guard let hostView else { return }
        dismiss(immediately: true)

        let toast = PassthroughToastView()
        toast.material = .hudWindow
        toast.blendingMode = .withinWindow
        toast.state = .active
        toast.wantsLayer = true
        toast.layer?.cornerRadius = 17
        toast.layer?.masksToBounds = true
        toast.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(
            systemSymbolName: style.symbolName,
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.contentTintColor = style.tintColor
        icon.setAccessibilityElement(false)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1

        let content = NSStackView(views: [icon, label])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 7
        content.edgeInsets = NSEdgeInsets(top: 8, left: 15, bottom: 8, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        toast.addSubview(content)

        hostView.addSubview(toast)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: toast.topAnchor),
            content.leadingAnchor.constraint(equalTo: toast.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: toast.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: toast.bottomAnchor),
            toast.centerXAnchor.constraint(equalTo: hostView.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: hostView.safeAreaLayoutGuide.bottomAnchor, constant: -bottomOffset),
            toast.widthAnchor.constraint(lessThanOrEqualTo: hostView.widthAnchor, constant: -48)
        ])
        toastView = toast
        toast.setAccessibilityElement(false)

        // Toast 不抢焦点，通过系统 announcement 主动告知 VoiceOver；失败提示使用更高优先级。
        let announcementPriority: NSAccessibilityPriorityLevel = switch style {
        case .failure: .high
        case .info, .success: .medium
        }
        NSAccessibility.post(
            element: hostView,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: announcementPriority.rawValue
            ]
        )

        if DesignTokens.reduceMotion {
            toast.alphaValue = 1
        } else {
            toast.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = DesignTokens.animationFast
                toast.animator().alphaValue = 1
            }, completionHandler: nil)
        }

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(immediately: false)
        }
    }

    func dismiss(immediately: Bool) {
        dismissTask?.cancel()
        dismissTask = nil
        guard let toast = toastView else { return }
        if immediately || DesignTokens.reduceMotion {
            toastView = nil
            toast.layer?.removeAllAnimations()
            toast.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DesignTokens.animationNormal
            toast.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                toast.removeFromSuperview()
                if self?.toastView === toast {
                    self?.toastView = nil
                }
            }
        })
    }
}

/// 纯提示层不参与鼠标命中测试，避免短暂遮挡底部媒体卡片的点击、双击与滚轮。
@MainActor
private final class PassthroughToastView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
