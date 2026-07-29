import AppKit

/// 全局 UI 设计常量：圆角、阴影、动画时长等统一在此维护，避免散落各文件硬编码。
@MainActor
enum DesignTokens {
    // MARK: - 卡片

    static let cardCornerRadius: CGFloat = 10
    static let cardSelectionBorderWidth: CGFloat = 2.5
    static let cardHoverLift: CGFloat = 1.06
    static let cardShadowOpacity: Float = 0.28
    static let cardShadowRadius: CGFloat = 12
    static let cardShadowOffsetY: CGFloat = -3

    // MARK: - 动画时长

    static let animationFast: TimeInterval = 0.15
    static let animationNormal: TimeInterval = 0.22
    static let animationSlow: TimeInterval = 0.48

    /// 用户开启"减弱动态效果"时所有装饰性动画应退化为瞬时切换。
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 尊重系统"减弱动态效果"设置的动画包装：开启时直接执行 changes，不做动画。
    static func animate(
        duration: TimeInterval = animationNormal,
        changes: () -> Void,
        completion: (@Sendable @MainActor () -> Void)? = nil
    ) {
        guard !reduceMotion else {
            changes()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion.map { handler in
            // 动画回调在主线程触发，包一层 assumeIsolated 满足 @Sendable 要求。
            { @Sendable in MainActor.assumeIsolated { handler() } }
        })
    }
}
