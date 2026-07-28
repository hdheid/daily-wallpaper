import AppKit

@MainActor
final class ImportProgressWindowController: NSWindowController, NSWindowDelegate {
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "正在扫描图片…")
    private let statusIconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "")
    private let barIndicator = NSProgressIndicator()
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var isFinished = false

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "导入图片"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        renderDetail(ImportProgress())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(_ progress: ImportProgress) {
        renderDetail(progress)
        renderBar(progress)
        if !isFinished, progress.scanned > 0 {
            statusLabel.stringValue = "正在导入图片…"
        }
    }

    func finish(_ summary: ImportSummary) {
        isFinished = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusIconView.image = NSImage(
            systemSymbolName: summary.cancelled ? "xmark.circle.fill" : "checkmark.circle.fill",
            accessibilityDescription: summary.cancelled ? "导入已取消" : "导入完成"
        )
        statusIconView.contentTintColor = summary.cancelled ? .secondaryLabelColor : .systemGreen
        statusIconView.isHidden = false
        statusLabel.stringValue = summary.cancelled ? "导入已取消" : "导入完成"
        renderDetail(summary.progress)
        barIndicator.isIndeterminate = false
        barIndicator.maxValue = 1
        barIndicator.doubleValue = 1
        cancelButton.title = "关闭"
        cancelButton.isEnabled = true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isFinished else { return true }
        // 关闭按钮与“取消”使用同一语义，避免导入在不可见窗口中继续运行。
        cancelPressed()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    /// 统计文案分段着色：失败数大于 0 时标红，便于一眼发现异常。
    private func renderDetail(_ progress: ImportProgress) {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "已扫描 \(progress.scanned) · 已导入 \(progress.imported) · 重复 \(progress.duplicates) · 跳过 \(progress.skipped) · ", attributes: base))
        var failedAttributes = base
        if progress.failed > 0 {
            failedAttributes[.foregroundColor] = NSColor.systemRed
            failedAttributes[.font] = NSFont.systemFont(ofSize: 12, weight: .medium)
        }
        text.append(NSAttributedString(string: "失败 \(progress.failed)", attributes: failedAttributes))
        detailLabel.attributedStringValue = text
    }

    /// 用「已处理 / 已扫描」驱动确定型进度条；扫描尚未产出计数时保持不确定态。
    private func renderBar(_ progress: ImportProgress) {
        guard progress.scanned > 0 else { return }
        let processed = progress.imported + progress.duplicates + progress.skipped + progress.failed
        if barIndicator.isIndeterminate {
            barIndicator.stopAnimation(nil)
            barIndicator.isIndeterminate = false
        }
        barIndicator.maxValue = Double(progress.scanned)
        barIndicator.doubleValue = Double(processed)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        statusIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        statusIconView.isHidden = true

        barIndicator.style = .bar
        barIndicator.isIndeterminate = true
        barIndicator.startAnimation(nil)
        barIndicator.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)

        let titleRow = NSStackView(views: [spinner, statusIconView, statusLabel])
        titleRow.orientation = .horizontal
        titleRow.spacing = 10
        titleRow.alignment = .centerY

        let stack = NSStackView(views: [titleRow, barIndicator, detailLabel, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18),
            barIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func cancelPressed() {
        if isFinished {
            close()
        } else {
            cancelButton.isEnabled = false
            statusLabel.stringValue = "正在停止…"
            onCancel?()
        }
    }
}
