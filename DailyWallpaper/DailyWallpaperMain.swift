import AppKit

@main
enum DailyWallpaperMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // 前台主窗口需要正常的 Dock 与应用切换器身份；菜单栏快捷入口仍会保留。
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
