import AppKit
import Foundation

struct WallpaperApplySummary {
    let appliedDisplayUUIDs: [String]
    let skippedDisplayUUIDs: [String]
    let failures: [String: String]

    var hasFailures: Bool { !failures.isEmpty }
}

@MainActor
final class WallpaperApplier {
    private let registry: DisplayRegistry
    private let workspace: NSWorkspace

    init(registry: DisplayRegistry, workspace: NSWorkspace = .shared) {
        self.registry = registry
        self.workspace = workspace
    }

    func apply(
        imageURL: URL,
        to displayUUIDs: [String],
        scalingByDisplay: [String: WallpaperScaling]
    ) -> WallpaperApplySummary {
        var applied: [String] = []
        var skipped: [String] = []
        var failures: [String: String] = [:]

        guard imageURL.isFileURL, FileManager.default.fileExists(atPath: imageURL.path) else {
            return WallpaperApplySummary(
                appliedDisplayUUIDs: [],
                skippedDisplayUUIDs: [],
                failures: Dictionary(uniqueKeysWithValues: displayUUIDs.map { ($0, "壁纸文件不存在") })
            )
        }

        // 每次应用前刷新 NSScreen，避免持有插拔显示器后已经失效的系统对象。
        registry.refresh()
        for uuid in displayUUIDs {
            guard let screen = registry.screen(for: uuid) else {
                failures[uuid] = "显示器当前未连接"
                continue
            }

            let scaling = scalingByDisplay[uuid] ?? .fill
            let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: scaling == .fill
            ]
            if workspace.desktopImageURL(for: screen)?.standardizedFileURL == imageURL.standardizedFileURL,
               desktopOptionsMatch(for: screen, scaling: scaling)
            {
                skipped.append(uuid)
                continue
            }
            do {
                // Apple 要求 setDesktopImageURL 在主线程调用；整个类型固定在 MainActor。
                try workspace.setDesktopImageURL(imageURL, for: screen, options: options)
                applied.append(uuid)
            } catch {
                failures[uuid] = error.localizedDescription
            }
        }
        return WallpaperApplySummary(
            appliedDisplayUUIDs: applied,
            skippedDisplayUUIDs: skipped,
            failures: failures
        )
    }

    private func desktopOptionsMatch(for screen: NSScreen, scaling: WallpaperScaling) -> Bool {
        guard let current = workspace.desktopImageOptions(for: screen) else { return false }
        let expectedScaling = NSImageScaling.scaleProportionallyUpOrDown.rawValue
        let currentScaling = (current[.imageScaling] as? NSNumber)?.uintValue
        let currentClipping = (current[.allowClipping] as? NSNumber)?.boolValue
        return currentScaling == expectedScaling && currentClipping == (scaling == .fill)
    }
}
