import AppKit
import CoreGraphics
import Foundation

@MainActor
final class DisplayRegistry {
    private(set) var displays: [DisplayDescriptor] = []
    private var screensByUUID: [String: NSScreen] = [:]

    init() {
        refresh()
    }

    @discardableResult
    func refresh() -> [DisplayDescriptor] {
        var nextDisplays: [DisplayDescriptor] = []
        var nextScreens: [String: NSScreen] = [:]

        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(for: screen), let uuid = Self.uuid(for: displayID) else {
                continue
            }
            let frame = screen.frame
            let descriptor = DisplayDescriptor(
                uuid: uuid,
                localizedName: screen.localizedName,
                isMain: screen == NSScreen.main,
                logicalWidth: Int(frame.width.rounded()),
                logicalHeight: Int(frame.height.rounded()),
                pixelWidth: Int(CGDisplayPixelsWide(displayID)),
                pixelHeight: Int(CGDisplayPixelsHigh(displayID)),
                isConnected: true
            )
            nextDisplays.append(descriptor)
            nextScreens[uuid] = screen
        }

        nextDisplays.sort {
            if $0.isMain != $1.isMain { return $0.isMain }
            return $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
        }
        let changed = nextDisplays != displays
        displays = nextDisplays
        screensByUUID = nextScreens
        if changed {
            NotificationCenter.default.post(name: .dailyWallpaperDisplaysDidChange, object: self)
        }
        return displays
    }

    func screen(for uuid: String) -> NSScreen? {
        screensByUUID[uuid]
    }

    func uuid(for screen: NSScreen) -> String? {
        guard let displayID = Self.displayID(for: screen) else { return nil }
        return Self.uuid(for: displayID)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static func uuid(for displayID: CGDirectDisplayID) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(kCFAllocatorDefault, value) as String
    }
}
